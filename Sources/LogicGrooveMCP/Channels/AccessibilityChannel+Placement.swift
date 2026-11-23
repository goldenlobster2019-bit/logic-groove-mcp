import ApplicationServices
import CoreGraphics
import Foundation

/// Region placement on an existing track and cycle-to-regions, all through Edit / Track / Navigate
/// menu items and verified track selection. Written without a live test: every step reports a trace.
extension AccessibilityChannel {
    /// Text for a menu press that did not end in `.pressed`, with the entries Logic showed.
    private static func menuFailure(_ outcome: MenuPressOutcome, path: [String]) -> String {
        let label = path.joined(separator: " > ")
        switch outcome {
        case .pressed:
            return "\(label) pressed"
        case .notFound:
            let entries = AXLogicProElements.menuEntryTitles(path: Array(path.dropLast()))
            return "\(label) not found (entries seen: \(entries.joined(separator: ", ")))"
        case .disabled(let title):
            return "\(label) is disabled ('\(title)')"
        case .failed(let title):
            return "\(label) could not be pressed ('\(title)')"
        }
    }

    // MARK: - Cycle to regions

    func cycleToRegions() async -> ChannelResult {
        guard await FilePanelAutomation.ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front")
        }
        var trace: [String] = []
        let selectAll = ["Edit", "Select", "All"]
        let outcome1 = AXLogicProElements.pressMenu(selectAll)
        guard case .pressed = outcome1 else {
            return .error("cycle_to_regions: \(Self.menuFailure(outcome1, path: selectAll))")
        }
        trace.append("Edit > Select > All pressed")
        guard await FilePanelAutomation.pause(ms: 300) else { return .error("Cancelled") }

        let locators = ["Navigate", "Set Rounded Locators by Selection and Enable Cycle"]
        let outcome2 = AXLogicProElements.pressMenu(locators)
        guard case .pressed(let title) = outcome2 else {
            return .error("cycle_to_regions: \(Self.menuFailure(outcome2, path: locators)); the regions stay selected. Trace: \(trace.joined(separator: "; "))")
        }
        trace.append("Navigate > '\(title)' pressed")
        return .unverified("Cycle set to the regions and enabled (not read back). Trace: \(trace.joined(separator: "; "))")
    }

    // MARK: - Put the imported region on an existing track

    /// Phase 1 of placing an imported clip on an existing track. Right after a MIDI import the new
    /// track (index `new_index`) is the last one and holds the selected region. Cuts the region,
    /// deletes the now empty temporary track (only when its selection is verified), then selects the
    /// target track (`track`) with read-back. The region stays on the clipboard for `pasteOnTrack`.
    func moveSelectedToTrack(params: [String: String]) async -> ChannelResult {
        guard let newIndex = Int(params["new_index"] ?? ""), newIndex >= 0,
              let target = Int(params["track"] ?? ""), target >= 0 else {
            return .error("region.move_selected_to_track needs 'new_index' and 'track' (0-based)")
        }
        guard target != newIndex else {
            return .error("The target track is the newly created track; nothing to move")
        }
        let headerCount = AXLogicProElements.trackHeaderCount()
        guard headerCount == newIndex + 1 else {
            return .error("Expected \(newIndex + 1) track headers after the import but see \(headerCount); the region was not moved")
        }
        guard await FilePanelAutomation.ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front")
        }
        var trace: [String] = []
        func traceText() -> String { trace.joined(separator: "; ") }

        // 1. Cut the selected (imported) region with the key command: the Edit > Cut menu item pressed
        // through Accessibility did not cut (live test), and key commands only work while Logic is frontmost.
        guard FilePanelAutomation.postKeyGlobal(7, flags: .maskCommand) else {
            return .error("Could not post Cmd+X. The region stays on the new track \(newIndex)")
        }
        trace.append("posted Cmd+X")
        guard await FilePanelAutomation.pause(ms: 400) else { return .error("Cancelled") }
        // Confirm the cut before anything is deleted or pasted: if it silently did nothing,
        // deleting the temporary track would lose the region and Paste would insert stale
        // clipboard content. The Edit menu (read while Logic is frontmost) then reads "Undo Cut ...".
        let undoAfterCut = AXLogicProElements.undoMenuTitle() ?? "none"
        trace.append("undo title after cut '\(undoAfterCut)'")
        guard undoAfterCut.lowercased().contains("cut") else {
            return .error("The cut was not confirmed (Edit menu shows '\(undoAfterCut)'); nothing was deleted or pasted, the region stays on the new track \(newIndex). Trace: \(traceText())")
        }

        // 2. Delete the empty temporary track, only with a verified selection.
        let temporary = await selectTrackVerified(index: newIndex)
        trace.append(contentsOf: temporary.trace)
        if temporary.ok {
            let deletePath = ["Track", "Delete Track"]
            let delete = AXLogicProElements.pressMenu(deletePath)
            if case .pressed = delete {
                trace.append("Track > Delete Track pressed")
                guard await FilePanelAutomation.pause(ms: 400) else { return .error("Cancelled") }
                let dialogButtons = AXLogicProElements.attentionContainers().flatMap { AXLogicProElements.buttonTitles(in: $0) }
                if dialogButtons.contains(where: { $0.lowercased() == "cancel" }) {
                    let pressed = AXLogicProElements.pressAlertButton(titleContaining: "cancel")
                    trace.append("a dialog with buttons [\(dialogButtons.joined(separator: ", "))] appeared; pressed '\(pressed ?? "nothing")'; delete left undone")
                }
                var after = AXLogicProElements.trackHeaderCount()
                var waited = 0
                while after != newIndex && waited < 1_500 {
                    guard await FilePanelAutomation.pause(ms: 150) else { return .error("Cancelled") }
                    waited += 150
                    after = AXLogicProElements.trackHeaderCount()
                }
                trace.append(after == newIndex
                    ? "temporary track deleted (headers \(headerCount) -> \(after))"
                    : "temporary track NOT deleted (headers \(headerCount) -> \(after)); it was left in place")
            } else {
                trace.append("delete skipped: \(Self.menuFailure(delete, path: deletePath)); temporary track left in place")
            }
        } else {
            trace.append("temporary track left in place (its selection was not verified, so nothing was deleted)")
        }

        // 3. Select the target track with read-back.
        let selection = await selectTrackVerified(index: target)
        trace.append(contentsOf: selection.trace)
        guard selection.ok else {
            return .error("Track \(target) could not be selected (read back). The region is on the clipboard and was NOT pasted. Trace: \(traceText())")
        }
        return .success("Region cut; track \(target) selected. Trace: \(traceText())")
    }

    /// Phase 2: with the target track selected and the playhead at the wanted bar, paste the region (Cmd+V, confirmed by the Undo title).
    /// The target selection is read back again first (and re-selected once when it moved).
    func pasteOnTrack(params: [String: String]) async -> ChannelResult {
        guard let target = Int(params["track"] ?? ""), target >= 0 else {
            return .error("region.paste_on_track needs 'track' (0-based)")
        }
        let bar = params["bar"] ?? "1"
        guard await FilePanelAutomation.ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front")
        }
        var trace: [String] = []
        if AXLogicProElements.selectedTrackIndex() != target {
            let selection = await selectTrackVerified(index: target)
            trace.append(contentsOf: selection.trace)
            guard selection.ok else {
                return .error("The selection moved away from track \(target) and could not be restored; the region is on the clipboard and was NOT pasted. Trace: \(trace.joined(separator: "; "))")
            }
        } else {
            trace.append("track \(target) still selected")
        }
        guard await FilePanelAutomation.ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front for the paste; the region is on the clipboard. Trace: \(trace.joined(separator: "; "))")
        }
        guard FilePanelAutomation.postKeyGlobal(9, flags: .maskCommand) else {
            return .error("Could not post Cmd+V. The region is on the clipboard. Trace: \(trace.joined(separator: "; "))")
        }
        trace.append("posted Cmd+V")
        guard await FilePanelAutomation.pause(ms: 500) else { return .error("Cancelled") }
        let undoAfterPaste = AXLogicProElements.undoMenuTitle() ?? "none"
        trace.append("undo title after paste '\(undoAfterPaste)'")
        guard undoAfterPaste.lowercased().contains("paste") else {
            return .error("The paste was not confirmed (Edit menu shows '\(undoAfterPaste)'); nothing else was done. The region may still be on the clipboard. Trace: \(trace.joined(separator: "; "))")
        }
        return .success("Region pasted on track \(target) at bar \(bar) (Edit menu: '\(undoAfterPaste)'). Trace: \(trace.joined(separator: "; "))")
    }
}
