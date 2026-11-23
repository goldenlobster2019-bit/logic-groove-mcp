import ApplicationServices
import Foundation

/// Finders for Logic's Bounce dialog (File > Bounce > Project or Section...). The dialog structure has NOT
/// been inspected live yet: everything matches by title and role and the callers record what they saw.
extension AXLogicProElements {
    /// The window whose title starts with "Bounce" (case-insensitive), nil when there is none.
    static func bounceWindow() -> AXUIElement? {
        for window in dialogCandidates() {
            let title = (AXHelpers.getTitle(window) ?? "").lowercased()
            if isProjectWindowTitle(title) { continue }
            if title.hasPrefix("bounce") { return window }
        }
        return nil
    }

    /// Compact summary of the Bounce dialog's controls (roles, titles, values; at most `limit` lines).
    static func bounceControlSummary(limit: Int = 40) -> [String] {
        guard let window = bounceWindow() else { return ["no Bounce window"] }
        let roles: Set<String> = [
            kAXButtonRole, kAXCheckBoxRole, kAXPopUpButtonRole, kAXRadioButtonRole, kAXTextFieldRole,
            kAXMenuButtonRole, kAXComboBoxRole,
        ]
        var lines: [String] = []
        for element in AXHelpers.findAllDescendants(of: window, role: nil, maxDepth: 12) {
            guard let role = AXHelpers.getRole(element), roles.contains(role) else { continue }
            let title = AXHelpers.getTitle(element) ?? ""
            let description = AXHelpers.getDescription(element) ?? ""
            let value = stringValue(of: element) ?? ""
            if title.isEmpty && description.isEmpty && value.isEmpty { continue }
            lines.append("\(role) title='\(title)' desc='\(description)' value='\(value)' enabled=\(isEnabled(element))")
            if lines.count >= limit { break }
        }
        if lines.isEmpty { lines.append("the Bounce window shows no titled controls") }
        return lines
    }

    /// Make sure a radio button or checkbox titled "Offline" (title or description) is on. Returns a trace
    /// note, nil when no such control exists.
    static func bounceSelectOffline() -> String? {
        guard let window = bounceWindow() else { return nil }
        let candidates = AXHelpers.findAllDescendants(of: window, role: kAXRadioButtonRole, maxDepth: 12)
            + AXHelpers.findAllDescendants(of: window, role: kAXCheckBoxRole, maxDepth: 12)
        for element in candidates {
            let label = ((AXHelpers.getTitle(element) ?? "") + " " + (AXHelpers.getDescription(element) ?? "")).lowercased()
            guard label.contains("offline") else { continue }
            if toggleState(element) == true { return "Offline already selected" }
            let pressed = AXHelpers.performAction(element, kAXPressAction)
            usleep(250_000)
            let after = toggleState(element)
            return "Offline: AXPress \(pressed ? "ok" : "failed"), now \(after.map { String($0) } ?? "unreadable")"
        }
        return nil
    }

    /// Press the Bounce dialog's confirm button: a button titled one of `titles` (in that order,
    /// case-insensitive), else the default button. Returns the pressed title or nil.
    static func pressBounceConfirm(titles: [String]) -> String? {
        guard let window = bounceWindow() else { return nil }
        let buttons = AXHelpers.findAllDescendants(of: window, role: kAXButtonRole, maxDepth: 12)
        for wanted in titles {
            for button in buttons {
                let title = AXHelpers.getTitle(button) ?? ""
                if title.lowercased() == wanted.lowercased() && isEnabled(button) {
                    if AXHelpers.performAction(button, kAXPressAction) { return title }
                }
            }
        }
        let defaultButton: AXUIElement? = AXHelpers.getAttribute(window, kAXDefaultButtonAttribute)
        if let defaultButton, isEnabled(defaultButton), AXHelpers.performAction(defaultButton, kAXPressAction) {
            return AXHelpers.getTitle(defaultButton) ?? "default button"
        }
        return nil
    }

    /// Press Cancel on the Bounce dialog. True when a Cancel button was pressed.
    static func cancelBounceWindow() -> Bool {
        guard let window = bounceWindow() else { return false }
        for button in AXHelpers.findAllDescendants(of: window, role: kAXButtonRole, maxDepth: 12) {
            if (AXHelpers.getTitle(button) ?? "").lowercased() == "cancel" && isEnabled(button) {
                if AXHelpers.performAction(button, kAXPressAction) { return true }
            }
        }
        return false
    }
}
