import ApplicationServices
import Foundation

/// Strip-based mixer commands: `strip`, `bypass_plugin`, `set_volume {db}`, `set_master_volume {db}`.
/// Straight-line async code calling synchronous AXLogicProElements helpers; no AX element crosses an `await`.
extension AccessibilityChannel {
    /// Select the wanted track (verified by read-back) and make sure the Inspector channel strip is
    /// reachable. `trackIndex < 0` means "the currently selected track" (which must be readable) when
    /// `requireTrack` is true; with `requireTrack` false only the Inspector strip is needed (Stereo Out).
    func prepareStrip(trackIndex: Int, requireTrack: Bool) async -> (error: String?, trace: [String]) {
        var trace: [String] = []
        if requireTrack {
            if trackIndex >= 0 {
                let selection = await selectTrackVerified(index: trackIndex)
                trace.append(contentsOf: selection.trace)
                guard selection.ok else {
                    return ("Could not select track \(trackIndex) (read back through Accessibility), so nothing was changed. Trace: \(trace.joined(separator: "; "))", trace)
                }
                guard await FilePanelAutomation.pause(ms: 300) else { return ("Cancelled", trace) }
            } else {
                guard AXLogicProElements.selectedTrackIndex() != nil else {
                    return ("No track is selected (or the selection cannot be read); pass 'track'. Nothing was changed.", trace)
                }
                trace.append("selected track \(AXLogicProElements.selectedTrackSummary())")
            }
        }
        if !AXLogicProElements.hasInspectorChannelStrip() {
            if case .pressed = AXLogicProElements.pressMenu(["View", "Show Inspector"]) {
                trace.append("opened the Inspector through View > Show Inspector")
                _ = await FilePanelAutomation.pause(ms: 500)
            }
        }
        guard AXLogicProElements.hasInspectorChannelStrip() else {
            let entries = AXLogicProElements.menuEntryTitles(path: ["View"])
            return ("Cannot find the Inspector channel strip (AXLayoutArea described 'Mixer'). Open the Inspector (I). View menu entries: \(entries.joined(separator: ", ")). Trace: \(trace.joined(separator: "; "))", trace)
        }
        return (nil, trace)
    }

    // MARK: - strip

    func stripReport(params: [String: String]) async -> ChannelResult {
        let trackIndex = Int(params["track_index"] ?? "-1") ?? -1
        let prep = await prepareStrip(trackIndex: trackIndex, requireTrack: true)
        if let error = prep.error { return .error(error) }
        guard let model = AXLogicProElements.stripModel() else {
            return .error("Could not read the selected track's channel strip. Trace: \(prep.trace.joined(separator: "; "))")
        }
        let response = StripResponse(chain: model.chainText, trace: prep.trace, strip: model)
        return .success(response.json())
    }

    // MARK: - bypass_plugin

    func bypassPlugin(params: [String: String]) async -> ChannelResult {
        let trackIndex = Int(params["track_index"] ?? "-1") ?? -1
        let wantedText = (params["bypassed"] ?? "true").lowercased()
        let wanted = !(wantedText == "false" || wantedText == "0" || wantedText == "no" || wantedText == "off")
        let pluginName = (params["plugin"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let target: PluginTarget
        if !pluginName.isEmpty {
            target = .named(pluginName)
        } else if let slotText = params["slot"], !slotText.isEmpty {
            switch PluginSlotRequest.parse(slotText) {
            case .some(.instrument): target = .instrument
            case .some(.effect(let n)): target = .effect(n)
            default: return .error("Invalid 'slot': use 0 or \"instrument\" for the instrument, 1, 2, ... for the n-th effect (or pass 'plugin' with a name)")
            }
        } else {
            return .error("Pass 'plugin' (name substring) or 'slot' (0 = instrument, n = n-th effect)")
        }

        let prep = await prepareStrip(trackIndex: trackIndex, requireTrack: true)
        if let error = prep.error { return .error(error) }
        var trace = prep.trace
        let outcome = AXLogicProElements.pressBypassIfNeeded(target: target, wanted: wanted)
        guard outcome.found else {
            let chain = AXLogicProElements.stripModel()?.chainText ?? "strip unreadable"
            return .error("Plug-in \(target) not found in the strip (\(outcome.note); chain: \(chain)). Trace: \(trace.joined(separator: "; "))")
        }
        trace.append("\(outcome.name): bypass before=\(outcome.before.map { String($0) } ?? "unreadable"), \(outcome.note)")
        guard outcome.before != nil else {
            return .error("The bypass state of '\(outcome.name)' cannot be read, so nothing was pressed. Trace: \(trace.joined(separator: "; "))")
        }
        if outcome.pressed {
            guard await FilePanelAutomation.pause(ms: 200) else { return .error("Cancelled") }
        } else if outcome.before != wanted {
            return .error("Could not press the bypass checkbox of '\(outcome.name)'. Trace: \(trace.joined(separator: "; "))")
        }
        let after = AXLogicProElements.bypassState(target: target)
        trace.append("read back: \(after.map { String($0.bypassed) } ?? "unreadable")")
        guard let after, after.bypassed == wanted else {
            return .error("Bypass of '\(outcome.name)' is not \(wanted) after the press. Trace: \(trace.joined(separator: "; "))")
        }
        let changed = outcome.pressed ? "changed" : "unchanged"
        return .success("\(after.name) is now \(wanted ? "bypassed" : "active") (\(changed)). Trace: \(trace.joined(separator: "; "))")
    }

    // MARK: - set_volume / set_master_volume with dB

    /// Stepped search with read-back from the level text. Live finding: setting the fader's AXValue to a
    /// wanted value does not jump (every set moved it about 0.1 dB down), so the fader is moved one step
    /// at a time. A stepping method is chosen by testing each with ONE step and reading the level back:
    /// (1) AXIncrement / AXDecrement, (2) AXValue set to the current raw value +/- 1, 2, 5, 10. The chosen
    /// method is repeated until the level is within 0.15 dB of the target or has crossed it (at most 4
    /// reversals), with a cap of 700 steps and 25 s. When no method moves the fader the right way and the
    /// level text field is settable, the text is written instead. Success within 0.3 dB, otherwise error.
    func setFaderDb(params: [String: String], master: Bool) async -> ChannelResult {
        guard let dbText = params["db"], let target = Double(dbText), target.isFinite, (-60.0...6.0).contains(target) else {
            return .error("'db' is required and must be a number between -60 and 6")
        }
        let trackIndex = Int(params["track_index"] ?? "-1") ?? -1
        let prep = await prepareStrip(trackIndex: trackIndex, requireTrack: !master)
        if let error = prep.error { return .error(error) }
        var trace = prep.trace
        let label = master ? "Stereo Out" : (AXLogicProElements.stripModel()?.trackName ?? "selected track")
        func traceText() -> String { trace.joined(separator: "; ") }

        guard let info = AXLogicProElements.faderInfo(master: master) else {
            return .error("Volume fader of \(label) not found in the strip. Trace: \(traceText())")
        }
        guard let startText = info.levelText, var level = ComposeSupport.parseDecibels(startText) else {
            return .error("The level text of the \(label) fader is unreadable ('\(info.levelText ?? "none")'). Trace: \(traceText())")
        }
        let actions = AXLogicProElements.faderActionNames(master: master)
        trace.append("fader raw \(String(format: "%.2f", info.raw)) (\(info.min)...\(info.max)), settable=\(info.settable), level '\(startText)', actions [\(actions.joined(separator: ","))]")
        if abs(level - target) <= 0.15 {
            return .success("\(label) volume is already '\(startText)' (target \(target) dB)")
        }

        // 1. Pick a stepping method: one probe step each, read back.
        var methods: [FaderStepMethod] = []
        if actions.contains("AXIncrement") && actions.contains("AXDecrement") { methods.append(.action) }
        if info.settable {
            methods.append(contentsOf: [.delta(1), .delta(2), .delta(5), .delta(10)])
        }
        var chosen: FaderStepMethod?
        var steps = 0
        var lastText = startText
        // Nearest known readings below and above the target (the fader moves in steps, so the target
        // may lie between two of them).
        var below: Double?
        var above: Double?
        func record(_ reading: Double) {
            if reading.isFinite == false { return }
            if reading < target {
                if below == nil || reading > (below ?? reading) { below = reading }
            } else if reading > target {
                if above == nil || reading < (above ?? reading) { above = reading }
            }
        }
        record(level)
        for method in methods {
            let direction = target > level ? 1 : -1
            let probe = AXLogicProElements.stepFaderBatch(master: master, method: method, direction: direction, target: target, maxSteps: 1)
            steps += probe.steps
            guard await FilePanelAutomation.pause(ms: 40) else { return .error("Cancelled") }
            guard let newLevel = probe.level, probe.stop != "unreadable", probe.stop != "failed" else {
                trace.append("probe \(method.label): \(probe.stop)")
                continue
            }
            let moved = direction > 0 ? newLevel > level + 0.001 : newLevel < level - 0.001
            trace.append("probe \(method.label) \(direction > 0 ? "up" : "down"): \(String(format: "%.1f", level)) -> \(probe.lastText ?? "?") (\(moved ? "moved" : "no move in the wanted direction"))")
            level = newLevel
            record(newLevel)
            if let text = probe.lastText { lastText = text }
            if moved {
                chosen = method
                break
            }
        }

        // 2. Repeat the chosen method.
        var reversals = 0
        var stop = "no method"
        if let method = chosen {
            let started = Date()
            var direction = target > level ? 1 : -1
            stop = "limit"
            while steps < 700 {
                if Date().timeIntervalSince(started) > 25 { stop = "time limit (25 s)"; break }
                let diff = target - level
                if abs(diff) <= 0.15 { stop = "target"; break }
                let wanted = diff > 0 ? 1 : -1
                if wanted != direction {
                    reversals += 1
                    if reversals >= 2, below != nil, above != nil { stop = "between steps"; break }
                    if reversals > 4 { stop = "too many reversals"; break }
                    direction = wanted
                }
                let batch = AXLogicProElements.stepFaderBatch(
                    master: master, method: method, direction: direction, target: target, maxSteps: Swift.min(12, 700 - steps))
                steps += batch.steps
                if let text = batch.lastText { lastText = text }
                if let newLevel = batch.level { level = newLevel; record(newLevel) }
                if batch.stop == "unreadable" || batch.stop == "failed" {
                    stop = batch.stop
                    break
                }
                if batch.stop == "stalled" {
                    stop = "stalled (the level did not change)"
                    break
                }
                guard await FilePanelAutomation.pause(ms: 5) else { return .error("Cancelled") }
            }
            trace.append("stepping with \(method.label): \(steps) step(s), \(reversals) reversal(s), stopped: \(stop), last '\(lastText)'")
        } else if AXLogicProElements.faderLevelFieldSettable(master: master) {
            // 3. Last resort: write the level text.
            let text = ComposeSupport.formatDecibels(target, like: startText)
            let outcome = AXLogicProElements.setFaderLevelText(master: master, text: text)
            trace.append("no stepping method moved the fader; level text set to '\(text)': write \(outcome.set ? "ok" : "failed"), confirm \(outcome.confirmed ? "ok" : "failed")")
            guard await FilePanelAutomation.pause(ms: 300) else { return .error("Cancelled") }
            stop = "level text"
        } else {
            trace.append("no stepping method moved the fader in the wanted direction and the level text is not settable")
        }

        // 4. Final read-back.
        var finalText = AXLogicProElements.faderLevelText(master: master)
        var finalDb = finalText.flatMap { ComposeSupport.parseDecibels($0) }

        // 4b. The target lies between two fader steps: go to the nearer of the two known readings.
        if stop == "between steps" || stop == "too many reversals",
           let lowReading = below, let highReading = above, highReading > lowReading, let method = chosen {
            let nearer = ComposeSupport.nearestStep(target: target, lower: lowReading, upper: highReading)
            if let nowDb = finalDb, abs(nowDb - nearer) > 0.15 {
                let fixDirection = nearer > nowDb ? 1 : -1
                let fix = AXLogicProElements.stepFaderBatch(
                    master: master, method: method, direction: fixDirection, target: nearer, maxSteps: 2)
                steps += fix.steps
                guard await FilePanelAutomation.pause(ms: 200) else { return .error("Cancelled") }
                finalText = AXLogicProElements.faderLevelText(master: master)
                finalDb = finalText.flatMap { ComposeSupport.parseDecibels($0) }
                trace.append("target between steps (\(lowReading) / \(highReading) dB); moved toward the nearer one")
            }
            if let reached = finalDb, abs(reached - nearer) <= 0.3 {
                return .success("\(label) volume: the fader moves in steps there; nearest step '\(finalText ?? "?")' for target \(target) dB (start '\(startText)', \(steps) step(s)). Trace: \(traceText())")
            }
        }
        let methodText = chosen.map { $0.label } ?? stop
        let summary = "\(label) volume: target \(target) dB, now '\(finalText ?? "?")' (start '\(startText)', method \(methodText), \(steps) step(s))"
        if let finalDb, abs(finalDb - target) <= 0.3 {
            return .success("\(summary). Trace: \(traceText())")
        }
        return .error("\(summary), not within 0.3 dB of the target. Trace: \(traceText())")
    }
}
