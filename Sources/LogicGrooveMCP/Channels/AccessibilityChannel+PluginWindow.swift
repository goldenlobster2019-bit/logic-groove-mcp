import ApplicationServices
import Foundation

/// A plug-in window the current command works with. Only Sendable values.
struct PluginWindowSession: Sendable {
    let key: PluginWindowKey
    let openedByUs: Bool
    let keepOpen: Bool
    let trace: [String]
}

/// Which plug-in a command addresses, resolved against the selected track's strip.
struct PluginTargetResolution: Sendable {
    let key: PluginWindowKey?
    let target: PluginTarget?
    let error: String?
    let trace: [String]
}

/// Outcome of driving a pop-up menu of a plug-in window.
struct PluginMenuChoice: Sendable {
    let error: String?
    let notes: [String]
    /// Titles of the final level (only when nothing was pressed).
    let titles: [String]
}

/// Commands that work on a plug-in's own window: open / close, Logic's settings menu, plug-in pop-ups,
/// parameters through the Controls view. Straight-line async code; every step re-finds its AX elements
/// through the Sendable `PluginWindowKey`, so no element is held across an `await`.
/// The Controls view structure and the pop-up menu structure are UNVERIFIED (see the trace of each call).
extension AccessibilityChannel {
    // MARK: - Small helpers

    private static func flag(_ params: [String: String], _ key: String, default fallback: Bool) -> Bool {
        guard let text = params[key]?.lowercased() else { return fallback }
        if text == "true" || text == "1" || text == "yes" || text == "on" { return true }
        if text == "false" || text == "0" || text == "no" || text == "off" { return false }
        return fallback
    }

    private static func jsonText(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func closeMenuLevels(_ levels: Int) async {
        for _ in 0..<Swift.max(1, levels) {
            await FilePanelAutomation.pressEscape()
            _ = await FilePanelAutomation.pause(ms: 80)
        }
    }

    // MARK: - Resolving and opening

    /// Select the track (verified), read the strip and resolve `plugin` / `slot` to a plug-in. Without
    /// either, the instrument is used.
    func resolvePluginTarget(params: [String: String]) async -> PluginTargetResolution {
        var trace: [String] = []
        if AXLogicProElements.dismissDownloadPrompt() != nil {
            trace.append(AXLogicProElements.downloadPromptTraceText)
        }
        if !AXLogicProElements.focusedWindowIsProject() {
            let raised = AXLogicProElements.raiseProjectWindow()
            trace.append("project window was not the focused window (\(AXLogicProElements.focusedWindowSummary())); raise \(raised ? "ok" : "failed")")
            _ = await FilePanelAutomation.pause(ms: 250)
        }
        let trackIndex = Int(params["track_index"] ?? "-1") ?? -1
        let prep = await prepareStrip(trackIndex: trackIndex, requireTrack: true)
        trace.append(contentsOf: prep.trace)
        if let error = prep.error {
            return PluginTargetResolution(key: nil, target: nil, error: error, trace: trace)
        }
        guard let model = AXLogicProElements.stripModel() else {
            return PluginTargetResolution(key: nil, target: nil, error: "Could not read the selected track's channel strip. Trace: \(trace.joined(separator: "; "))", trace: trace)
        }
        trace.append("strip: \(model.chainText)")
        let pluginText = (params["plugin"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let slotText = (params["slot"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var target: PluginTarget = .instrument
        var name: String?
        if !pluginText.isEmpty {
            target = .named(pluginText)
            name = model.plugins.first { ComposeSupport.pluginNameMatches($0.name, pluginText) }?.name
        } else if !slotText.isEmpty {
            switch PluginSlotRequest.parse(slotText) {
            case .some(.instrument):
                target = .instrument
                name = model.instrument?.name
            case .some(.effect(let n)):
                target = .effect(n)
                name = model.effects.indices.contains(n - 1) ? model.effects[n - 1].name : nil
            default:
                return PluginTargetResolution(key: nil, target: nil, error: "Invalid 'slot': use 0 or \"instrument\" for the instrument or 1, 2, ... for the n-th effect (or pass 'plugin' with a name)", trace: trace)
            }
        } else {
            name = model.instrument?.name
            trace.append("neither 'plugin' nor 'slot' given: using the instrument")
        }
        guard let pluginName = name, !pluginName.isEmpty else {
            return PluginTargetResolution(key: nil, target: nil, error: "The wanted plug-in is not in the strip (chain: \(model.chainText)). Trace: \(trace.joined(separator: "; "))", trace: trace)
        }
        let key = PluginWindowKey(pluginName: pluginName, trackName: model.trackName)
        return PluginTargetResolution(key: key, target: target, error: nil, trace: trace)
    }

    /// Resolve the plug-in and make sure its window is open (an already open one is reused). The window is
    /// closed again by `endPluginWindow` only when this call opened it and `keep_open` is not set.
    func beginPluginWindow(params: [String: String], forceKeepOpen: Bool = false) async -> (session: PluginWindowSession?, error: String?) {
        let resolution = await resolvePluginTarget(params: params)
        if let error = resolution.error { return (nil, error) }
        guard let key = resolution.key, let target = resolution.target else {
            return (nil, "Could not resolve the plug-in")
        }
        var trace = resolution.trace
        let keepOpen = forceKeepOpen || Self.flag(params, "keep_open", default: false)
        if AXLogicProElements.pluginWindowExists(key) {
            trace.append("plug-in window for '\(key.pluginName)' was already open")
            return (PluginWindowSession(key: key, openedByUs: false, keepOpen: keepOpen, trace: trace), nil)
        }
        guard await FilePanelAutomation.ensureFrontmost() else {
            return (nil, "Could not bring Logic Pro to the front. Trace: \(trace.joined(separator: "; "))")
        }
        let press = AXLogicProElements.pressPluginOpen(target: target)
        guard press.found else {
            return (nil, "Cannot open the plug-in window: \(press.note). Trace: \(trace.joined(separator: "; "))")
        }
        trace.append("\(press.name): \(press.note)")
        var waited = 0
        while waited < 2_000 {
            guard await FilePanelAutomation.pause(ms: 100) else { return (nil, "Cancelled") }
            waited += 100
            if AXLogicProElements.pluginWindowExists(key) { break }
        }
        guard AXLogicProElements.pluginWindowExists(key) else {
            let titles = AXLogicProElements.windowTitles().map { "'\($0)'" }.joined(separator: ", ")
            return (nil, "No plug-in window for '\(key.pluginName)' appeared within 2 seconds (windows: \(titles)). Trace: \(trace.joined(separator: "; "))")
        }
        trace.append("plug-in window opened after \(waited) ms: '\(AXLogicProElements.pluginWindowTitle(key) ?? "")'")
        return (PluginWindowSession(key: key, openedByUs: true, keepOpen: keepOpen, trace: trace), nil)
    }

    /// Close the window when this command opened it (and keep_open is off). Returns a trace note.
    func endPluginWindow(_ session: PluginWindowSession) async -> String {
        guard session.openedByUs, !session.keepOpen else {
            return session.keepOpen ? "plug-in window left open (keep_open)" : "plug-in window was open before; left open"
        }
        guard AXLogicProElements.pluginWindowExists(session.key) else { return "plug-in window already gone" }
        let pressed = AXLogicProElements.pressPluginWindowClose(session.key)
        var waited = 0
        while waited < 1_000 {
            guard await FilePanelAutomation.pause(ms: 100) else { return "cancelled while closing the plug-in window" }
            waited += 100
            if !AXLogicProElements.pluginWindowExists(session.key) {
                return "closed the plug-in window (close button \(pressed ? "pressed" : "not pressed")) after \(waited) ms"
            }
        }
        return "WARNING: the plug-in window is still open after the close press (\(pressed ? "pressed" : "no close button"))"
    }

    func openPluginCommand(params: [String: String]) async -> ChannelResult {
        let begun = await beginPluginWindow(params: params, forceKeepOpen: true)
        guard let session = begun.session else { return .error(begun.error ?? "Could not open the plug-in window") }
        let title = AXLogicProElements.pluginWindowTitle(session.key) ?? ""
        let state = session.openedByUs ? "Opened" : "Plug-in window was already open:"
        return .success("\(state) '\(session.key.pluginName)' window (title '\(title)'). Trace: \(session.trace.joined(separator: "; "))")
    }

    func closePluginCommand(params: [String: String]) async -> ChannelResult {
        let resolution = await resolvePluginTarget(params: params)
        if let error = resolution.error { return .error(error) }
        guard let key = resolution.key else { return .error("Could not resolve the plug-in") }
        var trace = resolution.trace
        guard AXLogicProElements.pluginWindowExists(key) else {
            return .success("The plug-in window for '\(key.pluginName)' is not open. Trace: \(trace.joined(separator: "; "))")
        }
        let pressed = AXLogicProElements.pressPluginWindowClose(key)
        trace.append("close button \(pressed ? "pressed" : "not found or press failed")")
        var waited = 0
        while waited < 1_500 {
            guard await FilePanelAutomation.pause(ms: 100) else { return .error("Cancelled") }
            waited += 100
            if !AXLogicProElements.pluginWindowExists(key) {
                return .success("Closed the '\(key.pluginName)' window after \(waited) ms. Trace: \(trace.joined(separator: "; "))")
            }
        }
        return .error("The '\(key.pluginName)' window is still open after the close press. Trace: \(trace.joined(separator: "; "))")
    }

    // MARK: - Menu driving

    private func waitForPluginMenu(ref: PluginControlRef, key: PluginWindowKey, timeoutMs: Int) async -> Bool {
        var waited = 0
        while waited <= timeoutMs {
            let level = AXLogicProElements.pluginMenuTitles(ref, key: key, path: [])
            if level.found && !level.titles.isEmpty { return true }
            guard await FilePanelAutomation.pause(ms: 100) else { return false }
            waited += 100
        }
        return false
    }

    /// Open the menu of `ref`, follow `path` and (with `pressLast`) press the last component; without it
    /// the titles of the final level are returned and the caller closes the menu. Non-final components are
    /// followed through their AX submenu when it is already visible, else the item is pressed and the
    /// submenu awaited for up to 800 ms. On failure Escape is posted for every level that was opened and
    /// the error lists the titles of the level where the search failed.
    func navigatePluginMenu(ref: PluginControlRef, key: PluginWindowKey, path: [String], pressLast: Bool) async -> PluginMenuChoice {
        var notes: [String] = []
        if pressLast && path.isEmpty {
            return PluginMenuChoice(error: "Empty menu path", notes: notes, titles: [])
        }
        guard await FilePanelAutomation.ensureFrontmost() else {
            return PluginMenuChoice(error: "Could not bring Logic Pro to the front", notes: notes, titles: [])
        }
        guard let code = AXLogicProElements.pressPluginControl(ref, key: key) else {
            return PluginMenuChoice(error: "The control \(ref) was not found in the plug-in window", notes: notes, titles: [])
        }
        notes.append("pressed the control (returned \(code))")
        var opened = await waitForPluginMenu(ref: ref, key: key, timeoutMs: 1_500)
        if !opened {
            let showCode = AXLogicProElements.showPluginControlMenu(ref, key: key)
            notes.append("AXShowMenu returned \(showCode.map { String($0) } ?? "n/a")")
            opened = await waitForPluginMenu(ref: ref, key: key, timeoutMs: 800)
        }
        guard opened else {
            await closeMenuLevels(1)
            return PluginMenuChoice(error: "The menu did not open (no AXMenu with entries visible within 2.3 s)", notes: notes, titles: [])
        }
        var openedLevels = 1
        for index in path.indices {
            let component = path[index]
            let prefix = Array(path[0..<index])
            if index == path.count - 1 && pressLast {
                let step = AXLogicProElements.pressPluginMenuEntry(ref, key: key, path: prefix, title: component)
                guard step.found else {
                    await closeMenuLevels(openedLevels)
                    return PluginMenuChoice(
                        error: "\(step.note); items at '\(prefix.joined(separator: "/"))': \(step.titles.joined(separator: " | "))",
                        notes: notes, titles: step.titles)
                }
                notes.append(step.note)
                return PluginMenuChoice(error: nil, notes: notes, titles: [])
            }
            var level = AXLogicProElements.pluginMenuTitles(ref, key: key, path: prefix + [component])
            if !(level.found && !level.titles.isEmpty) {
                let step = AXLogicProElements.pressPluginMenuEntry(ref, key: key, path: prefix, title: component)
                guard step.found else {
                    await closeMenuLevels(openedLevels)
                    return PluginMenuChoice(
                        error: "\(step.note); items at '\(prefix.joined(separator: "/"))': \(step.titles.joined(separator: " | "))",
                        notes: notes, titles: step.titles)
                }
                notes.append(step.note)
                var waited = 0
                while waited < 800 {
                    guard await FilePanelAutomation.pause(ms: 100) else {
                        return PluginMenuChoice(error: "Cancelled", notes: notes, titles: [])
                    }
                    waited += 100
                    level = AXLogicProElements.pluginMenuTitles(ref, key: key, path: prefix + [component])
                    if level.found && !level.titles.isEmpty { break }
                }
                guard level.found && !level.titles.isEmpty else {
                    await closeMenuLevels(openedLevels + 1)
                    return PluginMenuChoice(error: "'\(component)' has no submenu", notes: notes, titles: [])
                }
            }
            openedLevels += 1
        }
        let finalLevel = AXLogicProElements.pluginMenuTitles(ref, key: key, path: path)
        return PluginMenuChoice(error: nil, notes: notes, titles: finalLevel.titles)
    }

    // MARK: - Settings menu

    func pluginSettingRead(params: [String: String]) async -> ChannelResult {
        let begun = await beginPluginWindow(params: params)
        guard let session = begun.session else { return .error(begun.error ?? "Could not open the plug-in window") }
        let value = AXLogicProElements.pluginControlText(.settings, key: session.key)
        let closeNote = await endPluginWindow(session)
        let trace = session.trace + [closeNote]
        guard let value else {
            return .error("The settings pop-up of the '\(session.key.pluginName)' window was not found. Trace: \(trace.joined(separator: "; "))")
        }
        return .success(Self.jsonText(["plugin": session.key.pluginName, "setting": value, "trace": trace]))
    }

    func setPluginSetting(params: [String: String]) async -> ChannelResult {
        let path = ComposeSupport.splitMenuPath(params["setting"] ?? "")
        guard let wanted = path.last else {
            return .error("Missing 'setting' (a menu item title, or a path such as \"Dub Delays/Dub Echo\")")
        }
        let begun = await beginPluginWindow(params: params)
        guard let session = begun.session else { return .error(begun.error ?? "Could not open the plug-in window") }
        var trace = session.trace
        let before = AXLogicProElements.pluginControlText(.settings, key: session.key)
        trace.append("setting before: '\(before ?? "?")'")
        let choice = await navigatePluginMenu(ref: .settings, key: session.key, path: path, pressLast: true)
        trace.append(contentsOf: choice.notes)
        if let error = choice.error {
            let closeNote = await endPluginWindow(session)
            trace.append(closeNote)
            return .error("Could not choose the setting: \(error). Trace: \(trace.joined(separator: "; "))")
        }
        guard await FilePanelAutomation.pause(ms: 500) else { return .error("Cancelled") }
        let after = AXLogicProElements.pluginControlText(.settings, key: session.key)
        trace.append("setting after: '\(after ?? "?")'")
        let closeNote = await endPluginWindow(session)
        trace.append(closeNote)
        if let after, after.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted.lowercased() {
            return .success("Setting of '\(session.key.pluginName)' is now '\(after)' (was '\(before ?? "?")'). Trace: \(trace.joined(separator: "; "))")
        }
        return .error("The settings pop-up reads '\(after ?? "?")' after choosing '\(wanted)' (expected '\(wanted)'). Trace: \(trace.joined(separator: "; "))")
    }

    func pluginSettingsMenu(params: [String: String]) async -> ChannelResult {
        let path = ComposeSupport.splitMenuPath(params["path"] ?? "")
        let begun = await beginPluginWindow(params: params)
        guard let session = begun.session else { return .error(begun.error ?? "Could not open the plug-in window") }
        var trace = session.trace
        let choice = await navigatePluginMenu(ref: .settings, key: session.key, path: path, pressLast: false)
        trace.append(contentsOf: choice.notes)
        if choice.error == nil {
            await closeMenuLevels(path.count + 1)
        }
        let closeNote = await endPluginWindow(session)
        trace.append(closeNote)
        if let error = choice.error {
            return .error("Could not list the settings menu: \(error). Trace: \(trace.joined(separator: "; "))")
        }
        return .success(Self.jsonText([
            "plugin": session.key.pluginName,
            "path": path.joined(separator: "/"),
            "items": choice.titles,
            "trace": trace,
        ]))
    }

    // MARK: - Plug-in specific pop-ups

    func pluginPopupsRead(params: [String: String]) async -> ChannelResult {
        let begun = await beginPluginWindow(params: params)
        guard let session = begun.session else { return .error(begun.error ?? "Could not open the plug-in window") }
        let count = AXLogicProElements.pluginPopupCount(session.key)
        var lines: [String] = ["settings | \(AXLogicProElements.pluginControlText(.settings, key: session.key) ?? "?")"]
        for index in 0..<count {
            lines.append("\(index) | \(AXLogicProElements.pluginControlText(.popup(index), key: session.key) ?? "?")")
        }
        let closeNote = await endPluginWindow(session)
        lines.append("(\(count) plug-in pop-up(s); \(closeNote))")
        return .success(lines.joined(separator: "\n"))
    }

    func setPluginPopup(params: [String: String]) async -> ChannelResult {
        guard let index = Int(params["index"] ?? ""), index >= 0 else {
            return .error("Missing or invalid 'index' (0-based among the plug-in specific pop-ups)")
        }
        let path = ComposeSupport.splitMenuPath(params["value"] ?? "")
        guard let wanted = path.last else { return .error("Missing 'value' (the menu item title)") }
        let begun = await beginPluginWindow(params: params)
        guard let session = begun.session else { return .error(begun.error ?? "Could not open the plug-in window") }
        var trace = session.trace
        let count = AXLogicProElements.pluginPopupCount(session.key)
        guard index < count else {
            let closeNote = await endPluginWindow(session)
            return .error("The window has \(count) plug-in pop-up(s); index \(index) does not exist. Trace: \((trace + [closeNote]).joined(separator: "; "))")
        }
        let before = AXLogicProElements.pluginControlText(.popup(index), key: session.key)
        trace.append("pop-up \(index) before: '\(before ?? "?")'")
        let choice = await navigatePluginMenu(ref: .popup(index), key: session.key, path: path, pressLast: true)
        trace.append(contentsOf: choice.notes)
        if let error = choice.error {
            let closeNote = await endPluginWindow(session)
            trace.append(closeNote)
            return .error("Could not choose '\(wanted)' in pop-up \(index): \(error). Trace: \(trace.joined(separator: "; "))")
        }
        guard await FilePanelAutomation.pause(ms: 500) else { return .error("Cancelled") }
        let after = AXLogicProElements.pluginControlText(.popup(index), key: session.key)
        trace.append("pop-up \(index) after: '\(after ?? "?")'")
        let closeNote = await endPluginWindow(session)
        trace.append(closeNote)
        if let after, after.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted.lowercased() {
            return .success("Pop-up \(index) of '\(session.key.pluginName)' is now '\(after)' (was '\(before ?? "?")'). Trace: \(trace.joined(separator: "; "))")
        }
        return .error("Pop-up \(index) reads '\(after ?? "?")' after choosing '\(wanted)'. Trace: \(trace.joined(separator: "; "))")
    }

    // MARK: - Controls view

    /// Switch the window to the Controls view. previous is nil when it already was in that view.
    private func ensureControlsView(key: PluginWindowKey) async -> (error: String?, previous: String?, notes: [String]) {
        guard let title = AXLogicProElements.pluginControlText(.view, key: key) else {
            return ("The view menu button of the plug-in window was not found", nil, [])
        }
        if title.lowercased().contains("controls") {
            return (nil, nil, ["window already shows the Controls view"])
        }
        let choice = await navigatePluginMenu(ref: .view, key: key, path: ["Controls"], pressLast: true)
        var notes = choice.notes
        if let error = choice.error {
            return ("Could not switch to the Controls view: \(error)", nil, notes)
        }
        guard await FilePanelAutomation.pause(ms: 600) else { return ("Cancelled", nil, notes) }
        let newTitle = AXLogicProElements.pluginControlText(.view, key: key) ?? ""
        let count = AXLogicProElements.readPluginParams(key).count
        notes.append("view '\(title)' -> '\(newTitle)', \(count) slider(s) found")
        if count == 0 && !newTitle.lowercased().contains("controls") {
            return ("The view did not switch to Controls (view button '\(newTitle)', no sliders)", title, notes)
        }
        return (nil, title, notes)
    }

    /// Switch back to the view that was active before `ensureControlsView` (a zoom factor such as "100%"
    /// means the Editor view). Returns a trace note.
    private func restoreView(key: PluginWindowKey, previous: String?) async -> String {
        guard let previous else { return "view unchanged" }
        let lowered = previous.lowercased()
        let target = (lowered.hasSuffix("%") || lowered.isEmpty) ? "Editor" : previous
        let choice = await navigatePluginMenu(ref: .view, key: key, path: [target], pressLast: true)
        if let error = choice.error {
            return "could not switch back to '\(target)' (\(error)); the window stays in the Controls view"
        }
        _ = await FilePanelAutomation.pause(ms: 400)
        return "switched the view back to '\(target)' (now '\(AXLogicProElements.pluginControlText(.view, key: key) ?? "?")')"
    }

    private static func paramLine(_ param: PluginParam) -> String {
        var raw = "-"
        if let value = param.raw {
            raw = String(format: "%.4g", value)
            if let low = param.minValue, let high = param.maxValue {
                raw += " (\(String(format: "%.4g", low))..\(String(format: "%.4g", high)))"
            }
        }
        let value = param.valueText.isEmpty ? (param.fieldText ?? "") : param.valueText
        let flags = (param.sliderSettable ? "v" : "") + (param.fieldSettable ? "t" : "")
        return "\(param.index) | \(param.label) | \(value) | \(raw) | \(flags.isEmpty ? "-" : flags)"
    }

    func pluginParamsRead(params: [String: String]) async -> ChannelResult {
        let begun = await beginPluginWindow(params: params)
        guard let session = begun.session else { return .error(begun.error ?? "Could not open the plug-in window") }
        var trace = session.trace
        let view = await ensureControlsView(key: session.key)
        trace.append(contentsOf: view.notes)
        if let error = view.error {
            let restore = await restoreView(key: session.key, previous: view.previous)
            let closeNote = await endPluginWindow(session)
            return .error("\(error). Trace: \((trace + [restore, closeNote]).joined(separator: "; "))")
        }
        let all = AXLogicProElements.readPluginParams(session.key)
        let filter = (params["filter"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shown = filter.isEmpty ? all : all.filter { $0.label.lowercased().contains(filter) }
        let restore = await restoreView(key: session.key, previous: view.previous)
        let closeNote = await endPluginWindow(session)
        var lines: [String] = ["\(shown.count)/\(all.count) parameters of '\(session.key.pluginName)' (index | label | value | raw (min..max) | v = slider value settable, t = text field settable)"]
        lines.append(contentsOf: shown.map { Self.paramLine($0) })
        lines.append("trace: \((trace + [restore, closeNote]).joined(separator: "; "))")
        return .success(lines.joined(separator: "\n"))
    }

    /// Whether `text` reads as the requested number within `tolerance`.
    private static func textMatches(_ text: String?, target: Double, tolerance: Double) -> Bool {
        guard let text, let number = ComposeSupport.parseDisplayedNumber(text) else { return false }
        return abs(number - target) <= tolerance
    }

    private func pluginParamFailure(_ message: String, session: PluginWindowSession, previous: String?, trace: [String]) async -> ChannelResult {
        let restore = await restoreView(key: session.key, previous: previous)
        let closeNote = await endPluginWindow(session)
        return .error("\(message). Trace: \((trace + [restore, closeNote]).joined(separator: "; "))")
    }

    private func pluginParamSuccess(
        _ how: String, now: PluginParam?, param: PluginParam, beforeText: String,
        session: PluginWindowSession, previous: String?, trace: [String]
    ) async -> ChannelResult {
        let restore = await restoreView(key: session.key, previous: previous)
        let closeNote = await endPluginWindow(session)
        let nowText = now.map { $0.valueText.isEmpty ? ($0.fieldText ?? "") : $0.valueText } ?? "?"
        return .success("Parameter '\(param.label)' of '\(session.key.pluginName)' is now '\(nowText)' (was '\(beforeText)', \(how)). Trace: \((trace + [restore, closeNote]).joined(separator: "; "))")
    }

    func setPluginParam(params: [String: String]) async -> ChannelResult {
        guard let valueText = params["value"]?.trimmingCharacters(in: .whitespacesAndNewlines), !valueText.isEmpty else {
            return .error("Missing 'value'")
        }
        let paramName = (params["param"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wantedIndex = Int(params["index"] ?? "")
        guard !paramName.isEmpty || wantedIndex != nil else {
            return .error("Pass 'param' (label) or 'index' (from plugin_params)")
        }
        let useRaw = Self.flag(params, "raw", default: false)
        let numeric = ComposeSupport.parseDisplayedNumber(valueText)

        let begun = await beginPluginWindow(params: params)
        guard let session = begun.session else { return .error(begun.error ?? "Could not open the plug-in window") }
        var trace = session.trace
        let key = session.key

        let view = await ensureControlsView(key: key)
        trace.append(contentsOf: view.notes)
        if let error = view.error { return await pluginParamFailure(error, session: session, previous: view.previous, trace: trace) }
        let previousView = view.previous

        // Find the parameter: index, exact label, unique substring.
        let all = AXLogicProElements.readPluginParams(key)
        var chosen: PluginParam?
        if let wantedIndex {
            chosen = all.first { $0.index == wantedIndex }
        } else {
            let lowered = paramName.lowercased()
            chosen = all.first { $0.label.lowercased() == lowered }
            if chosen == nil {
                let partial = all.filter { $0.label.lowercased().contains(lowered) }
                if partial.count == 1 { chosen = partial[0] }
                else if partial.count > 1 {
                    let names = partial.prefix(20).map { "\($0.index): \($0.label)" }.joined(separator: ", ")
                    return await pluginParamFailure("'\(paramName)' matches several parameters (\(names)); use 'index'", session: session, previous: previousView, trace: trace)
                }
            }
        }
        guard let param = chosen else {
            let names = all.prefix(60).map { "\($0.index): \($0.label)" }.joined(separator: ", ")
            return await pluginParamFailure("Parameter '\(paramName.isEmpty ? String(wantedIndex ?? -1) : paramName)' not found among \(all.count): \(names)", session: session, previous: previousView, trace: trace)
        }
        let index = param.index
        let beforeText = param.valueText.isEmpty ? (param.fieldText ?? "") : param.valueText
        trace.append("parameter \(index) '\(param.label)' = '\(beforeText)' raw \(param.raw.map { String($0) } ?? "?") (\(param.minValue.map { String($0) } ?? "?")..\(param.maxValue.map { String($0) } ?? "?")), slider settable \(param.sliderSettable), field \(param.hasField ? (param.fieldSettable ? "settable" : "read-only") : "none")")
        let decimals = ComposeSupport.displayedDecimals(beforeText)
        let tolerance = 0.5 * pow(10.0, -Double(decimals)) + 1e-9

        // Strategy 1: AXValue of the slider.
        if let numeric, param.sliderSettable, let low = param.minValue, let high = param.maxValue, high > low, let raw0 = param.raw {
            if useRaw {
                guard numeric >= low && numeric <= high else {
                    return await pluginParamFailure("raw value \(numeric) is outside \(low)..\(high)", session: session, previous: previousView, trace: trace)
                }
                let written = AXLogicProElements.setPluginParamRaw(key, index: index, raw: numeric)
                guard await FilePanelAutomation.pause(ms: 250) else { return .error("Cancelled") }
                let now = AXLogicProElements.readPluginParam(key, index: index)
                trace.append("1 raw write \(written ? "ok" : "failed") -> raw \(now?.raw.map { String($0) } ?? "?")")
                if let nowRaw = now?.raw, abs(nowRaw - numeric) <= (high - low) * 0.005 {
                    return await pluginParamSuccess("AXValue raw", now: now, param: param, beforeText: beforeText, session: session, previous: previousView, trace: trace)
                }
            } else if let d0 = ComposeSupport.parseDisplayedNumber(beforeText) {
                // Probe a second point to map displayed number to raw value linearly; one secant refinement.
                let step = (high - low) * 0.1
                let raw1 = raw0 + step <= high ? raw0 + step : raw0 - step
                _ = AXLogicProElements.setPluginParamRaw(key, index: index, raw: raw1)
                guard await FilePanelAutomation.pause(ms: 200) else { return .error("Cancelled") }
                let probe = AXLogicProElements.readPluginParam(key, index: index)
                let d1 = probe.flatMap { ComposeSupport.parseDisplayedNumber($0.valueText.isEmpty ? ($0.fieldText ?? "") : $0.valueText) }
                if let d1, abs(d1 - d0) > 1e-9, let rawNow1 = probe?.raw, abs(rawNow1 - raw0) > 1e-12 {
                    let slope = (d1 - d0) / (rawNow1 - raw0)
                    var targetRaw = Swift.min(high, Swift.max(low, rawNow1 + (numeric - d1) / slope))
                    _ = AXLogicProElements.setPluginParamRaw(key, index: index, raw: targetRaw)
                    guard await FilePanelAutomation.pause(ms: 200) else { return .error("Cancelled") }
                    var now = AXLogicProElements.readPluginParam(key, index: index)
                    var nowText = now.map { $0.valueText.isEmpty ? ($0.fieldText ?? "") : $0.valueText }
                    trace.append("1 linear probe: slope \(slope) per raw unit; first write raw \(targetRaw) -> '\(nowText ?? "?")'")
                    if !Self.textMatches(nowText, target: numeric, tolerance: tolerance),
                       let d2 = nowText.flatMap({ ComposeSupport.parseDisplayedNumber($0) }), let raw2 = now?.raw, abs(d2 - d1) > 1e-9 {
                        let secant = (d2 - d1) / (raw2 - rawNow1)
                        if abs(secant) > 1e-12 {
                            targetRaw = Swift.min(high, Swift.max(low, raw2 + (numeric - d2) / secant))
                            _ = AXLogicProElements.setPluginParamRaw(key, index: index, raw: targetRaw)
                            guard await FilePanelAutomation.pause(ms: 200) else { return .error("Cancelled") }
                            now = AXLogicProElements.readPluginParam(key, index: index)
                            nowText = now.map { $0.valueText.isEmpty ? ($0.fieldText ?? "") : $0.valueText }
                            trace.append("1 secant refinement: raw \(targetRaw) -> '\(nowText ?? "?")'")
                        }
                    }
                    if Self.textMatches(nowText, target: numeric, tolerance: tolerance) {
                        return await pluginParamSuccess("AXValue of the slider", now: now, param: param, beforeText: beforeText, session: session, previous: previousView, trace: trace)
                    }
                    trace.append("1 not within tolerance \(tolerance) (the mapping may not be linear); restoring the old value")
                } else {
                    trace.append("1 probe did not change the displayed number; skipped")
                }
                _ = AXLogicProElements.setPluginParamRaw(key, index: index, raw: raw0)
                _ = await FilePanelAutomation.pause(ms: 200)
            } else {
                trace.append("1 skipped: the current text '\(beforeText)' has no number")
            }
        } else {
            trace.append("1 skipped: needs a numeric value, a settable slider with min/max")
        }

        // Strategy 2: the numeric text field.
        if param.hasField, param.fieldSettable, let numeric {
            let sample = param.fieldText ?? beforeText
            let text = ComposeSupport.formatValue(numeric, like: sample)
            let outcome = AXLogicProElements.setPluginParamText(key, index: index, text: text)
            guard await FilePanelAutomation.pause(ms: 300) else { return .error("Cancelled") }
            let now = AXLogicProElements.readPluginParam(key, index: index)
            let nowText = now.map { $0.valueText.isEmpty ? ($0.fieldText ?? "") : $0.valueText }
            trace.append("2 text field set to '\(text)': write \(outcome.written ? "ok" : "failed"), confirm \(outcome.confirmed ? "ok" : "failed") -> '\(nowText ?? "?")'")
            if Self.textMatches(nowText, target: numeric, tolerance: tolerance) {
                return await pluginParamSuccess("text field", now: now, param: param, beforeText: beforeText, session: session, previous: previousView, trace: trace)
            }
        } else {
            trace.append("2 skipped: no settable numeric field or no numeric value")
        }

        // Strategy 3: AXIncrement / AXDecrement.
        if let numeric, let current = ComposeSupport.parseDisplayedNumber(AXLogicProElements.readPluginParam(key, index: index)?.valueText ?? beforeText) {
            let started = Date()
            var steps = 0
            var stop = "limit"
            var direction = numeric > current ? 1 : -1
            var lastText = beforeText
            var reversals = 0
            while steps < 400 {
                if Date().timeIntervalSince(started) > 15 { stop = "time limit (15 s)"; break }
                let nowParam = AXLogicProElements.readPluginParam(key, index: index)
                let nowNumber = nowParam.flatMap { ComposeSupport.parseDisplayedNumber($0.valueText.isEmpty ? ($0.fieldText ?? "") : $0.valueText) }
                guard let nowNumber else { stop = "unreadable"; break }
                if abs(nowNumber - numeric) <= tolerance { stop = "target"; break }
                let wanted = numeric > nowNumber ? 1 : -1
                if wanted != direction {
                    reversals += 1
                    if reversals > 2 { stop = "between steps"; break }
                    direction = wanted
                }
                let batch = AXLogicProElements.stepPluginParam(
                    key, index: index, direction: direction, target: numeric, tolerance: tolerance, maxSteps: Swift.min(25, 400 - steps))
                steps += batch.steps
                if let text = batch.lastText { lastText = text }
                if batch.stop == "unreadable" || batch.stop == "failed" || batch.stop == "stalled" {
                    stop = batch.stop
                    break
                }
                if batch.stop == "crossed" { stop = "crossed"; break }
                guard await FilePanelAutomation.pause(ms: 5) else { return .error("Cancelled") }
            }
            let now = AXLogicProElements.readPluginParam(key, index: index)
            let nowText = now.map { $0.valueText.isEmpty ? ($0.fieldText ?? "") : $0.valueText }
            trace.append("3 stepping: \(steps) step(s), stopped: \(stop), last '\(lastText)', now '\(nowText ?? "?")'")
            if Self.textMatches(nowText, target: numeric, tolerance: tolerance) {
                return await pluginParamSuccess("stepped with AXIncrement/AXDecrement", now: now, param: param, beforeText: beforeText, session: session, previous: previousView, trace: trace)
            }
            // Accept the nearest step when stepping crossed the target (the parameter moves in steps).
            if stop == "crossed" || stop == "between steps", let nowNumber = nowText.flatMap({ ComposeSupport.parseDisplayedNumber($0) }),
               let startNumber = ComposeSupport.parseDisplayedNumber(beforeText), abs(nowNumber - numeric) < abs(startNumber - numeric) {
                return await pluginParamSuccess("nearest step (the parameter moves in steps; wanted \(valueText))", now: now, param: param, beforeText: beforeText, session: session, previous: previousView, trace: trace)
            }
            return await pluginParamFailure("Could not set '\(param.label)' to \(valueText): now '\(nowText ?? "?")', before '\(beforeText)'", session: session, previous: previousView, trace: trace)
        }
        trace.append("3 skipped: no numeric value or the current text has no number")
        return await pluginParamFailure("Could not set '\(param.label)' to \(valueText) (before '\(beforeText)'; every strategy was skipped or failed)", session: session, previous: previousView, trace: trace)
    }

    // MARK: - Debug dump

    func debugPlugin(params: [String: String]) async -> ChannelResult {
        let wantedView = (params["view"] ?? "controls").lowercased()
        let maxLines = Swift.min(2_000, Swift.max(20, Int(params["max_lines"] ?? "") ?? 400))
        let begun = await beginPluginWindow(params: params)
        guard let session = begun.session else { return .error(begun.error ?? "Could not open the plug-in window") }
        var trace = session.trace
        var previous: String?
        if wantedView == "controls" {
            let view = await ensureControlsView(key: session.key)
            trace.append(contentsOf: view.notes)
            previous = view.previous
            if let error = view.error { trace.append("ERROR: \(error)") }
        } else if wantedView == "editor" {
            let title = AXLogicProElements.pluginControlText(.view, key: session.key) ?? ""
            if title.lowercased().contains("controls") {
                let choice = await navigatePluginMenu(ref: .view, key: session.key, path: ["Editor"], pressLast: true)
                trace.append(contentsOf: choice.notes)
                if let error = choice.error { trace.append("ERROR: \(error)") }
                _ = await FilePanelAutomation.pause(ms: 500)
                previous = title
            }
        }
        let dump = AXLogicProElements.debugPluginDump(session.key, maxLines: maxLines)
        let restore = await restoreView(key: session.key, previous: previous)
        let closeNote = await endPluginWindow(session)
        trace.append(restore)
        trace.append(closeNote)
        return .success("trace: \(trace.joined(separator: "; "))\n\(dump)")
    }
}
