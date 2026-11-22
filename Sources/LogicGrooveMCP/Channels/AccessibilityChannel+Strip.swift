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

    /// Bounded bisection on the fader's raw value (at most 14 steps, 120 ms after each set) until the
    /// level text read-back is within 0.15 dB of `db`. Success within 0.3 dB, otherwise unverified.
    func setFaderDb(params: [String: String], master: Bool) async -> ChannelResult {
        guard let dbText = params["db"], let target = Double(dbText), target.isFinite, (-60.0...6.0).contains(target) else {
            return .error("'db' is required and must be a number between -60 and 6")
        }
        let trackIndex = Int(params["track_index"] ?? "-1") ?? -1
        let prep = await prepareStrip(trackIndex: trackIndex, requireTrack: !master)
        if let error = prep.error { return .error(error) }
        var trace = prep.trace
        let label = master ? "Stereo Out" : (AXLogicProElements.stripModel()?.trackName ?? "selected track")

        guard let info = AXLogicProElements.faderInfo(master: master) else {
            return .error("Volume fader of \(label) not found in the strip. Trace: \(trace.joined(separator: "; "))")
        }
        guard info.settable else {
            return .error("The volume fader of \(label) is not settable through Accessibility. Trace: \(trace.joined(separator: "; "))")
        }
        trace.append("fader range \(info.min)...\(info.max), raw \(info.raw), level '\(info.levelText ?? "?")'")

        var low = info.min
        var high = info.max
        var bestRaw = info.raw
        var bestError = Double.infinity
        var lastRaw = Double.nan
        var steps = 0
        while steps < 14 {
            steps += 1
            let mid = (low + high) / 2
            if mid == lastRaw { break }
            lastRaw = mid
            guard AXLogicProElements.setFaderRaw(master: master, raw: mid) else {
                return .error("Setting the fader of \(label) failed at raw \(mid). Trace: \(trace.joined(separator: "; "))")
            }
            guard await FilePanelAutomation.pause(ms: 120) else { return .error("Cancelled") }
            let text = AXLogicProElements.faderLevelText(master: master)
            trace.append("raw \(String(format: "%.2f", mid)) -> '\(text ?? "?")'")
            guard let text, let level = ComposeSupport.parseDecibels(text) else {
                return .error("The level text of \(label) is unreadable after setting raw \(mid). Trace: \(trace.joined(separator: "; "))")
            }
            let distance = abs(level - target)
            if distance < bestError {
                bestError = distance
                bestRaw = mid
            }
            if distance <= 0.15 { break }
            if level < target { low = mid } else { high = mid }
        }

        // Make sure the best value is the one that stays set, then read it back.
        if lastRaw != bestRaw {
            _ = AXLogicProElements.setFaderRaw(master: master, raw: bestRaw)
            guard await FilePanelAutomation.pause(ms: 120) else { return .error("Cancelled") }
            trace.append("restored best raw \(String(format: "%.2f", bestRaw))")
        }
        let finalText = AXLogicProElements.faderLevelText(master: master)
        let finalDb = finalText.flatMap { ComposeSupport.parseDecibels($0) }
        let finalRaw = AXLogicProElements.faderInfo(master: master)?.raw ?? bestRaw
        let summary = "\(label) volume: target \(target) dB, now '\(finalText ?? "?")' (raw \(String(format: "%.2f", finalRaw)), \(steps) step(s))"
        if let finalDb, abs(finalDb - target) <= 0.3 {
            return .success("\(summary). Trace: \(trace.joined(separator: "; "))")
        }
        return .unverified("\(summary), not within 0.3 dB of the target. Trace: \(trace.joined(separator: "; "))")
    }
}
