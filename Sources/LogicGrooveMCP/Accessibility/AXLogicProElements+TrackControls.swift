import ApplicationServices
import CoreGraphics
import Foundation

/// Which toggle on a track header a verified command addresses.
enum HeaderToggle: Sendable {
    case mute
    case solo

    var label: String {
        switch self {
        case .mute: return "Mute"
        case .solo: return "Solo"
        }
    }
}

/// Live reads and finders for the track header controls, the transport play state and alerts.
/// All synchronous; AX elements never leave these functions except to their synchronous callers.
extension AXLogicProElements {
    // MARK: - Toggle state

    /// State of a checkbox / toggle button: AXValue as number, "1" or "true". nil when unreadable.
    static func toggleState(_ element: AXUIElement) -> Bool? {
        guard let value = AXHelpers.getValue(element) else { return nil }
        if let number = value as? NSNumber { return number.intValue != 0 }
        if let text = value as? String {
            let lowered = text.lowercased()
            if lowered == "1" || lowered == "true" || lowered == "on" { return true }
            if lowered == "0" || lowered == "false" || lowered == "off" { return false }
        }
        return nil
    }

    /// "role[title=..., desc=...] value='...'" for traces of header controls.
    static func describeWithValue(_ element: AXUIElement) -> String {
        let value = stringValue(of: element) ?? "nil"
        return "\(describe(element)) value='\(value)'"
    }

    /// The mute or solo control of a track header (0-based index), nil when it cannot be found.
    static func headerToggleElement(index: Int, toggle: HeaderToggle) -> AXUIElement? {
        switch toggle {
        case .mute: return findTrackMuteButton(trackIndex: index)
        case .solo: return findTrackSoloButton(trackIndex: index)
        }
    }

    // MARK: - Names

    /// The name shown on a track header (same extraction as the state poller), nil when the header is missing.
    static func trackHeaderName(index: Int) -> String? {
        guard let header = findTrackHeader(at: index) else { return nil }
        return AXValueExtractors.extractTrackState(from: header, index: index).name
    }

    /// The name of the selected track's header, nil when no track is selected or readable.
    static func selectedTrackName() -> String? {
        guard let index = selectedTrackIndex() else { return nil }
        return trackHeaderName(index: index)
    }

    // MARK: - Transport

    /// Live value of the transport's "Play" checkbox (an AXCheckBox titled or described "Play" in the
    /// control bar). nil when the checkbox cannot be found or read.
    static func transportIsPlaying() -> Bool? {
        guard let box = findTransportButton(named: "Play") else { return nil }
        return toggleState(box)
    }

    // MARK: - Alerts

    /// Press the button titled exactly `title` (case-insensitive) in a sheet or non-project window that
    /// also has a Cancel button (an alert asking for confirmation). Returns the pressed title or nil.
    static func pressConfirmingAlertButton(exactTitle title: String) -> String? {
        let wanted = title.lowercased()
        for container in attentionContainers() {
            let buttons = AXHelpers.findAllDescendants(of: container, role: kAXButtonRole, maxDepth: 8)
            let titles = buttons.compactMap { AXHelpers.getTitle($0)?.lowercased() }
            guard titles.contains("cancel") else { continue }
            for button in buttons {
                let buttonTitle = AXHelpers.getTitle(button) ?? ""
                if buttonTitle.lowercased() == wanted && isEnabled(button) {
                    if AXHelpers.performAction(button, kAXPressAction) { return buttonTitle }
                }
            }
        }
        return nil
    }

    // MARK: - Diagnostics

    /// AX subtree dump of one track header (reuses the dump helper of debug_strip / debug_panel).
    static func debugHeaderDump(index: Int, maxLines: Int = 300) -> String {
        let count = trackHeaderCount()
        guard let header = findTrackHeader(at: index) else {
            return "track header \(index) not found (\(count) track headers visible)"
        }
        var lines: [String] = []
        lines.append("track header \(index) of \(count); selected: \(AXValueExtractors.isTrackSelected(header)); name: '\(trackHeaderName(index: index) ?? "?")'")
        lines.append("mute control: \(findTrackMuteButton(trackIndex: index).map { describeWithValue($0) } ?? "none")")
        lines.append("solo control: \(findTrackSoloButton(trackIndex: index).map { describeWithValue($0) } ?? "none")")
        lines.append("# header subtree")
        dump(header, depth: 0, maxDepth: 8, maxLines: lines.count + maxLines, into: &lines)
        if lines.count >= maxLines { lines.append("... truncated") }
        return lines.joined(separator: "\n")
    }
}
