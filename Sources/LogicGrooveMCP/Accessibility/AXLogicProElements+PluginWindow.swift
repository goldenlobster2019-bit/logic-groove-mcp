import ApplicationServices
import CoreGraphics
import Foundation

/// Identifies one plug-in window without holding an AX element: the plug-in name (the window header
/// holds an AXStaticText with it) and the track name (the window title).
struct PluginWindowKey: Sendable, Equatable {
    let pluginName: String
    let trackName: String
}

/// A control of a plug-in window that opens a menu.
enum PluginControlRef: Sendable, Equatable {
    /// Logic's settings menu: the header AXPopUpButton whose value is the current setting name.
    case settings
    /// The AXMenuButton described "view" (Editor / Controls / zoom).
    case view
    /// A plug-in specific AXPopUpButton, 0-based among all pop-ups except the settings pop-up.
    case popup(Int)
}

/// Result of looking for / pressing one menu entry. Only Sendable values.
struct PluginMenuStep: Sendable {
    let found: Bool
    let pressedTitle: String
    /// Titles of the level that was searched (non-empty ones, at most 60).
    let titles: [String]
    let note: String
}

/// One parameter of the Controls view. Only Sendable values.
struct PluginParam: Sendable {
    let index: Int
    let label: String
    let valueText: String
    let raw: Double?
    let minValue: Double?
    let maxValue: Double?
    let sliderSettable: Bool
    let hasField: Bool
    let fieldSettable: Bool
    let fieldText: String?
}

/// Outcome of a batch of AXIncrement / AXDecrement steps on one parameter.
struct PluginParamStepOutcome: Sendable {
    let steps: Int
    let lastText: String?
    /// "target", "crossed", "stalled", "unreadable", "failed" or "limit".
    let stop: String
}

/// Plug-in window finders and readers (verified live: the window is an AXWindow / AXDialog titled with the
/// track name; its direct children are close, toolbar, link, view menu button, "View:" text, bypass,
/// compare, three segment groups, the settings pop-up, optionally a group of plug-in specific pop-ups, then
/// static texts with the plug-in name and the track name). The Controls view structure is UNVERIFIED.
/// All synchronous; elements never leave these functions.
extension AXLogicProElements {
    // MARK: - Finding the window

    private static func windowTextValues(_ window: AXUIElement) -> [String] {
        var values: [String] = []
        for child in AXHelpers.getChildren(window) where AXHelpers.getRole(child) == kAXStaticTextRole {
            if let value = stringValue(of: child), !value.isEmpty {
                values.append(value)
            } else if let title = AXHelpers.getTitle(child), !title.isEmpty {
                values.append(title)
            }
        }
        return values
    }

    /// The open plug-in window for `key` (a non-project window with an AXStaticText holding the plug-in
    /// name; an exact name match wins over a loose one; the window titled like the track wins among several).
    static func pluginWindow(for key: PluginWindowKey) -> AXUIElement? {
        var exact: [AXUIElement] = []
        var loose: [AXUIElement] = []
        let wanted = key.pluginName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for window in allWindows() {
            let title = AXHelpers.getTitle(window) ?? ""
            if isProjectWindowTitle(title) { continue }
            let values = windowTextValues(window)
            if values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted }) {
                exact.append(window)
            } else if values.contains(where: { ComposeSupport.pluginNameMatches($0, key.pluginName) }) {
                loose.append(window)
            }
        }
        let candidates = exact.isEmpty ? loose : exact
        if candidates.isEmpty { return nil }
        let track = key.trackName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !track.isEmpty {
            for window in candidates {
                let title = (AXHelpers.getTitle(window) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if title == track { return window }
            }
        }
        return candidates.first
    }

    static func pluginWindowExists(_ key: PluginWindowKey) -> Bool {
        pluginWindow(for: key) != nil
    }

    static func pluginWindowTitle(_ key: PluginWindowKey) -> String? {
        pluginWindow(for: key).flatMap { AXHelpers.getTitle($0) }
    }

    /// Press the AX close button of the plug-in window. False when there is no window or no close button.
    static func pressPluginWindowClose(_ key: PluginWindowKey) -> Bool {
        guard let window = pluginWindow(for: key) else { return false }
        if let button = AXHelpers.findChild(of: window, role: kAXButtonRole, description: "close"),
           AXHelpers.performAction(button, kAXPressAction) {
            return true
        }
        if let button = closeButton(of: window) {
            return AXHelpers.performAction(button, kAXPressAction)
        }
        return false
    }

    // MARK: - Controls of the window

    private static func settingsPopupElement(in window: AXUIElement) -> AXUIElement? {
        if let direct = AXHelpers.findChild(of: window, role: kAXPopUpButtonRole) { return direct }
        return AXHelpers.findDescendant(of: window, role: kAXPopUpButtonRole, maxDepth: 4)
    }

    private static func pluginPopupElements(in window: AXUIElement) -> [AXUIElement] {
        let settings = settingsPopupElement(in: window)
        let all = AXHelpers.findAllDescendants(of: window, role: kAXPopUpButtonRole, maxDepth: 8)
        return all.filter { element in
            if let settings, CFEqual(settings, element) { return false }
            return true
        }
    }

    private static func viewButtonElement(in window: AXUIElement) -> AXUIElement? {
        if let direct = AXHelpers.findChild(of: window, role: kAXMenuButtonRole, description: "view") { return direct }
        return AXHelpers.findDescendant(of: window, role: kAXMenuButtonRole, description: "view", maxDepth: 4)
    }

    private static func controlElement(_ ref: PluginControlRef, in window: AXUIElement) -> AXUIElement? {
        switch ref {
        case .settings:
            return settingsPopupElement(in: window)
        case .view:
            return viewButtonElement(in: window)
        case .popup(let index):
            let popups = pluginPopupElements(in: window)
            return popups.indices.contains(index) ? popups[index] : nil
        }
    }

    /// Number of plug-in specific pop-ups in the window.
    static func pluginPopupCount(_ key: PluginWindowKey) -> Int {
        guard let window = pluginWindow(for: key) else { return 0 }
        return pluginPopupElements(in: window).count
    }

    /// Current text of a control: the AXValue of a pop-up (AXTitle as fallback), the AXTitle of the view button.
    static func pluginControlText(_ ref: PluginControlRef, key: PluginWindowKey) -> String? {
        guard let window = pluginWindow(for: key), let element = controlElement(ref, in: window) else { return nil }
        if ref == .view {
            if let title = AXHelpers.getTitle(element), !title.isEmpty { return title }
            return stringValue(of: element)
        }
        if let value = stringValue(of: element), !value.isEmpty { return value }
        return AXHelpers.getTitle(element)
    }

    /// Press a control with a short AX messaging timeout (the press returns an error while the pop-up menu
    /// tracks). Returns the raw AXError code (recorded only), nil when the control is missing.
    static func pressPluginControl(_ ref: PluginControlRef, key: PluginWindowKey) -> Int32? {
        guard let window = pluginWindow(for: key), let element = controlElement(ref, in: window) else { return nil }
        _ = AXUIElementSetMessagingTimeout(element, 0.7)
        let code = AXUIElementPerformAction(element, kAXPressAction as CFString)
        _ = AXUIElementSetMessagingTimeout(element, 0)
        return code.rawValue
    }

    /// Ask the control to show its menu (alternative to AXPress). Raw AXError code, nil when missing.
    static func showPluginControlMenu(_ ref: PluginControlRef, key: PluginWindowKey) -> Int32? {
        guard let window = pluginWindow(for: key), let element = controlElement(ref, in: window) else { return nil }
        _ = AXUIElementSetMessagingTimeout(element, 0.7)
        let code = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
        _ = AXUIElementSetMessagingTimeout(element, 0)
        return code.rawValue
    }

    // MARK: - Menus opened by a control

    /// The pop-up menu a control opened: an AXMenu child of the control, else any open menu of the app.
    private static func openedControlMenu(_ ref: PluginControlRef, key: PluginWindowKey) -> AXUIElement? {
        guard let window = pluginWindow(for: key), let element = controlElement(ref, in: window) else { return nil }
        if let menu = AXHelpers.findChild(of: element, role: kAXMenuRole) { return menu }
        return openedMenu(near: element)
    }

    /// Match one menu entry by title: exact (case-insensitive, ellipsis-tolerant) first, then a unique substring.
    private static func matchEntry(_ entries: [AXUIElement], _ wanted: String) -> (element: AXUIElement?, ambiguous: Bool) {
        let needle = ComposeSupport.normalizeMenuTitle(wanted)
        guard !needle.isEmpty else { return (nil, false) }
        for entry in entries {
            let title = ComposeSupport.normalizeMenuTitle(AXHelpers.getTitle(entry) ?? "")
            if !title.isEmpty && title == needle { return (entry, false) }
        }
        var partial: [AXUIElement] = []
        for entry in entries {
            let title = ComposeSupport.normalizeMenuTitle(AXHelpers.getTitle(entry) ?? "")
            if !title.isEmpty && title.contains(needle) { partial.append(entry) }
        }
        if partial.count == 1 { return (partial[0], false) }
        return (nil, partial.count > 1)
    }

    private static func entryTitles(_ entries: [AXUIElement]) -> [String] {
        let titles = entries.compactMap { AXHelpers.getTitle($0) }.filter { !$0.isEmpty }
        return Array(titles.prefix(60))
    }

    /// The menu container reached by following `path` (item titles) from the opened menu. nil when the menu
    /// is not open or a component is missing.
    private static func menuContainer(_ ref: PluginControlRef, key: PluginWindowKey, path: [String]) -> AXUIElement? {
        guard var current = openedControlMenu(ref, key: key) else { return nil }
        for component in path {
            let match = matchEntry(menuEntries(of: current), component)
            guard let element = match.element else { return nil }
            current = element
        }
        return current
    }

    /// Titles of the entries at `path` (an empty path is the first level). found is false when the menu is
    /// not open or the path cannot be followed.
    static func pluginMenuTitles(_ ref: PluginControlRef, key: PluginWindowKey, path: [String]) -> (found: Bool, titles: [String]) {
        guard let container = menuContainer(ref, key: key, path: path) else { return (false, []) }
        return (true, entryTitles(menuEntries(of: container)))
    }

    /// Press the entry titled `title` at the level `path`. On failure `titles` lists that level.
    static func pressPluginMenuEntry(_ ref: PluginControlRef, key: PluginWindowKey, path: [String], title: String) -> PluginMenuStep {
        guard let container = menuContainer(ref, key: key, path: path) else {
            return PluginMenuStep(found: false, pressedTitle: "", titles: [], note: "the menu is not open or the path '\(path.joined(separator: "/"))' was not found")
        }
        let entries = menuEntries(of: container)
        let match = matchEntry(entries, title)
        guard let element = match.element else {
            let note = match.ambiguous ? "'\(title)' matches several entries" : "'\(title)' not found"
            return PluginMenuStep(found: false, pressedTitle: "", titles: entryTitles(entries), note: note)
        }
        let pressedTitle = AXHelpers.getTitle(element) ?? title
        guard isEnabled(element) else {
            return PluginMenuStep(found: false, pressedTitle: pressedTitle, titles: entryTitles(entries), note: "'\(pressedTitle)' is disabled")
        }
        guard AXHelpers.performAction(element, kAXPressAction) else {
            return PluginMenuStep(found: false, pressedTitle: pressedTitle, titles: entryTitles(entries), note: "AXPress on '\(pressedTitle)' failed")
        }
        return PluginMenuStep(found: true, pressedTitle: pressedTitle, titles: [], note: "pressed '\(pressedTitle)'")
    }

    // MARK: - Parameters of the Controls view

    private struct ParamElements {
        let slider: AXUIElement
        let field: AXUIElement?
        let label: String
    }

    private static func paramNumber(_ element: AXUIElement) -> Double? {
        guard let value = AXHelpers.getValue(element) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    private static func textOf(_ element: AXUIElement) -> String {
        if let value = stringValue(of: element), !value.isEmpty { return value }
        return AXHelpers.getTitle(element) ?? ""
    }

    private static func collectParams(_ container: AXUIElement, depth: Int, into result: inout [ParamElements]) {
        let children = AXHelpers.getChildren(container)
        let roles = children.map { AXHelpers.getRole($0) ?? "" }
        var lastText: String?
        for (position, child) in children.enumerated() {
            let role = roles[position]
            if role == kAXStaticTextRole {
                let text = textOf(child).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lastText = text }
                continue
            }
            if role == kAXSliderRole {
                // The numeric field: the nearest text field among the siblings.
                var field: AXUIElement?
                var bestDistance = Int.max
                for (otherPosition, other) in children.enumerated() where roles[otherPosition] == kAXTextFieldRole {
                    let distance = abs(otherPosition - position)
                    if distance < bestDistance { bestDistance = distance; field = other }
                }
                var label = (AXHelpers.getTitle(child) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if label.isEmpty { label = (AXHelpers.getDescription(child) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                if label.isEmpty { label = lastText ?? "" }
                if label.isEmpty, let field {
                    label = (AXHelpers.getTitle(field) ?? AXHelpers.getDescription(field) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if label.isEmpty { label = "param \(result.count)" }
                result.append(ParamElements(slider: child, field: field, label: label))
                continue
            }
            if depth < 8 {
                collectParams(child, depth: depth + 1, into: &result)
            }
        }
    }

    private static func paramElements(_ key: PluginWindowKey) -> [ParamElements] {
        guard let window = pluginWindow(for: key) else { return [] }
        var result: [ParamElements] = []
        collectParams(window, depth: 0, into: &result)
        return result
    }

    private static func paramValueText(_ elements: ParamElements) -> String {
        let description: String? = AXHelpers.getAttribute(elements.slider, kAXValueDescriptionAttribute)
        if let description, !description.isEmpty { return description }
        if let field = elements.field {
            let text = textOf(field)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private static func paramInfo(_ elements: ParamElements, index: Int) -> PluginParam {
        let minValue: NSNumber? = AXHelpers.getAttribute(elements.slider, kAXMinValueAttribute)
        let maxValue: NSNumber? = AXHelpers.getAttribute(elements.slider, kAXMaxValueAttribute)
        let fieldText = elements.field.map { textOf($0) }
        return PluginParam(
            index: index, label: elements.label, valueText: paramValueText(elements),
            raw: paramNumber(elements.slider), minValue: minValue?.doubleValue, maxValue: maxValue?.doubleValue,
            sliderSettable: isSettable(elements.slider, kAXValueAttribute),
            hasField: elements.field != nil,
            fieldSettable: elements.field.map { isSettable($0, kAXValueAttribute) } ?? false,
            fieldText: fieldText)
    }

    /// Every AXSlider of the plug-in window (recursively, depth 8) as a parameter.
    static func readPluginParams(_ key: PluginWindowKey) -> [PluginParam] {
        let all = paramElements(key)
        var result: [PluginParam] = []
        for (index, elements) in all.enumerated() {
            result.append(paramInfo(elements, index: index))
        }
        return result
    }

    /// One parameter again (fresh read), nil when the index no longer exists.
    static func readPluginParam(_ key: PluginWindowKey, index: Int) -> PluginParam? {
        let all = paramElements(key)
        guard all.indices.contains(index) else { return nil }
        return paramInfo(all[index], index: index)
    }

    /// Set the slider's AXValue to a raw number.
    static func setPluginParamRaw(_ key: PluginWindowKey, index: Int, raw: Double) -> Bool {
        let all = paramElements(key)
        guard all.indices.contains(index) else { return false }
        return AXHelpers.setAttribute(all[index].slider, kAXValueAttribute, NSNumber(value: raw))
    }

    /// Write text into the numeric field of a parameter and send AXConfirm. (written, confirmed).
    static func setPluginParamText(_ key: PluginWindowKey, index: Int, text: String) -> (written: Bool, confirmed: Bool) {
        let all = paramElements(key)
        guard all.indices.contains(index), let field = all[index].field else { return (false, false) }
        let written = AXHelpers.setAttribute(field, kAXValueAttribute, text as CFTypeRef)
        let confirmed = AXHelpers.performAction(field, kAXConfirmAction)
        return (written, confirmed)
    }

    /// Up to `maxSteps` AXIncrement / AXDecrement steps on a parameter, reading the displayed number after
    /// each one. Stops at the target (within `tolerance`), when the number crossed it (then steps back once
    /// when the previous reading was nearer), when the text did not change, or at the limit.
    static func stepPluginParam(
        _ key: PluginWindowKey, index: Int, direction: Int, target: Double, tolerance: Double, maxSteps: Int
    ) -> PluginParamStepOutcome {
        let all = paramElements(key)
        guard all.indices.contains(index) else {
            return PluginParamStepOutcome(steps: 0, lastText: nil, stop: "unreadable")
        }
        let elements = all[index]
        let action = direction > 0 ? kAXIncrementAction : kAXDecrementAction
        let reverse = direction > 0 ? kAXDecrementAction : kAXIncrementAction
        var previousText = paramValueText(elements)
        var previousNumber = ComposeSupport.parseDisplayedNumber(previousText)
        var steps = 0
        while steps < maxSteps {
            guard AXUIElementPerformAction(elements.slider, action as CFString) == .success else {
                return PluginParamStepOutcome(steps: steps, lastText: previousText, stop: "failed")
            }
            steps += 1
            usleep(20_000)
            var text = paramValueText(elements)
            var retries = 0
            while text == previousText && retries < 3 {
                usleep(30_000)
                text = paramValueText(elements)
                retries += 1
            }
            if text == previousText {
                return PluginParamStepOutcome(steps: steps, lastText: text, stop: "stalled")
            }
            guard let number = ComposeSupport.parseDisplayedNumber(text) else {
                return PluginParamStepOutcome(steps: steps, lastText: text, stop: "unreadable")
            }
            if abs(number - target) <= tolerance {
                return PluginParamStepOutcome(steps: steps, lastText: text, stop: "target")
            }
            let crossed = (direction > 0 && number > target) || (direction < 0 && number < target)
            if crossed {
                if let previousNumber, abs(previousNumber - target) < abs(number - target),
                   AXUIElementPerformAction(elements.slider, reverse as CFString) == .success {
                    usleep(40_000)
                    return PluginParamStepOutcome(steps: steps + 1, lastText: paramValueText(elements), stop: "crossed")
                }
                return PluginParamStepOutcome(steps: steps, lastText: text, stop: "crossed")
            }
            previousText = text
            previousNumber = number
        }
        return PluginParamStepOutcome(steps: steps, lastText: previousText, stop: "limit")
    }

    // MARK: - Diagnostics

    /// Subtree dump of the plug-in window (reuses the dump helper of debug_panel).
    static func debugPluginDump(_ key: PluginWindowKey, maxLines: Int) -> String {
        guard let window = pluginWindow(for: key) else { return "no plug-in window for '\(key.pluginName)'" }
        var lines: [String] = ["# plug-in window '\(AXHelpers.getTitle(window) ?? "")' for '\(key.pluginName)'"]
        dump(window, depth: 0, maxDepth: 16, maxLines: maxLines, into: &lines)
        if lines.count >= maxLines { lines.append("... truncated at \(maxLines) lines") }
        return lines.joined(separator: "\n")
    }
}
