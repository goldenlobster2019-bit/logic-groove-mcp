import ApplicationServices
import CoreGraphics
import Foundation

/// Drives macOS open / save panels hosted by Logic Pro (Cmd+Shift+G "Go to the folder",
/// default button, replace alerts). All entry points take and return Sendable values only;
/// AX elements are looked up inside, so nothing non-Sendable crosses an async boundary.
enum FilePanelAutomation {
    // MARK: - Timing

    /// Sleep; false when the task was cancelled.
    static func pause(ms: Int) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(ms))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Keyboard

    /// Bring Logic Pro to the front (it discards posted key events otherwise).
    static func ensureFrontmost() async -> Bool {
        if Task.isCancelled { return false }
        if ProcessUtils.isLogicProFrontmost { return true }
        guard ProcessUtils.activateLogicPro() else { return false }
        for _ in 0..<20 {
            guard await pause(ms: 25) else { return false }
            if ProcessUtils.isLogicProFrontmost { return true }
        }
        return false
    }

    /// Post a key-down/key-up pair to Logic Pro.
    static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }

    /// Post a key to the HID event tap (the frontmost app). Logic's Open/Save panels are
    /// hosted out of process, so keys meant for them must go to whatever is frontmost,
    /// not to Logic's pid. Callers must ensureFrontmost() first.
    static func postKeyGlobal(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Type text to the frontmost app in chunks. A single unicode CGEvent carries at most
    /// ~20 UTF-16 units (the rest is silently dropped), so long paths must be split.
    static func typeTextGlobal(_ text: String) async -> Bool {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + 16, units.count)
            let chunk = Array(units[index..<end])
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            chunk.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            index = end
            guard await pause(ms: 20) else { return false }
        }
        return true
    }

    /// Type a string with a unicode CGEvent (same approach as CGEventChannel.postText).
    static func postText(_ text: String, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }
        let characters = Array(text.utf16)
        characters.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }

    /// Press Escape in Logic Pro (closes stray menus / popups after a failed step).
    static func pressEscape() async {
        guard let pid = ProcessUtils.logicProPID() else { return }
        guard await ensureFrontmost() else { return }
        _ = postKey(53, flags: [], pid: pid)
    }

    // MARK: - Panels

    /// Poll (every 100 ms) until an open / save panel shows up.
    static func waitForPanel(timeoutMs: Int = 5_000) async -> Bool {
        var waited = 0
        while waited <= timeoutMs {
            if AXLogicProElements.filePanel() != nil { return true }
            guard await pause(ms: 100) else { return false }
            waited += 100
        }
        return false
    }

    /// Poll until the panel is gone.
    static func waitForPanelToClose(timeoutMs: Int = 5_000) async -> Bool {
        var waited = 0
        while waited <= timeoutMs {
            if AXLogicProElements.filePanel() == nil { return true }
            guard await pause(ms: 100) else { return false }
            waited += 100
        }
        return false
    }

    /// Poll (every 100 ms) until the import panel (see AXLogicProElements.importPanel) shows up.
    static func waitForImportPanel(timeoutMs: Int = 5_000) async -> Bool {
        var waited = 0
        while waited <= timeoutMs {
            if AXLogicProElements.importPanel() != nil { return true }
            guard await pause(ms: 100) else { return false }
            waited += 100
        }
        return false
    }

    /// Poll until the import panel is gone.
    static func waitForImportPanelToClose(timeoutMs: Int = 5_000) async -> Bool {
        var waited = 0
        while waited <= timeoutMs {
            if AXLogicProElements.importPanel() == nil { return true }
            guard await pause(ms: 100) else { return false }
            waited += 100
        }
        return false
    }

    /// Result of the Go to folder step: an error (nil on success) and short trace notes.
    struct GoToOutcome: Sendable {
        let error: String?
        let notes: [String]
    }

    /// With a panel showing: Cmd+Shift+G, then (only once the Go to text field is confirmed
    /// through AX) Cmd+A, type `path`, Return. Never types blind. `path` may be a folder or a
    /// file. When the field does not show up, Escape is pressed once and an error is returned
    /// without having typed anything; the caller should cancel the panel if it is still up.
    static func goToChecked(path: String) async -> GoToOutcome {
        var notes: [String] = []
        func fail(_ message: String) -> GoToOutcome {
            GoToOutcome(error: message, notes: notes)
        }
        guard await ensureFrontmost() else {
            return fail("Could not bring Logic Pro to the front")
        }
        let focusBefore = AXLogicProElements.focusedFieldSummary()
        let sheetsBefore = AXLogicProElements.allSheets().count
        guard postKeyGlobal(5, flags: [.maskCommand, .maskShift]) else {
            return fail("Failed to post Cmd+Shift+G")
        }

        // Poll up to 3 s for a focused text field (not the search field) that is new.
        var waited = 0
        var fieldSummary: String?
        var latest: String?
        while waited <= 3_000 {
            guard await pause(ms: 100) else { return fail("Cancelled") }
            waited += 100
            latest = AXLogicProElements.focusedFieldSummary()
            if AXLogicProElements.focusedIsNonSearchTextField(),
               latest != focusBefore || AXLogicProElements.allSheets().count > sheetsBefore {
                fieldSummary = latest
                break
            }
        }
        guard let fieldSummary else {
            notes.append("go-to field not found, focus: \(latest ?? "none")")
            await pressEscape()
            return fail("The Go to folder field did not appear after Cmd+Shift+G (focus: \(latest ?? "none")); nothing was typed")
        }
        notes.append("go-to field: \(fieldSummary)")

        guard await pause(ms: 150) else { return fail("Cancelled") }
        guard await ensureFrontmost() else { return fail("Could not bring Logic Pro to the front") }
        // Re-check right before typing: the focus must still be the confirmed field.
        guard AXLogicProElements.focusedIsNonSearchTextField() else {
            notes.append("focus left the go-to field before typing")
            await pressEscape()
            return fail("Focus left the Go to folder field before typing; nothing was typed")
        }
        _ = postKeyGlobal(0, flags: .maskCommand) // select the pre-filled path
        guard await pause(ms: 80) else { return fail("Cancelled") }
        guard await typeTextGlobal(path) else { return fail("Failed to type the path") }
        guard await pause(ms: 500) else { return fail("Cancelled") } // let the suggestion list update
        let typed = AXLogicProElements.focusedFieldValue() ?? ""
        let matches = typed == path
        notes.append("typed \(path.count) chars, field now has \(typed.count) chars, matches=\(matches)")
        let summaryAtReturn = AXLogicProElements.focusedFieldSummary()

        guard await ensureFrontmost() else { return fail("Could not bring Logic Pro to the front") }
        guard postKeyGlobal(36, flags: []) else { return fail("Failed to press Return in Go to Folder") }

        // Poll up to 3 s for the field to go away (focus changes or the sheet closes).
        waited = 0
        var gone = false
        while waited <= 3_000 {
            guard await pause(ms: 100) else { return fail("Cancelled") }
            waited += 100
            if AXLogicProElements.focusedFieldSummary() != summaryAtReturn
                || !AXLogicProElements.focusedIsNonSearchTextField() {
                gone = true
                break
            }
        }
        notes.append(gone ? "go-to field closed" : "go-to field still focused 3 s after Return")
        guard await pause(ms: 300) else { return fail("Cancelled") }
        return GoToOutcome(error: nil, notes: notes)
    }

    /// With a panel showing: Cmd+Shift+G, enter `path`, Return (see goToChecked).
    /// Returns nil on success, otherwise an error message.
    static func goTo(path: String, pid: pid_t) async -> String? {
        let outcome = await goToChecked(path: path)
        if let error = outcome.error {
            Log.warn("goTo failed: \(error); \(outcome.notes.joined(separator: "; "))", subsystem: "ax")
        }
        return outcome.error
    }

    /// Press the panel's confirm button (Import / Open / Save / default). Returns the pressed title.
    static func confirmPanel(buttonTitles: [String]) -> String? {
        AXLogicProElements.pressPanelButton(titles: buttonTitles)
    }

    /// For up to `timeoutMs`, look for a tempo-import question and answer it without importing tempo.
    /// Returns a description of what was found / pressed, nil when no such dialog appeared.
    static func handleTempoDialog(timeoutMs: Int = 3_000) async -> String? {
        var waited = 0
        while waited <= timeoutMs {
            if let outcome = AXLogicProElements.resolveTempoDialog() { return outcome }
            guard await pause(ms: 100) else { return nil }
            waited += 100
        }
        return nil
    }

    /// For up to `timeoutMs`, press a "Replace" button if an overwrite alert appears.
    static func handleReplaceAlert(timeoutMs: Int = 1_500) async -> String? {
        var waited = 0
        while waited <= timeoutMs {
            if let title = AXLogicProElements.pressAlertButton(titleContaining: "replace") { return title }
            guard await pause(ms: 100) else { return nil }
            waited += 100
        }
        return nil
    }

    /// Poll for a file to exist on disk.
    static func waitForFile(atPath path: String, timeoutMs: Int = 5_000) async -> Bool {
        var waited = 0
        while waited <= timeoutMs {
            if FileManager.default.fileExists(atPath: path) { return true }
            guard await pause(ms: 100) else { return false }
            waited += 100
        }
        return false
    }
}
