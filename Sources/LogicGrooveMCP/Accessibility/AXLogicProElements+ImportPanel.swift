import ApplicationServices
import Foundation

/// Small readers for the import panel used by the keyboard import strategy (no typing).
extension AXLogicProElements {
    /// Value of the panel's "Where:" pop-up (the current folder name, for example "Import"). nil when
    /// there is no import panel or no such pop-up.
    static func panelWhereValue() -> String? {
        guard let panel = importPanel() else { return nil }
        for element in AXHelpers.findAllDescendants(of: panel, role: kAXPopUpButtonRole, maxDepth: 14) {
            let title = (AXHelpers.getTitle(element) ?? "").lowercased()
            let description = (AXHelpers.getDescription(element) ?? "").lowercased()
            if title.hasPrefix("where") || description.hasPrefix("where") {
                return stringValue(of: element)
            }
        }
        return nil
    }

    /// Set AXFocused on the panel's column-view browser. Returns a short trace clause.
    static func focusPanelBrowser() -> String {
        guard let panel = importPanel() else { return "no import panel" }
        let browsers = AXHelpers.findAllDescendants(of: panel, role: kAXBrowserRole, maxDepth: 14)
        let browser = browsers.first { (AXHelpers.getDescription($0) ?? "").lowercased().contains("column") } ?? browsers.first
        guard let browser else { return "no AXBrowser in the panel" }
        guard isSettable(browser, kAXFocusedAttribute) else { return "AXBrowser: AXFocused not settable" }
        return AXHelpers.setAttribute(browser, kAXFocusedAttribute, kCFBooleanTrue)
            ? "AXBrowser: AXFocused set" : "AXBrowser: AXFocused set failed"
    }

    /// Whether the panel exposes any AXRow / AXCell with a non-empty string value (file rows).
    static func panelExposesRows() -> Bool {
        guard let panel = importPanel() else { return false }
        for element in AXHelpers.findAllDescendants(of: panel, role: nil, maxDepth: 14) {
            let role = AXHelpers.getRole(element)
            guard role == kAXRowRole || role == kAXCellRole else { continue }
            if let text = AXHelpers.getValue(element) as? String, !text.isEmpty { return true }
        }
        return false
    }
}
