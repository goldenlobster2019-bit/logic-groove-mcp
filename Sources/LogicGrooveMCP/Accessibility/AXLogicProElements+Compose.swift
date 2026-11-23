import ApplicationServices
import CoreGraphics
import Foundation

/// Outcome of trying to press a menu item.
enum MenuPressOutcome: Sendable {
    case pressed(String)
    case notFound
    case disabled(String)
    case failed(String)
}

/// Additional Logic Pro AX finders used by the compose / file-panel / plugin automation.
/// The original `menuItem(path:)` is intentionally left untouched.
extension AXLogicProElements {
    // MARK: - Small generic helpers

    private static func elementArray(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        guard let array: CFArray = AXHelpers.getAttribute(element, attribute) else {
            return []
        }
        var result: [AXUIElement] = []
        for i in 0..<CFArrayGetCount(array) {
            let ptr = CFArrayGetValueAtIndex(array, i)
            let item = unsafeBitCast(ptr, to: AXUIElement.self)
            result.append(item)
        }
        return result
    }

    /// Whether the element is enabled. Elements without the attribute count as enabled.
    static func isEnabled(_ element: AXUIElement) -> Bool {
        let value: NSNumber? = AXHelpers.getAttribute(element, kAXEnabledAttribute)
        return value?.boolValue ?? true
    }

    /// Lowercased "title description help" of an element, for fuzzy matching.
    static func searchLabel(of element: AXUIElement) -> String {
        let title = AXHelpers.getTitle(element) ?? ""
        let description = AXHelpers.getDescription(element) ?? ""
        let help: String = AXHelpers.getAttribute(element, kAXHelpAttribute) ?? ""
        return "\(title) \(description) \(help)".lowercased()
    }

    /// One-line description of an element for diagnostics.
    static func describe(_ element: AXUIElement) -> String {
        let role = AXHelpers.getRole(element) ?? "?"
        let title = AXHelpers.getTitle(element) ?? ""
        let description = AXHelpers.getDescription(element) ?? ""
        return "\(role)[title=\(title), desc=\(description)]"
    }

    /// Diagnostic string listing at most `limit` elements.
    static func diagnostic(of elements: [AXUIElement], limit: Int = 25) -> String {
        if elements.isEmpty { return "no candidate elements seen" }
        let lines = elements.prefix(limit).map { describe($0) }
        return lines.joined(separator: "; ")
    }

    // MARK: - Windows, sheets, dialogs

    /// All windows of Logic Pro.
    static func allWindows() -> [AXUIElement] {
        guard let app = appRoot() else { return [] }
        return elementArray(of: app, attribute: kAXWindowsAttribute)
    }

    /// Every sheet in every window (outermost first).
    static func allSheets() -> [AXUIElement] {
        var result: [AXUIElement] = []
        for window in allWindows() {
            result.append(contentsOf: AXHelpers.findAllDescendants(of: window, role: kAXSheetRole, maxDepth: 6))
        }
        return result
    }

    /// Windows other than the main project window, plus all sheets: candidates for alerts and dialogs.
    static func attentionContainers() -> [AXUIElement] {
        var result: [AXUIElement] = allSheets()
        for window in allWindows() {
            // Dialogs become AXMainWindow while they are up, so identify the project
            // window by its title instead of skipping "main".
            if isProjectWindowTitle(AXHelpers.getTitle(window) ?? "") { continue }
            result.append(window)
        }
        return result
    }

    /// Whether a window title belongs to a project window: a saved project ("Name.logicx ...") or an
    /// unsaved one, whose title reads "Untitled - Tracks" (any title ending in " - Tracks").
    static func isProjectWindowTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return lowered.contains(".logicx") || lowered.hasSuffix(" - tracks")
    }

    /// The project (arrange) window: the window whose title contains ".logicx" or ends in " - Tracks"
    /// (unsaved project). Falls back to AXMainWindow. Use this instead of mainWindow() for anything that
    /// lives in the project window, because modal dialogs take over AXMainWindow.
    static func projectWindow() -> AXUIElement? {
        for window in allWindows() where isProjectWindowTitle(AXHelpers.getTitle(window) ?? "") {
            return window
        }
        return mainWindow()
    }

    /// Windows to inspect for dialogs: every AX window plus the focused and main
    /// windows (a sandboxed Open/Save panel is not always listed in kAXWindows).
    static func dialogCandidates() -> [AXUIElement] {
        var result = allWindows()
        if let app = appRoot() {
            if let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute) {
                result.append(focused)
            }
            if let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute) {
                result.append(main)
            }
        }
        return result
    }

    /// True when the container looks like an Open/Save/Import panel: it has a
    /// Cancel button and a Save / Open / Import / Export / Choose button.
    static func looksLikeFilePanel(_ container: AXUIElement) -> Bool {
        let titles = AXHelpers.findAllDescendants(of: container, role: kAXButtonRole, maxDepth: 12)
            .compactMap { AXHelpers.getTitle($0)?.lowercased() }
        let hasCancel = titles.contains("cancel")
        let hasConfirm = titles.contains { ["save", "open", "import", "export", "choose"].contains($0) }
        return hasCancel && hasConfirm
    }

    /// The open / save panel if one is showing: a sheet, an AXDialog window, a window
    /// titled Import / Open / Save / Export, or any non-project window that has
    /// Cancel + Save/Open/Import buttons.
    /// Verified on Logic Pro 11: the panel is a standalone window ("Save MIDI File as:")
    /// that becomes AXMainWindow while it is up, so it must NOT be skipped as "main";
    /// project windows are recognised by ".logicx" in their title instead.
    static func filePanel() -> AXUIElement? {
        for window in dialogCandidates() {
            let sheets = AXHelpers.findAllDescendants(of: window, role: kAXSheetRole, maxDepth: 6)
            if let sheet = sheets.first { return sheet }
            let title = (AXHelpers.getTitle(window) ?? "").lowercased()
            if isProjectWindowTitle(title) { continue }
            let subrole: String? = AXHelpers.getAttribute(window, kAXSubroleAttribute)
            if subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole {
                return window
            }
            if title.contains("import") || title.contains("open") || title.contains("save") || title.contains("export") {
                return window
            }
            if looksLikeFilePanel(window) { return window }
        }
        return nil
    }

    /// Diagnostic: one line per candidate window (role, subrole, title, button titles),
    /// plus whether filePanel() finds a panel. Used by logic_system debug_windows.
    static func debugWindowSummary() -> [String] {
        var lines: [String] = []
        if appRoot() == nil { return ["Logic Pro AX root not available"] }
        lines.append("kAXWindows count: \(allWindows().count)")
        for (index, window) in dialogCandidates().enumerated() {
            let role = AXHelpers.getRole(window) ?? "?"
            let subrole: String = AXHelpers.getAttribute(window, kAXSubroleAttribute) ?? "-"
            let title = AXHelpers.getTitle(window) ?? "(nil)"
            let buttons = AXHelpers.findAllDescendants(of: window, role: kAXButtonRole, maxDepth: 12)
                .compactMap { AXHelpers.getTitle($0) }.filter { !$0.isEmpty }.prefix(12)
            let sheets = AXHelpers.findAllDescendants(of: window, role: kAXSheetRole, maxDepth: 6).count
            lines.append("#\(index) role=\(role) subrole=\(subrole) title=\"\(title)\" sheets=\(sheets) buttons=\(buttons.joined(separator: "|"))")
        }
        lines.append("filePanel(): \(filePanel() == nil ? "not found" : "FOUND")")
        return lines
    }

    /// Texts (static text values and descriptions) inside a container, lowercased and joined.
    static func containerText(_ container: AXUIElement) -> String {
        var parts: [String] = []
        let texts = AXHelpers.findAllDescendants(of: container, role: kAXStaticTextRole, maxDepth: 8)
        for text in texts {
            if let value = AXHelpers.getValue(text) as? String { parts.append(value) }
            if let description = AXHelpers.getDescription(text) { parts.append(description) }
        }
        if let title = AXHelpers.getTitle(container) { parts.append(title) }
        return parts.joined(separator: " ").lowercased()
    }

    /// Titles of the buttons inside a container.
    static func buttonTitles(in container: AXUIElement) -> [String] {
        let buttons = AXHelpers.findAllDescendants(of: container, role: kAXButtonRole, maxDepth: 8)
        return buttons.compactMap { AXHelpers.getTitle($0) }.filter { !$0.isEmpty }
    }

    /// Press the panel's default button (or a button whose title matches one of
    /// `titles`, case-insensitive). Returns the pressed title, or nil when nothing was pressed.
    static func pressPanelButton(titles: [String]) -> String? {
        guard let panel = strictFilePanel() else { return nil }
        let wanted = titles.map { $0.lowercased() }
        let buttons = AXHelpers.findAllDescendants(of: panel, role: kAXButtonRole, maxDepth: 10)
        for button in buttons {
            let title = (AXHelpers.getTitle(button) ?? "").lowercased()
            if wanted.contains(title) && isEnabled(button) {
                if AXHelpers.performAction(button, kAXPressAction) {
                    return AXHelpers.getTitle(button) ?? "button"
                }
            }
        }
        let defaultButton: AXUIElement? = AXHelpers.getAttribute(panel, kAXDefaultButtonAttribute)
        if let defaultButton, isEnabled(defaultButton) {
            if AXHelpers.performAction(defaultButton, kAXPressAction) {
                return AXHelpers.getTitle(defaultButton) ?? "default button"
            }
        }
        return nil
    }

    /// Press a button in any alert / sheet / dialog whose title contains `fragment`.
    /// Returns the pressed title or nil.
    static func pressAlertButton(titleContaining fragment: String) -> String? {
        let needle = fragment.lowercased()
        for container in attentionContainers() {
            let buttons = AXHelpers.findAllDescendants(of: container, role: kAXButtonRole, maxDepth: 8)
            for button in buttons {
                let title = AXHelpers.getTitle(button) ?? ""
                if title.lowercased().contains(needle) && isEnabled(button) {
                    if AXHelpers.performAction(button, kAXPressAction) { return title }
                }
            }
        }
        return nil
    }

    /// If a dialog asking about importing tempo is showing, press the button that
    /// does NOT import tempo. Returns a description of what happened, nil when no
    /// tempo dialog is showing.
    static func resolveTempoDialog() -> String? {
        for container in attentionContainers() {
            guard containerText(container).contains("tempo") else { continue }
            let buttons = AXHelpers.findAllDescendants(of: container, role: kAXButtonRole, maxDepth: 8)
            let titles = buttons.compactMap { AXHelpers.getTitle($0) }.filter { !$0.isEmpty }
            for button in buttons {
                let raw = AXHelpers.getTitle(button) ?? ""
                let t = ComposeSupport.normalizeMenuTitle(raw)
                if t.isEmpty { continue }
                let declines = t.hasPrefix("don") || t.hasPrefix("do not") || t == "no"
                    || t.hasPrefix("no ") || t.contains("ignore") || t.contains("without") || t.contains("keep")
                if declines && isEnabled(button) {
                    if AXHelpers.performAction(button, kAXPressAction) {
                        return "tempo dialog: pressed '\(raw)'"
                    }
                }
            }
            return "tempo dialog found but no safe button recognised (buttons: \(titles.joined(separator: ", "))); left open"
        }
        return nil
    }

    /// Press "Create" in the New Tracks dialog if showing.
    static func pressNewTracksCreate() -> Bool {
        for container in attentionContainers() {
            let buttons = AXHelpers.findAllDescendants(of: container, role: kAXButtonRole, maxDepth: 8)
            for button in buttons {
                let title = ComposeSupport.normalizeMenuTitle(AXHelpers.getTitle(button) ?? "")
                if title == "create" && isEnabled(button) {
                    if AXHelpers.performAction(button, kAXPressAction) { return true }
                }
            }
        }
        return false
    }

    // MARK: - Text fields in panels

    static func isTextRole(_ role: String?) -> Bool {
        role == kAXTextFieldRole || role == kAXComboBoxRole || role == kAXTextAreaRole
    }

    /// The focused UI element of the app when it is a text-like control.
    static func focusedTextField() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        let focused: AXUIElement? = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute)
        guard let focused, isTextRole(AXHelpers.getRole(focused)) else { return nil }
        return focused
    }

    /// Whether the currently focused element is the same as `other`.
    static func focusedElementEquals(_ other: AXUIElement?) -> Bool {
        guard let app = appRoot() else { return false }
        let focused: AXUIElement? = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute)
        guard let focused, let other else { return false }
        return CFEqual(focused, other)
    }

    /// The raw focused element (any role).
    static func focusedElement() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        let focused: AXUIElement? = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute)
        return focused
    }

    /// Text field of the "Go to the folder" sheet that appears after Cmd+Shift+G.
    /// `sheetCountBefore` is the sheet count before the shortcut was posted; the
    /// field is only returned once a new sheet exists or the focus moved.
    static func goToFolderField(sheetCountBefore: Int, focusBefore: AXUIElement?) -> AXUIElement? {
        let sheets = allSheets()
        if sheets.count > sheetCountBefore {
            for sheet in sheets.reversed() {
                if let field = AXHelpers.findDescendant(of: sheet, role: kAXComboBoxRole, maxDepth: 6) {
                    return field
                }
                if let field = AXHelpers.findDescendant(of: sheet, role: kAXTextFieldRole, maxDepth: 6) {
                    return field
                }
            }
        }
        if let focused = focusedTextField(), !focusedElementEquals(focusBefore) {
            return focused
        }
        return nil
    }

    /// The file name field of a save panel.
    static func saveNameField() -> AXUIElement? {
        guard let panel = strictFilePanel() else { return nil }
        if let field = AXHelpers.findDescendant(
            of: panel, role: kAXTextFieldRole, identifier: "saveAsNameTextField", maxDepth: 10
        ) {
            return field
        }
        return AXHelpers.findDescendant(of: panel, role: kAXTextFieldRole, maxDepth: 10)
    }

    // MARK: - Tolerant menu access

    /// Items of a menu-bar item / menu / submenu item, flattening the AXMenu wrapper.
    static func menuEntries(of container: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for child in AXHelpers.getChildren(container) {
            if AXHelpers.getRole(child) == kAXMenuRole {
                result.append(contentsOf: menuEntries(of: child))
            } else {
                result.append(child)
            }
        }
        return result
    }

    /// Find an entry of `container` by title: exact (normalized) match first, then prefix.
    static func findMenuEntry(in container: AXUIElement, matching title: String) -> AXUIElement? {
        let entries = menuEntries(of: container)
        for entry in entries {
            if let t = AXHelpers.getTitle(entry), ComposeSupport.menuTitleEquals(t, title) {
                return entry
            }
        }
        for entry in entries {
            if let t = AXHelpers.getTitle(entry), ComposeSupport.menuTitleHasPrefix(t, title) {
                return entry
            }
        }
        return nil
    }

    /// Case-insensitive, ellipsis-tolerant menu lookup. All but the last path
    /// component must resolve level by level; the last component is also searched
    /// one submenu level deeper (e.g. Track > Other > New External MIDI Track).
    static func menuItem(matching path: [String]) -> AXUIElement? {
        guard let bar = getMenuBar(), let last = path.last else { return nil }
        var current = bar
        for title in path.dropLast() {
            guard let next = findMenuEntry(in: current, matching: title) else { return nil }
            current = next
        }
        if let found = findMenuEntry(in: current, matching: last) {
            return found
        }
        for entry in menuEntries(of: current) {
            if menuEntries(of: entry).isEmpty { continue }
            if let found = findMenuEntry(in: entry, matching: last) {
                return found
            }
        }
        return nil
    }

    /// Titles of the entries directly under a menu path (diagnostics).
    static func menuEntryTitles(path: [String]) -> [String] {
        guard let bar = getMenuBar() else { return [] }
        var current = bar
        for title in path {
            guard let next = findMenuEntry(in: current, matching: title) else { return [] }
            current = next
        }
        return menuEntries(of: current).compactMap { AXHelpers.getTitle($0) }.filter { !$0.isEmpty }
    }

    /// Press a menu item found with `menuItem(matching:)`.
    static func pressMenu(_ path: [String]) -> MenuPressOutcome {
        guard let item = menuItem(matching: path) else { return .notFound }
        let title = AXHelpers.getTitle(item) ?? path.joined(separator: " > ")
        guard isEnabled(item) else { return .disabled(title) }
        return AXHelpers.performAction(item, kAXPressAction) ? .pressed(title) : .failed(title)
    }

    /// Title of the first Edit-menu item (e.g. "Undo Create Initial Automation Node").
    /// Reads only; presses nothing.
    static func undoMenuTitle() -> String? {
        guard let edit = menuItem(matching: ["Edit"]) else { return nil }
        guard let first = menuEntries(of: edit).first else { return nil }
        guard let title = AXHelpers.getTitle(first), !title.isEmpty else { return nil }
        return title
    }

    // MARK: - Inspector channel strip and plugin slots

    /// The Inspector's channel strip (first "Mixer" layout area in the main window).
    static func inspectorChannelStrip() -> AXUIElement? {
        guard let window = projectWindow() else { return nil }
        if let strip = AXHelpers.findDescendant(
            of: window, role: "AXLayoutArea", description: "Mixer", maxDepth: 12
        ) {
            return strip
        }
        return AXHelpers.findDescendant(of: window, role: kAXGroupRole, description: "Inspector", maxDepth: 8)
    }

    /// Button-like descendants of a strip (slot candidates), in tree order.
    static func slotCandidates(in strip: AXUIElement) -> [AXUIElement] {
        let all = AXHelpers.findAllDescendants(of: strip, role: nil, maxDepth: 10)
        return all.filter { element in
            let role = AXHelpers.getRole(element)
            return role == kAXButtonRole || role == kAXMenuButtonRole || role == kAXPopUpButtonRole
        }
    }

    /// The button that opens the plug-in menu of a slot in the Inspector's first channel strip.
    ///
    /// Verified on Logic Pro 11 (AXDescription values, no titles): a loaded slot is a pair of
    /// buttons on one row, "open" (opens the plug-in window) and "list" (opens the plug-in
    /// menu); an empty audio effect slot is a single "audio plug-in" button; the MIDI FX slot
    /// is "MIDI plug-in"; rows run top to bottom MIDI FX, instrument, audio FX. The second
    /// strip in the Inspector (the output, e.g. Stereo Out) is excluded by x position.
    static func pluginSlotButton(slot: Int, candidates: [AXUIElement]) -> AXUIElement? {
        struct Item { let element: AXUIElement; let label: String; let frame: CGRect }
        var items: [Item] = candidates.compactMap { element in
            guard let rect = frame(of: element) else { return nil }
            let label = (AXHelpers.getDescription(element) ?? AXHelpers.getTitle(element) ?? "").lowercased()
            return Item(element: element, label: label, frame: rect)
        }
        guard !items.isEmpty else { return nil }
        // Keep only the first (leftmost) strip.
        let anchorX = items.first(where: { $0.label == "midi plug-in" })?.frame.minX
            ?? items.map { $0.frame.minX }.min() ?? 0
        items = items.filter { $0.frame.minX < anchorX + 60 }

        func sameRow(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.midY - b.midY) < 4 }
        // Rows that hold a plug-in: loaded ("open" + "list") or empty audio FX ("audio plug-in").
        var rows: [(y: CGFloat, menuButton: AXUIElement)] = []
        for open in items where open.label == "open" {
            if let list = items.first(where: { $0.label == "list" && sameRow($0.frame, open.frame) && $0.frame.minX > open.frame.minX }) {
                rows.append((open.frame.midY, list.element))
            }
        }
        for empty in items where empty.label == "audio plug-in" || empty.label == "instrument plug-in" {
            rows.append((empty.frame.midY, empty.element))
        }
        rows.sort { $0.y < $1.y }
        let midiY = items.first(where: { $0.label == "midi plug-in" })?.frame.midY ?? -CGFloat.greatestFiniteMagnitude
        let belowMidi = rows.filter { $0.y > midiY }
        if slot == 0 {
            if let first = belowMidi.first { return first.menuButton }
            return candidates.first { searchLabel(of: $0).contains("instrument") }
        }
        // Audio effect slots come after the instrument row.
        let effects = Array(belowMidi.dropFirst())
        return effects.indices.contains(slot - 1) ? effects[slot - 1].menuButton : nil
    }

    /// Find a menu that has just opened: under the element, under the app, or in a window.
    static func openedMenu(near element: AXUIElement) -> AXUIElement? {
        if let menu = AXHelpers.findChild(of: element, role: kAXMenuRole) {
            return menu
        }
        if let app = appRoot(), let menu = AXHelpers.findChild(of: app, role: kAXMenuRole) {
            return menu
        }
        // Only direct children of windows: deeper AXMenu elements belong to
        // unrelated (closed) pop-up buttons and would be picked up by mistake.
        for window in allWindows() {
            if let menu = AXHelpers.findChild(of: window, role: kAXMenuRole) {
                return menu
            }
        }
        return nil
    }

    /// Search field inside an opened plugin menu, if Logic provides one.
    static func menuSearchField(in menu: AXUIElement) -> AXUIElement? {
        for role in [kAXTextFieldRole, kAXComboBoxRole, kAXTextAreaRole] {
            if let field = AXHelpers.findDescendant(of: menu, role: role, maxDepth: 4) {
                return field
            }
        }
        return nil
    }

    /// Depth-first search of a menu tree for an item whose title contains `needle`
    /// (case-insensitive). Exact title matches win over substring matches at each
    /// level. Returns the chain [ancestor items..., target item].
    static func findMenuItemChain(in container: AXUIElement, containing needle: String, maxDepth: Int) -> [AXUIElement]? {
        guard maxDepth > 0 else { return nil }
        let wanted = needle.lowercased()
        let entries = menuEntries(of: container)
        for entry in entries {
            let title = (AXHelpers.getTitle(entry) ?? "").lowercased()
            if !title.isEmpty && title == wanted { return [entry] }
        }
        for entry in entries {
            let title = (AXHelpers.getTitle(entry) ?? "").lowercased()
            if !title.isEmpty && title.contains(wanted) { return [entry] }
        }
        for entry in entries {
            if menuEntries(of: entry).isEmpty { continue }
            if let rest = findMenuItemChain(in: entry, containing: needle, maxDepth: maxDepth - 1) {
                return [entry] + rest
            }
        }
        return nil
    }

    /// If `item` has a submenu, the chain of items to descend through to reach a
    /// leaf: prefers an entry titled "Stereo", otherwise the first enabled entry.
    /// Empty when `item` is already a leaf.
    static func leafChain(under item: AXUIElement, maxDepth: Int = 3) -> [AXUIElement] {
        guard maxDepth > 0 else { return [] }
        let entries = menuEntries(of: item)
        if entries.isEmpty { return [] }
        var chosen: AXUIElement?
        for entry in entries {
            let title = (AXHelpers.getTitle(entry) ?? "").lowercased()
            if title == "stereo" && isEnabled(entry) { chosen = entry; break }
        }
        if chosen == nil {
            for entry in entries {
                let title = AXHelpers.getTitle(entry) ?? ""
                if !title.isEmpty && isEnabled(entry) { chosen = entry; break }
            }
        }
        guard let pick = chosen else { return [] }
        return [pick] + leafChain(under: pick, maxDepth: maxDepth - 1)
    }

    // MARK: - Region inspector

    /// The "Loop" checkbox in the Region inspector.
    static func regionLoopCheckbox() -> AXUIElement? {
        guard let window = projectWindow() else { return nil }
        let boxes = AXHelpers.findAllDescendants(of: window, role: kAXCheckBoxRole, maxDepth: 14)
        for box in boxes {
            let title = (AXHelpers.getTitle(box) ?? "").lowercased()
            let description = (AXHelpers.getDescription(box) ?? "").lowercased()
            if title == "loop" || description == "loop" {
                return box
            }
        }
        // Verified on Logic Pro 11: the Region inspector's Loop checkbox is UNTITLED; its
        // "Loop:" caption is a separate static text on the same row. Match by row.
        let labels = AXHelpers.findAllDescendants(of: window, role: kAXStaticTextRole, maxDepth: 14)
            .filter { label in
                let text = ((AXHelpers.getValue(label) as? String) ?? AXHelpers.getTitle(label) ?? "")
                    .trimmingCharacters(in: .whitespaces).lowercased()
                return text == "loop:" || text == "loop"
            }
        for label in labels {
            guard let labelFrame = frame(of: label) else { continue }
            var best: (box: AXUIElement, distance: CGFloat)?
            for box in boxes where (AXHelpers.getTitle(box) ?? "").isEmpty {
                guard let boxFrame = frame(of: box) else { continue }
                let sameRow = abs(boxFrame.midY - labelFrame.midY) < 8
                let toTheRight = boxFrame.minX >= labelFrame.minX
                guard sameRow, toTheRight else { continue }
                let distance = boxFrame.minX - labelFrame.maxX
                if let current = best, current.distance <= distance { continue }
                best = (box, distance)
            }
            if let best { return best.box }
        }
        return nil
    }

    /// Screen frame of an element from kAXPosition/kAXSize, nil if unavailable.
    static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    /// Integer value (0/1) of a checkbox, nil if unreadable.
    static func checkboxState(_ box: AXUIElement) -> Int? {
        guard let value = AXHelpers.getValue(box) else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// Close button of a window.
    static func closeButton(of window: AXUIElement) -> AXUIElement? {
        let button: AXUIElement? = AXHelpers.getAttribute(window, kAXCloseButtonAttribute)
        return button
    }

    // MARK: - Import panel, file selection, focus and diagnostics

    /// The import panel: like filePanel() but only accepts a container that looks like a
    /// file panel (Cancel + confirm button) or is titled "Import". An unrelated AXDialog
    /// (for example Logic's "Go To Position" dialog) is never returned.
    static func importPanel() -> AXUIElement? {
        for window in dialogCandidates() {
            let title = (AXHelpers.getTitle(window) ?? "").lowercased()
            if isProjectWindowTitle(title) { continue }
            if title == "import" || looksLikeFilePanel(window) { return window }
        }
        return nil
    }

    /// Number of track header rows currently visible.
    static func trackHeaderCount() -> Int {
        allTrackHeaders().count
    }

    /// Whether a Logic window has exactly this title (case-insensitive).
    static func hasWindow(titled title: String) -> Bool {
        let wanted = title.lowercased()
        for window in allWindows() where (AXHelpers.getTitle(window) ?? "").lowercased() == wanted {
            return true
        }
        return false
    }

    /// Like filePanel() but never returns a plug-in window or an unrelated dialog: the import
    /// panel, a window titled Save / Export / Open, or a sheet that looks like a file panel.
    /// Used by the export flow and by every pre-check that asks "is a file panel up?".
    static func strictFilePanel() -> AXUIElement? {
        if let panel = importPanel() { return panel }
        for window in dialogCandidates() {
            let title = (AXHelpers.getTitle(window) ?? "").lowercased()
            if isProjectWindowTitle(title) { continue }
            if title.hasPrefix("save") || title.hasPrefix("export") || title.hasPrefix("open") {
                return window
            }
            for sheet in AXHelpers.findAllDescendants(of: window, role: kAXSheetRole, maxDepth: 6)
            where looksLikeFilePanel(sheet) {
                return sheet
            }
        }
        return nil
    }

    /// Title and button titles of a panel, for error messages.
    static func panelSummary(of panel: AXUIElement) -> String {
        let title = AXHelpers.getTitle(panel) ?? "(no title)"
        let buttons = buttonTitles(in: panel)
        return "window '\(title)' with buttons [\(buttons.joined(separator: ", "))]"
    }

    /// Title and button titles of the file panel, for error messages. nil without a panel.
    static func filePanelSummary() -> String? {
        guard let panel = strictFilePanel() else { return nil }
        return panelSummary(of: panel)
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    private static func parentElement(of element: AXUIElement) -> AXUIElement? {
        let value: AXUIElement? = AXHelpers.getAttribute(element, kAXParentAttribute)
        return value
    }

    /// Try the selection attributes along `chain` (match first, then its ancestors).
    /// Returns a description of the call that succeeded, nil when none did.
    private static func trySelect(chain: [AXUIElement], roles: [String]) -> String? {
        if let index = roles.firstIndex(where: { $0 == kAXRowRole || $0 == kAXCellRole }) {
            if AXHelpers.setAttribute(chain[index], kAXSelectedAttribute, kCFBooleanTrue) {
                return "AXSelected on \(roles[index])"
            }
        }
        if let index = roles.firstIndex(where: { $0 == kAXOutlineRole || $0 == kAXTableRole }), index > 0 {
            let row = chain[index - 1]
            if isSettable(chain[index], kAXSelectedRowsAttribute),
               AXHelpers.setAttribute(chain[index], kAXSelectedRowsAttribute, [row] as CFArray) {
                return "AXSelectedRows on \(roles[index])"
            }
        }
        for index in roles.indices where index > 0 {
            let role = roles[index]
            guard role == kAXListRole || role == kAXBrowserRole || role == kAXGroupRole else { continue }
            let item = chain[index - 1]
            if isSettable(chain[index], kAXSelectedChildrenAttribute),
               AXHelpers.setAttribute(chain[index], kAXSelectedChildrenAttribute, [item] as CFArray) {
                return "AXSelectedChildren on \(role)"
            }
        }
        return nil
    }

    /// Try to select `fileName` in the import panel with Accessibility only. Returns a
    /// human-readable outcome starting with "selected", "found-not-selected" or "not-found".
    /// "selected" means an attribute write succeeded; the caller must still check that the
    /// panel's confirm button became enabled.
    static func selectFileInPanel(named fileName: String) -> String {
        guard let panel = importPanel() else { return "not-found (no import panel)" }
        let wanted: Set<String> = [
            fileName.lowercased(),
            (fileName as NSString).deletingPathExtension.lowercased(),
        ]
        let all = AXHelpers.findAllDescendants(of: panel, role: nil, maxDepth: 14)
        var matches: [AXUIElement] = []
        for element in all {
            var labels: [String] = []
            if let title = AXHelpers.getTitle(element) { labels.append(title) }
            if let value = AXHelpers.getValue(element) as? String { labels.append(value) }
            if let description = AXHelpers.getDescription(element) { labels.append(description) }
            if labels.contains(where: { wanted.contains($0.lowercased()) }) {
                matches.append(element)
            }
        }
        if matches.isEmpty { return "not-found (scanned \(all.count) elements)" }

        var chains: [String] = []
        for match in matches {
            var chain: [AXUIElement] = [match]
            var current = match
            for _ in 0..<8 {
                guard let up = parentElement(of: current) else { break }
                chain.append(up)
                current = up
            }
            let roles = chain.map { AXHelpers.getRole($0) ?? "?" }
            let chainText = roles.joined(separator: ">")
            if let outcome = trySelect(chain: chain, roles: roles) {
                return "selected via \(outcome) (matches=\(matches.count), chain \(chainText))"
            }
            chains.append(chainText)
        }
        return "found-not-selected (matches=\(matches.count), chains \(chains.prefix(3).joined(separator: " | ")))"
    }

    /// State of the panel's confirm button: "enabled:<title>", "disabled:<title>" or "missing".
    static func panelConfirmButtonState(titles: [String]) -> String {
        guard let panel = importPanel() else { return "missing" }
        let wanted = titles.map { $0.lowercased() }
        for button in AXHelpers.findAllDescendants(of: panel, role: kAXButtonRole, maxDepth: 12) {
            let title = AXHelpers.getTitle(button) ?? ""
            if wanted.contains(title.lowercased()) {
                return (isEnabled(button) ? "enabled:" : "disabled:") + title
            }
        }
        return "missing"
    }

    /// Press the import panel's confirm button (no default-button fallback). Returns the pressed title.
    static func pressImportPanelButton(titles: [String]) -> String? {
        guard let panel = importPanel() else { return nil }
        let wanted = titles.map { $0.lowercased() }
        for button in AXHelpers.findAllDescendants(of: panel, role: kAXButtonRole, maxDepth: 12) {
            let title = AXHelpers.getTitle(button) ?? ""
            if wanted.contains(title.lowercased()) && isEnabled(button) {
                if AXHelpers.performAction(button, kAXPressAction) { return title }
            }
        }
        return nil
    }

    /// Press Cancel on the import panel (or, when there is none, on the file panel).
    /// Returns true when a Cancel button was pressed.
    static func cancelFilePanel() -> Bool {
        guard let panel = strictFilePanel() else { return false }
        for button in AXHelpers.findAllDescendants(of: panel, role: kAXButtonRole, maxDepth: 12) {
            if (AXHelpers.getTitle(button) ?? "").lowercased() == "cancel" && isEnabled(button) {
                if AXHelpers.performAction(button, kAXPressAction) { return true }
            }
        }
        return false
    }

    // MARK: Focus

    /// The focused UI element: system-wide first (the Open/Save panels are hosted out of
    /// process), then the Logic app element.
    static func currentFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        let focused: AXUIElement? = AXHelpers.getAttribute(systemWide, kAXFocusedUIElementAttribute)
        if let focused { return focused }
        return focusedElement()
    }

    private static func clip(_ text: String, _ limit: Int = 60) -> String {
        text.count > limit ? String(text.prefix(limit)) + "..." : text
    }

    static func stringValue(of element: AXUIElement) -> String? {
        guard let value = AXHelpers.getValue(element) else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// "role/subrole value='<first 60 chars>'" of the focused element, nil if there is none.
    static func focusedFieldSummary() -> String? {
        guard let element = currentFocusedElement() else { return nil }
        let role = AXHelpers.getRole(element) ?? "?"
        let subrole: String = AXHelpers.getAttribute(element, kAXSubroleAttribute) ?? "-"
        let value = stringValue(of: element) ?? ""
        return "\(role)/\(subrole) value='\(clip(value))'"
    }

    /// Whether the focused element is a text field that is not a search field.
    static func focusedIsNonSearchTextField() -> Bool {
        guard let element = currentFocusedElement() else { return false }
        guard isTextRole(AXHelpers.getRole(element)) else { return false }
        let subrole: String? = AXHelpers.getAttribute(element, kAXSubroleAttribute)
        return subrole != kAXSearchFieldSubrole
    }

    /// Full string value of the focused element, nil if unreadable.
    static func focusedFieldValue() -> String? {
        guard let element = currentFocusedElement() else { return nil }
        return stringValue(of: element)
    }

    /// Role, subrole and title of the focused window of Logic Pro.
    static func focusedWindowSummary() -> String {
        guard let app = appRoot() else { return "Logic Pro AX root not available" }
        let window: AXUIElement? = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute)
        guard let window else { return "no focused window" }
        let role = AXHelpers.getRole(window) ?? "?"
        let subrole: String = AXHelpers.getAttribute(window, kAXSubroleAttribute) ?? "-"
        return "\(role)/\(subrole) title='\(AXHelpers.getTitle(window) ?? "")'"
    }

    // MARK: Subtree dump

    static func dumpLine(of element: AXUIElement, depth: Int) -> String {
        let role = AXHelpers.getRole(element) ?? "?"
        let subrole: String? = AXHelpers.getAttribute(element, kAXSubroleAttribute)
        let title = AXHelpers.getTitle(element) ?? ""
        let value = stringValue(of: element) ?? ""
        let description = AXHelpers.getDescription(element) ?? ""
        var line = String(repeating: "  ", count: depth) + role
        if let subrole { line += "/\(subrole)" }
        line += " \"\(clip(title))\" value='\(clip(value))' desc='\(clip(description))' enabled=\(isEnabled(element))"
        let selected: NSNumber? = AXHelpers.getAttribute(element, kAXSelectedAttribute)
        if let selected { line += " selected=\(selected.boolValue)" }
        var settable: [String] = []
        for (name, attribute) in [
            ("AXSelected", kAXSelectedAttribute),
            ("AXSelectedRows", kAXSelectedRowsAttribute),
            ("AXSelectedChildren", kAXSelectedChildrenAttribute),
            ("AXValue", kAXValueAttribute),
            ("AXFocused", kAXFocusedAttribute),
        ] where isSettable(element, attribute) {
            settable.append(name)
        }
        line += " settable=[\(settable.joined(separator: ","))]"
        return line
    }

    static func dump(_ element: AXUIElement, depth: Int, maxDepth: Int, maxLines: Int, into lines: inout [String]) {
        guard lines.count < maxLines else { return }
        lines.append(dumpLine(of: element, depth: depth))
        guard depth < maxDepth else { return }
        for child in AXHelpers.getChildren(element) {
            if lines.count >= maxLines { return }
            dump(child, depth: depth + 1, maxDepth: maxDepth, maxLines: maxLines, into: &lines)
        }
    }

    /// Text dump of the AX subtree of the current file panel, or of the focused window when
    /// there is no panel (one line per element, indented by depth). With `windowTitle`, the
    /// first window whose title contains that text (case-insensitive) is dumped instead.
    static func debugPanelDump(maxDepth: Int = 16, maxLines: Int = 300, windowTitle: String? = nil) -> String {
        var lines: [String] = []
        let root: AXUIElement?
        if let windowTitle, !windowTitle.isEmpty {
            let wanted = windowTitle.lowercased()
            let match = dialogCandidates().first { (AXHelpers.getTitle($0) ?? "").lowercased().contains(wanted) }
            if let match {
                lines.append("# window: \(AXHelpers.getTitle(match) ?? "(no title)")")
                root = match
            } else {
                let titles = windowTitles().map { "'\($0)'" }.joined(separator: ", ")
                lines.append("no window with a title containing '\(windowTitle)'. Windows: \(titles)")
                root = nil
            }
        } else if let panel = filePanel() {
            lines.append("# file panel: \(AXHelpers.getTitle(panel) ?? "(no title)")")
            root = panel
        } else if let app = appRoot() {
            let focusedWindow: AXUIElement? = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute)
            lines.append("# no file panel; focused window")
            root = focusedWindow
        } else {
            root = nil
        }
        guard let root else {
            lines.append("no element to dump")
            return lines.joined(separator: "\n")
        }
        dump(root, depth: 0, maxDepth: maxDepth, maxLines: maxLines, into: &lines)
        if lines.count >= maxLines { lines.append("... truncated at \(maxLines) lines") }
        return lines.joined(separator: "\n")
    }
}
