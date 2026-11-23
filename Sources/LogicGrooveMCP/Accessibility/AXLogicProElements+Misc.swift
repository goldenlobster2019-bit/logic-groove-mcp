import ApplicationServices
import CoreGraphics
import Foundation

/// Small finders added in 0.4.3: the "additional content" download prompt, the project window focus and
/// the transport Stop control. All synchronous; nothing here holds an element across an await.
extension AXLogicProElements {
    /// Text recorded in the trace of every call that dismissed Logic's download prompt.
    static let downloadPromptTraceText = "dismissed Logic's download prompt (Cancel)"

    // MARK: - Download prompt

    /// Logic shows a small untitled dialog ("This project requires additional content. Do you want to
    /// download it now?", buttons Cancel and Download) after a MIDI import whose patch has missing
    /// content. It blocks track selection. Finds a sheet or non-project window that has BOTH a button
    /// titled exactly "Download" and one titled exactly "Cancel", presses Cancel and returns a
    /// description for the trace. nil when there is no such dialog (or Cancel could not be pressed).
    static func dismissDownloadPrompt() -> String? {
        var containers: [AXUIElement] = allSheets()
        for window in dialogCandidates() {
            if isProjectWindowTitle(AXHelpers.getTitle(window) ?? "") { continue }
            containers.append(window)
        }
        for container in containers {
            let buttons = AXHelpers.findAllDescendants(of: container, role: kAXButtonRole, maxDepth: 8)
            var hasDownload = false
            var cancel: AXUIElement?
            for button in buttons {
                let title = AXHelpers.getTitle(button) ?? ""
                if title == "Download" { hasDownload = true }
                if title == "Cancel" && isEnabled(button) { cancel = button }
            }
            guard hasDownload, let cancel else { continue }
            if AXHelpers.performAction(cancel, kAXPressAction) {
                let text = String(containerText(container).prefix(80))
                return "\(downloadPromptTraceText) [\(text)]"
            }
        }
        return nil
    }

    // MARK: - Project window focus

    /// Make the project (arrange) window the main and focused window of Logic (a plug-in window takes
    /// both roles while it is up). Returns true when the raise action was accepted.
    static func raiseProjectWindow() -> Bool {
        guard let window = projectWindow() else { return false }
        _ = AXHelpers.setAttribute(window, kAXMainAttribute, kCFBooleanTrue)
        _ = AXHelpers.setAttribute(window, kAXFocusedAttribute, kCFBooleanTrue)
        return AXHelpers.performAction(window, kAXRaiseAction)
    }

    // MARK: - Transport

    /// The control bar's Stop button: an AXButton titled "Stop" (while stopped Logic titles it
    /// "Go to Beginning", so nil means "not playing" as far as this button goes).
    static func transportStopButton() -> AXUIElement? {
        guard let transport = getTransportBar() else { return nil }
        if let button = AXHelpers.findDescendant(of: transport, role: kAXButtonRole, title: "Stop", maxDepth: 6) {
            return button
        }
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 6)
        return buttons.first { (AXHelpers.getDescription($0) ?? "") == "Stop" }
    }

    /// The control bar's Play checkbox, nil when it cannot be found.
    static func transportPlayControl() -> AXUIElement? {
        findTransportButton(named: "Play")
    }
}
