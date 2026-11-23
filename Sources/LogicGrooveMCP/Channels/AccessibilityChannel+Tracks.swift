import ApplicationServices
import CoreGraphics
import Foundation

/// Verified track header commands: mute / solo, rename, delete. Every command reads its result back
/// through Accessibility and returns `.error` with a step trace when the read-back does not match.
/// Straight-line async code; no AX element is held across an `await`.
extension AccessibilityChannel {
    private static func parseWanted(_ params: [String: String], keys: [String]) -> Bool {
        for key in keys {
            guard let text = params[key]?.lowercased() else { continue }
            if text == "false" || text == "0" || text == "no" || text == "off" { return false }
            return true
        }
        return true
    }

    // MARK: - mute / solo

    /// Set the mute or solo state of a track header to `enabled`. Order: read; "already" when equal;
    /// AXPress and re-read after 200 ms; then (only when the state did not change) verified track
    /// selection, Logic to the front, the key M / S, re-read after 250 ms.
    func setHeaderToggle(params: [String: String], toggle: HeaderToggle) async -> ChannelResult {
        guard let index = Int(params["index"] ?? ""), index >= 0 else {
            return .error("Missing or invalid 'index' parameter")
        }
        let keys = toggle == .mute ? ["enabled", "muted"] : ["enabled", "soloed"]
        let wanted = Self.parseWanted(params, keys: keys)
        let label = toggle.label
        let count = AXLogicProElements.trackHeaderCount()
        guard index < count else {
            return .error("Track \(index) does not exist (\(count) track headers visible)")
        }
        var trace: [String] = []
        func traceText() -> String { trace.joined(separator: "; ") }

        guard let control = AXLogicProElements.headerToggleElement(index: index, toggle: toggle) else {
            return .error("Cannot find the \(label) control on track \(index)'s header")
        }
        trace.append("control: \(AXLogicProElements.describeWithValue(control))")
        guard let before = AXLogicProElements.toggleState(control) else {
            return .error("The \(label) state of track \(index) cannot be read (AXValue), so nothing was pressed. Trace: \(traceText())")
        }
        if before == wanted {
            return .success("Track \(index) \(label) is already \(wanted ? "on" : "off")")
        }

        // 1. AXPress.
        let pressed = AXHelpers.performAction(control, kAXPressAction)
        guard await FilePanelAutomation.pause(ms: 200) else { return .error("Cancelled") }
        var after = AXLogicProElements.headerToggleElement(index: index, toggle: toggle).flatMap { AXLogicProElements.toggleState($0) }
        trace.append("AXPress \(pressed ? "ok" : "failed") -> state \(after.map { String($0) } ?? "unreadable")")
        if after == wanted {
            return .success("Track \(index) \(label) is now \(wanted ? "on" : "off") (AXPress)")
        }
        guard after == before else {
            return .error("The \(label) state of track \(index) is unreadable after AXPress. Trace: \(traceText())")
        }

        // 2. Key command on the selected track.
        let selection = await selectTrackVerified(index: index)
        trace.append(contentsOf: selection.trace)
        guard selection.ok else {
            return .error("\(label) of track \(index) did not change with AXPress and the track could not be selected (read back) for the key command. Trace: \(traceText())")
        }
        guard await FilePanelAutomation.ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front for the \(label) key. Trace: \(traceText())")
        }
        let keyCode: CGKeyCode = toggle == .mute ? 46 : 1 // M / S
        guard FilePanelAutomation.postKeyGlobal(keyCode, flags: []) else {
            return .error("Failed to post the \(label) key. Trace: \(traceText())")
        }
        guard await FilePanelAutomation.pause(ms: 250) else { return .error("Cancelled") }
        after = AXLogicProElements.headerToggleElement(index: index, toggle: toggle).flatMap { AXLogicProElements.toggleState($0) }
        trace.append("key \(toggle == .mute ? "M" : "S") -> state \(after.map { String($0) } ?? "unreadable")")
        if after == wanted {
            return .success("Track \(index) \(label) is now \(wanted ? "on" : "off") (key command; track \(index) is now selected)")
        }
        let controlText = AXLogicProElements.headerToggleElement(index: index, toggle: toggle).map { AXLogicProElements.describeWithValue($0) } ?? "control not found"
        return .error("\(label) of track \(index) did not change to \(wanted ? "on" : "off") (AXPress and key M/S tried). Control now: \(controlText). Trace: \(traceText())")
    }

    // MARK: - rename

    /// Rename a track and read the header name back. Tries the AX name field first; when the header
    /// name is unchanged, selects the track (verified), brings Logic to the front, posts Shift+Return
    /// (Logic's Rename Track key command), waits for a focused text field, types with a read-back and
    /// presses Return only when the field holds the wanted name.
    func renameTrackVerified(params: [String: String]) async -> ChannelResult {
        guard let index = Int(params["index"] ?? ""), index >= 0, let name = params["name"] else {
            return .error("Missing 'index' or 'name' parameter")
        }
        guard !name.isEmpty, name.count <= 80 else {
            return .error("name must be 1-80 characters")
        }
        for scalar in name.unicodeScalars where scalar.value < 32 || scalar.value == 127 {
            return .error("name must not contain control characters")
        }
        let count = AXLogicProElements.trackHeaderCount()
        guard index < count else {
            return .error("Track \(index) does not exist (\(count) track headers visible)")
        }
        var trace: [String] = []
        func traceText() -> String { trace.joined(separator: "; ") }

        let before = AXLogicProElements.trackHeaderName(index: index)
        trace.append("name before '\(before ?? "?")'")
        if before == name {
            return .success("Track \(index) is already named '\(name)'")
        }

        // 1. The AX name field.
        if let field = AXLogicProElements.findTrackNameField(trackIndex: index) {
            trace.append("name field: \(AXLogicProElements.describeWithValue(field))")
            if AXLogicProElements.isSettable(field, kAXValueAttribute) {
                let set = AXHelpers.setAttribute(field, kAXValueAttribute, name as CFTypeRef)
                let confirmed = AXHelpers.performAction(field, kAXConfirmAction)
                trace.append("AXValue set \(set ? "ok" : "failed"), AXConfirm \(confirmed ? "ok" : "failed")")
            } else {
                trace.append("AXValue not settable")
            }
        } else {
            trace.append("no name field found in the header")
        }
        guard await FilePanelAutomation.pause(ms: 250) else { return .error("Cancelled") }
        if AXLogicProElements.trackHeaderName(index: index) == name {
            return .success("Track \(index) renamed to '\(name)' (AX name field)")
        }

        // 2. Key command: select, Shift+Return, type, Return.
        let selection = await selectTrackVerified(index: index)
        trace.append(contentsOf: selection.trace)
        guard selection.ok else {
            return .error("The header name did not change through AX and track \(index) could not be selected (read back) for the rename key. Trace: \(traceText())")
        }
        guard await FilePanelAutomation.ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front for the rename key. Trace: \(traceText())")
        }
        let wasTextFocused = AXLogicProElements.focusedIsNonSearchTextField()
        let tokenBefore = AXLogicProElements.focusedElementToken()
        if wasTextFocused {
            return .error("A text field is already focused (\(AXLogicProElements.focusedFieldSummary() ?? "?")); nothing was typed. Trace: \(traceText())")
        }
        guard FilePanelAutomation.postKeyGlobal(36, flags: .maskShift) else {
            return .error("Failed to post Shift+Return. Trace: \(traceText())")
        }
        trace.append("posted Shift+Return")
        var waited = 0
        var fieldFound = false
        while waited <= 1_500 {
            guard await FilePanelAutomation.pause(ms: 100) else { return .error("Cancelled") }
            waited += 100
            if AXLogicProElements.focusedIsNonSearchTextField(),
               AXLogicProElements.focusedElementToken() != tokenBefore {
                fieldFound = true
                break
            }
        }
        guard fieldFound else {
            await FilePanelAutomation.pressEscape()
            trace.append("no text field took the focus within 1.5 s (focus: \(AXLogicProElements.focusedFieldSummary() ?? "none")); pressed Escape")
            return .error("Shift+Return did not open an inline name editor; nothing was typed. Trace: \(traceText())")
        }
        trace.append("name editor focused: \(AXLogicProElements.focusedFieldSummary() ?? "?")")

        guard await FilePanelAutomation.ensureFrontmost() else {
            await FilePanelAutomation.pressEscape()
            return .error("Could not bring Logic Pro to the front before typing. Trace: \(traceText())")
        }
        _ = FilePanelAutomation.postKeyGlobal(0, flags: .maskCommand) // select the old name
        guard await FilePanelAutomation.pause(ms: 120) else { return .error("Cancelled") }
        guard await FilePanelAutomation.typeTextGlobal(name) else {
            await FilePanelAutomation.pressEscape()
            return .error("Failed to type the name. Trace: \(traceText())")
        }
        guard await FilePanelAutomation.pause(ms: 300) else { return .error("Cancelled") }
        let typed = AXLogicProElements.focusedFieldValue() ?? ""
        trace.append("typed, field holds '\(String(typed.prefix(80)))'")
        guard typed == name else {
            await FilePanelAutomation.pressEscape()
            return .error("The name editor does not hold the wanted name ('\(String(typed.prefix(80)))'); pressed Escape, the name is unchanged. Trace: \(traceText())")
        }
        guard FilePanelAutomation.postKeyGlobal(36, flags: []) else {
            return .error("Failed to post Return. Trace: \(traceText())")
        }
        guard await FilePanelAutomation.pause(ms: 300) else { return .error("Cancelled") }
        let finalName = AXLogicProElements.trackHeaderName(index: index)
        trace.append("name after '\(finalName ?? "?")'")
        guard finalName == name else {
            return .error("The header of track \(index) reads '\(finalName ?? "?")' after the rename, not '\(name)'. Trace: \(traceText())")
        }
        return .success("Track \(index) renamed to '\(name)' (Shift+Return, read back)")
    }

    // MARK: - delete

    /// Delete a track: verified selection, Logic to the front, Cmd+Delete, press "Delete" on the
    /// confirmation alert when Logic asks (tracks with regions), success only when the header count
    /// dropped by exactly one.
    func deleteTrackVerified(params: [String: String]) async -> ChannelResult {
        guard let index = Int(params["index"] ?? ""), index >= 0 else {
            return .error("delete requires 'index' (0-based): nothing was deleted")
        }
        let before = AXLogicProElements.trackHeaderCount()
        guard index < before else {
            return .error("Track \(index) does not exist (\(before) track headers visible); nothing was deleted")
        }
        var trace: [String] = []
        func traceText() -> String { trace.joined(separator: "; ") }

        let selection = await selectTrackVerified(index: index)
        trace.append(contentsOf: selection.trace)
        guard selection.ok else {
            return .error("Track \(index) could not be selected (read back); nothing was deleted. Trace: \(traceText())")
        }
        let nameBefore = AXLogicProElements.trackHeaderName(index: index) ?? "?"
        trace.append("deleting track \(index) '\(nameBefore)' (headers: \(before))")
        guard await FilePanelAutomation.ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front; nothing was deleted. Trace: \(traceText())")
        }
        guard AXLogicProElements.selectedTrackIndex() == index else {
            return .error("The selection moved away from track \(index) before the delete key; nothing was deleted. Trace: \(traceText())")
        }
        guard FilePanelAutomation.postKeyGlobal(51, flags: .maskCommand) else {
            return .error("Failed to post Cmd+Delete; nothing was deleted. Trace: \(traceText())")
        }
        trace.append("posted Cmd+Delete")

        // Logic asks for confirmation when the track has regions: press "Delete" when that alert shows.
        var waited = 0
        var current = AXLogicProElements.trackHeaderCount()
        while waited <= 1_500, current == before {
            guard await FilePanelAutomation.pause(ms: 100) else { return .error("Cancelled") }
            waited += 100
            if let pressed = AXLogicProElements.pressConfirmingAlertButton(exactTitle: "Delete") {
                trace.append("pressed '\(pressed)' on the confirmation alert after \(waited) ms")
                break
            }
            current = AXLogicProElements.trackHeaderCount()
        }
        waited = 0
        current = AXLogicProElements.trackHeaderCount()
        while waited <= 2_000, current == before {
            guard await FilePanelAutomation.pause(ms: 150) else { return .error("Cancelled") }
            waited += 150
            current = AXLogicProElements.trackHeaderCount()
        }
        trace.append("headers after: \(current)")
        guard current == before - 1 else {
            return .error("Expected \(before - 1) track headers after deleting track \(index) but see \(current). Trace: \(traceText())")
        }
        return .success("Deleted track \(index) '\(nameBefore)' (track headers \(before) -> \(current)). Trace: \(traceText())")
    }
}
