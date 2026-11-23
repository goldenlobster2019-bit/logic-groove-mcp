import ApplicationServices
import CoreGraphics
import Foundation

/// Result of pressing a plug-in slot in the Inspector channel strip. Only Sendable values, so it can
/// cross an `await` (AX elements stay inside the synchronous helper that produced it).
struct SlotPressOutcome: Sendable {
    let found: Bool
    let candidateCount: Int
    let chosen: String
    /// "AXShowMenu" or "AXPress".
    let method: String
    /// Raw AXError code returned by the action (the result is only recorded, never trusted).
    let resultCode: Int32
    let actions: String
    let diagnostic: String

    var traceText: String {
        "slot candidates=\(candidateCount), chosen \(chosen), actions [\(actions)], \(method) returned \(resultCode)"
    }
}

/// Track selection, focus, window-set and plug-in slot helpers used by the verified flows
/// (selectTrackVerified, insertPlugin, region placement). All synchronous.
extension AXLogicProElements {
    // MARK: - Track selection

    /// Index (0-based, same indexing as the `tracks` state) of the first selected track header,
    /// read live through AX exactly like the state poller does (`AXValueExtractors.isTrackSelected`).
    static func selectedTrackIndex() -> Int? {
        for (index, header) in allTrackHeaders().enumerated() where AXValueExtractors.isTrackSelected(header) {
            return index
        }
        return nil
    }

    /// "index N name 'X'" of the selected track, or "none".
    static func selectedTrackSummary() -> String {
        for (index, header) in allTrackHeaders().enumerated() where AXValueExtractors.isTrackSelected(header) {
            let name = AXValueExtractors.extractTrackState(from: header, index: index).name
            return "index \(index) name '\(name)'"
        }
        return "none"
    }

    /// Try `AXSelected = true` on the header. Returns a short trace clause.
    static func setTrackHeaderSelected(index: Int) -> String {
        guard let header = findTrackHeader(at: index) else { return "AXSelected: header not found" }
        guard isSettable(header, kAXSelectedAttribute) else { return "AXSelected: not settable" }
        return AXHelpers.setAttribute(header, kAXSelectedAttribute, kCFBooleanTrue)
            ? "AXSelected: set" : "AXSelected: set failed"
    }

    /// Click point for the last-resort track selection: inside the header's track number column
    /// (frame.minX + 12, frame.midY), only when that point lies inside the project window.
    static func trackHeaderClickPoint(index: Int) -> CGPoint? {
        guard let header = findTrackHeader(at: index), let rect = frame(of: header),
              rect.width > 0, rect.height > 0 else { return nil }
        let point = CGPoint(x: rect.minX + 12, y: rect.midY)
        guard let window = projectWindow(), let windowFrame = frame(of: window),
              windowFrame.contains(point) else { return nil }
        return point
    }

    // MARK: - Focus

    /// Whether the focused element is a text field of any subrole (search fields included).
    static func focusedIsAnyTextField() -> Bool {
        guard let element = currentFocusedElement() else { return false }
        return isTextRole(AXHelpers.getRole(element))
    }

    /// Whether the focused element is a search field.
    static func focusedIsSearchField() -> Bool {
        guard let element = currentFocusedElement() else { return false }
        let subrole: String? = AXHelpers.getAttribute(element, kAXSubroleAttribute)
        return subrole == kAXSearchFieldSubrole
    }

    /// Hash of the focused element, to tell two equal-looking empty fields apart.
    static func focusedElementToken() -> Int {
        guard let element = currentFocusedElement() else { return 0 }
        return Int(truncatingIfNeeded: CFHash(element))
    }

    /// Whether Logic's focused window is the project window.
    static func focusedWindowIsProject() -> Bool {
        guard let app = appRoot() else { return false }
        let window: AXUIElement? = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute)
        guard let window else { return false }
        return isProjectWindowTitle(AXHelpers.getTitle(window) ?? "")
    }

    /// nil when arrow keys can safely move the track selection (only the project window is up, no file
    /// panel, no text field focused); otherwise the reason they are not safe.
    static func arrowKeysUnsafeReason() -> String? {
        if importPanel() != nil { return "a file panel is open" }
        if focusedIsAnyTextField() { return "a text field is focused" }
        if !focusedWindowIsProject() { return "the project window is not the focused window (\(focusedWindowSummary()))" }
        return nil
    }

    // MARK: - Windows

    /// Titles of all Logic windows (a multiset: duplicates stay).
    static func windowTitles() -> [String] {
        allWindows().map { AXHelpers.getTitle($0) ?? "" }
    }

    /// Titles present now that were not in `before` (multiset difference). When only the count grew
    /// and every title already existed, one placeholder is returned.
    static func newWindowTitles(since before: [String]) -> [String] {
        let now = windowTitles()
        var remaining: [String: Int] = [:]
        for title in before { remaining[title, default: 0] += 1 }
        var added: [String] = []
        for title in now {
            if let count = remaining[title], count > 0 {
                remaining[title] = count - 1
            } else {
                added.append(title)
            }
        }
        if added.isEmpty && now.count > before.count { added.append("(untitled window)") }
        return added
    }

    /// Close every window that is new compared with `before` through its AX close button.
    /// Returns how many close buttons were pressed.
    static func closeNewWindows(since before: [String]) -> Int {
        var remaining: [String: Int] = [:]
        for title in before { remaining[title, default: 0] += 1 }
        var closed = 0
        for window in allWindows() {
            let title = AXHelpers.getTitle(window) ?? ""
            if let count = remaining[title], count > 0 {
                remaining[title] = count - 1
                continue
            }
            if let button = closeButton(of: window), AXHelpers.performAction(button, kAXPressAction) {
                closed += 1
            }
        }
        return closed
    }

    // MARK: - Plug-in slot menu

    /// Whether the Inspector channel strip is currently reachable.
    static func hasInspectorChannelStrip() -> Bool {
        inspectorChannelStrip() != nil
    }

    /// Whether a pop-up menu is visible to AX (app-level or window-level), for failure traces.
    static func openedMenuSummary() -> String {
        guard let app = appRoot() else { return "Logic Pro AX root not available" }
        guard let menu = openedMenu(near: app) else { return "no pop-up menu visible to AX" }
        return "pop-up menu visible with \(menuEntries(of: menu).count) entries"
    }

    // MARK: - Diagnostics

    /// Dump of the Inspector channel strip: selected track, slot candidates with frames, AX subtree.
    static func debugStripDump(maxLines: Int = 300) -> String {
        var lines: [String] = []
        lines.append("selectedTrackIndex: \(selectedTrackIndex().map(String.init) ?? "nil") (\(selectedTrackSummary()))")
        guard let strip = inspectorChannelStrip() else {
            lines.append("no Inspector channel strip found (is the Inspector visible?)")
            return lines.joined(separator: "\n")
        }
        if let model = stripModel() {
            lines.append("stripModel: \(model.compactJSON())")
        } else {
            lines.append("stripModel: nil (no selected-track item)")
        }
        let candidates = slotCandidates(in: strip)
        lines.append("slot candidates (\(candidates.count)):")
        for (index, element) in candidates.enumerated() {
            let rect = frame(of: element).map { "frame=(\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height)))" } ?? "no frame"
            lines.append("  #\(index) \(describe(element)) \(rect)")
        }
        lines.append("diagnostic(of: candidates): \(diagnostic(of: candidates, limit: 60))")
        for slot in 0...2 {
            let chosen = pluginSlotButton(slot: slot, candidates: candidates).map { describe($0) } ?? "none"
            lines.append("pluginSlotButton(slot: \(slot)): \(chosen)")
        }
        lines.append("# strip subtree")
        dump(strip, depth: 0, maxDepth: 10, maxLines: lines.count + maxLines, into: &lines)
        if lines.count >= maxLines { lines.append("... truncated") }
        return lines.joined(separator: "\n")
    }
}
