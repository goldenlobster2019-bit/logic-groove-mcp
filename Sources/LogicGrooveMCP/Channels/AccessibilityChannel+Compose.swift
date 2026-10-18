import ApplicationServices
import CoreGraphics
import Foundation

/// Menu-driven and panel-driven Accessibility operations used by logic_compose,
/// plugin insertion, track creation and editor refresh. Nothing here ever clicks
/// at screen coordinates: every step finds an AX element or reports what it saw.
extension AccessibilityChannel {
    // MARK: - MIDI import

    func importMIDIFile(params: [String: String]) async -> ChannelResult {
        guard let rawPath = params["path"], !rawPath.isEmpty else {
            return .error("Missing 'path' parameter")
        }
        let path: String
        switch ComposeSupport.validateMIDIPath(rawPath) {
        case .success(let value): path = value
        case .failure(let message): return .error(message)
        }
        guard let pid = ProcessUtils.logicProPID() else {
            return .error("Logic Pro is not running")
        }
        guard await FilePanelAutomation.ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front")
        }

        switch AXLogicProElements.pressMenu(["File", "Import", "MIDI File"]) {
        case .pressed:
            break
        case .notFound:
            let entries = AXLogicProElements.menuEntryTitles(path: ["File", "Import"])
            return .error("Menu item File > Import > MIDI File... not found. File > Import entries: \(entries.joined(separator: ", "))")
        case .disabled(let title):
            return .error("Menu item '\(title)' is disabled. Is a project open?")
        case .failed(let title):
            return .error("Failed to press menu item '\(title)'")
        }

        guard await FilePanelAutomation.waitForPanel() else {
            return .error("The MIDI import file panel did not appear within 5 seconds")
        }
        if let failure = await FilePanelAutomation.goTo(path: path, pid: pid) {
            return .error("Import panel: \(failure)")
        }

        var pressed = "none (panel closed after Go to Folder)"
        if AXLogicProElements.filePanel() != nil {
            guard let title = FilePanelAutomation.confirmPanel(buttonTitles: ["Import", "Open"]) else {
                return .error("Could not press the Import/Open button of the file panel (is the file selected and the button enabled?)")
            }
            pressed = title
        }
        _ = await FilePanelAutomation.waitForPanelToClose(timeoutMs: 3_000)

        let tempoNote = await FilePanelAutomation.handleTempoDialog()
        let fileName = (path as NSString).lastPathComponent
        let barText = params["at_bar"].map { " at bar \($0)" } ?? ""
        var message = "Imported \(fileName)\(barText) — verify region placement (pressed '\(pressed)')"
        if let tempoNote {
            message += "; \(tempoNote)"
        }
        Log.info("midi.import_file: \(message)", subsystem: "ax")
        return .unverified(message)
    }

    // MARK: - MIDI export of the selected region

    func exportSelectedMIDI() async -> ChannelResult {
        guard let pid = ProcessUtils.logicProPID() else {
            return .error("Logic Pro is not running")
        }
        let selectMessage = "Select a MIDI region in the Tracks area first"
        guard let item = AXLogicProElements.menuItem(matching: ["File", "Export", "Selection as MIDI File"]) else {
            let entries = AXLogicProElements.menuEntryTitles(path: ["File", "Export"])
            return .error("\(selectMessage) (File > Export > Selection as MIDI File... not found; File > Export entries: \(entries.joined(separator: ", ")))")
        }
        guard AXLogicProElements.isEnabled(item) else {
            return .error(selectMessage)
        }

        let directory = ComposeSupport.exportsDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .error("Cannot create export folder \(directory.path): \(error.localizedDescription)")
        }
        let fileName = "region-\(ComposeSupport.timestamp()).mid"
        let fullPath = directory.appendingPathComponent(fileName).path
        let startedAt = Date()

        guard await FilePanelAutomation.ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front")
        }
        guard AXHelpers.performAction(item, kAXPressAction) else {
            return .error("Failed to press File > Export > Selection as MIDI File")
        }
        guard await FilePanelAutomation.waitForPanel() else {
            return .error("The export save panel did not appear within 5 seconds. \(selectMessage)")
        }
        if let failure = await FilePanelAutomation.goTo(path: directory.path, pid: pid) {
            return .error("Export panel: \(failure)")
        }

        // Wait for the name field, then set the file name.
        var nameSet = false
        var waited = 0
        while waited <= 2_000 {
            if let field = AXLogicProElements.saveNameField() {
                nameSet = AXHelpers.setAttribute(field, kAXValueAttribute, fileName as CFTypeRef)
                break
            }
            guard await FilePanelAutomation.pause(ms: 100) else { return .error("Cancelled") }
            waited += 100
        }
        if !nameSet {
            Log.warn("Save panel name field not settable via AX; typing the name", subsystem: "ax")
            guard await FilePanelAutomation.ensureFrontmost() else {
                return .error("Could not bring Logic Pro to the front")
            }
            _ = FilePanelAutomation.postKey(0, flags: .maskCommand, pid: pid)
            guard FilePanelAutomation.postText(fileName, pid: pid) else {
                return .error("Failed to type the file name")
            }
        }
        guard await FilePanelAutomation.pause(ms: 200) else { return .error("Cancelled") }

        guard FilePanelAutomation.confirmPanel(buttonTitles: ["Save", "Export"]) != nil else {
            return .error("Could not press the Save button of the export panel")
        }
        if let replaced = await FilePanelAutomation.handleReplaceAlert() {
            Log.info("Export: pressed '\(replaced)' on overwrite alert", subsystem: "ax")
        }

        if await FilePanelAutomation.waitForFile(atPath: fullPath) {
            return .success(fullPath)
        }
        // Logic may have appended or altered the extension; accept a fresh .mid in the folder.
        if let fresh = Self.newestMIDIFile(in: directory, since: startedAt) {
            return .success(fresh)
        }
        return .error("Export did not produce a file at \(fullPath) within 5 seconds")
    }

    private static func newestMIDIFile(in directory: URL, since date: Date) -> String? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return nil }
        var best: (path: String, date: Date)?
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "mid" || ext == "midi" else { continue }
            guard let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate else { continue }
            guard modified >= date.addingTimeInterval(-1) else { continue }
            if let current = best, current.date >= modified { continue }
            best = (url.path, modified)
        }
        return best?.path
    }

    // MARK: - Plugin insertion

    func insertPlugin(params: [String: String]) async -> ChannelResult {
        // track_index -1 (or absent) = use the track that is already selected. Verified on
        // Logic Pro 11: AXPress on a track header does not reliably change the selection,
        // so the safest flow is "select the track/region first, then insert".
        let trackIndex = Int(params["track_index"] ?? "-1") ?? -1
        let pluginName = (params["plugin_name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pluginName.isEmpty else {
            return .error("Missing 'plugin_name' parameter")
        }
        let slotText = (params["slot"] ?? "0").lowercased()
        let slot: Int
        if slotText == "instrument" {
            slot = 0
        } else if let parsed = Int(slotText), parsed >= 0 {
            slot = parsed
        } else {
            return .error("Invalid 'slot': use \"instrument\"/0 for the instrument slot or 1, 2, ... for audio effect slots")
        }
        let closeWindow = (params["close_window"] ?? "true").lowercased() != "false"

        if trackIndex >= 0 {
            let selected = selectTrack(params: ["index": String(trackIndex)])
            if case .error = selected {
                return selected
            }
            guard await FilePanelAutomation.pause(ms: 300) else { return .error("Cancelled") }
        }

        // Make sure the Inspector (and with it the channel strip) is visible.
        var strip = AXLogicProElements.inspectorChannelStrip()
        if strip == nil {
            if case .pressed = AXLogicProElements.pressMenu(["View", "Show Inspector"]) {
                _ = await FilePanelAutomation.pause(ms: 500)
                strip = AXLogicProElements.inspectorChannelStrip()
            }
        }
        guard let channelStrip = strip else {
            let entries = AXLogicProElements.menuEntryTitles(path: ["View"])
            return .error("Cannot find the Inspector channel strip (AXLayoutArea described 'Mixer'). Open the Inspector (I). View menu entries: \(entries.joined(separator: ", "))")
        }

        // Locate the slot control.
        let candidates = AXLogicProElements.slotCandidates(in: channelStrip)
        let target: AXUIElement? = AXLogicProElements.pluginSlotButton(slot: slot, candidates: candidates)
        guard let slotElement = target else {
            let kind = slot == 0 ? "instrument slot" : "audio effect slot \(slot)"
            return .error("Cannot find the \(kind) in the Inspector channel strip. Candidates seen (\(candidates.count)): \(AXLogicProElements.diagnostic(of: candidates))")
        }

        let windowsBefore = AXLogicProElements.allWindows()

        // Open the slot menu.
        var opened = AXHelpers.performAction(slotElement, kAXShowMenuAction)
        if !opened {
            opened = AXHelpers.performAction(slotElement, kAXPressAction)
        }
        guard opened else {
            return .error("Could not open the slot menu (neither AXShowMenu nor AXPress worked on \(AXLogicProElements.describe(slotElement)))")
        }

        var menu: AXUIElement?
        for _ in 0..<20 {
            if let found = AXLogicProElements.openedMenu(near: slotElement) {
                menu = found
                break
            }
            guard await FilePanelAutomation.pause(ms: 100) else { return .error("Cancelled") }
        }
        guard let firstMenu = menu else {
            await FilePanelAutomation.pressEscape()
            return .error("No plugin menu appeared after opening the slot. Candidates seen: \(AXLogicProElements.diagnostic(of: candidates))")
        }

        // Use the menu's search field when Logic offers one.
        if let search = AXLogicProElements.menuSearchField(in: firstMenu) {
            if AXHelpers.setAttribute(search, kAXValueAttribute, pluginName as CFTypeRef) {
                guard await FilePanelAutomation.pause(ms: 300) else { return .error("Cancelled") }
            }
        }
        let activeMenu = AXLogicProElements.openedMenu(near: slotElement) ?? firstMenu

        guard let chain = AXLogicProElements.findMenuItemChain(in: activeMenu, containing: pluginName, maxDepth: 4) else {
            let seen = AXLogicProElements.menuEntries(of: activeMenu)
            await FilePanelAutomation.pressEscape()
            return .error("No menu item containing '\(pluginName)' in the plugin menu. Menu entries seen (\(seen.count)): \(AXLogicProElements.diagnostic(of: seen))")
        }
        var fullChain = chain
        if let last = chain.last {
            fullChain.append(contentsOf: AXLogicProElements.leafChain(under: last))
        }

        // Open each submenu in turn, then press the leaf.
        var pressedTitles: [String] = []
        for (offset, item) in fullChain.enumerated() {
            let isLast = offset == fullChain.count - 1
            let title = AXHelpers.getTitle(item) ?? "?"
            let ok = AXHelpers.performAction(item, kAXPressAction)
            if isLast {
                guard ok else {
                    await FilePanelAutomation.pressEscape()
                    return .error("Failed to press menu item '\(title)'")
                }
            }
            pressedTitles.append(title)
            if !isLast {
                _ = await FilePanelAutomation.pause(ms: 150)
            }
        }

        // Logic opens the plugin editor automatically; close anything new.
        _ = await FilePanelAutomation.pause(ms: 700)
        var closed = 0
        if closeWindow {
            for window in AXLogicProElements.allWindows() {
                let existed = windowsBefore.contains(where: { CFEqual($0, window) })
                if existed { continue }
                if let button = AXLogicProElements.closeButton(of: window),
                   AXHelpers.performAction(button, kAXPressAction) {
                    closed += 1
                }
            }
        }

        let slotLabel = slot == 0 ? "instrument slot" : "audio effect slot \(slot)"
        return .unverified("Pressed \(pressedTitles.joined(separator: " > ")) in \(slotLabel) of track \(trackIndex); closed \(closed) new window(s) — verify the plugin loaded")
    }

    // MARK: - Region loop

    func setRegionLoop(params: [String: String]) async -> ChannelResult {
        let text = (params["enabled"] ?? "true").lowercased()
        let desired = (text == "true" || text == "1" || text == "yes" || text == "on")
        guard let box = AXLogicProElements.regionLoopCheckbox() else {
            return .error("Loop checkbox not found. Open the Region inspector (I) and select a region")
        }
        let wanted = desired ? 1 : 0
        if AXLogicProElements.checkboxState(box) == wanted {
            return .success("{\"loop\":\(desired),\"changed\":false}")
        }
        guard AXHelpers.performAction(box, kAXPressAction) else {
            return .error("Failed to press the Region Loop checkbox")
        }
        guard await FilePanelAutomation.pause(ms: 150) else { return .error("Cancelled") }
        if let fresh = AXLogicProElements.regionLoopCheckbox(),
           AXLogicProElements.checkboxState(fresh) == wanted {
            return .success("{\"loop\":\(desired),\"changed\":true}")
        }
        return .unverified("Pressed the Region Loop checkbox; could not confirm it is now \(desired ? "on" : "off")")
    }

    // MARK: - Editor / windows

    func refreshEditor() async -> ChannelResult {
        let candidates: [[String]] = [["View", "Editor"], ["View", "Hide Editor"], ["View", "Show Editor"]]
        for pass in 0..<2 {
            var pressed = false
            for path in candidates {
                if case .pressed = AXLogicProElements.pressMenu(path) {
                    pressed = true
                    break
                }
            }
            guard pressed else {
                let entries = AXLogicProElements.menuEntryTitles(path: ["View"])
                return .error("View > Editor menu item not found. View entries: \(entries.joined(separator: ", "))")
            }
            if pass == 0 {
                guard await FilePanelAutomation.pause(ms: 300) else { return .error("Cancelled") }
            }
        }
        return .unverified("Editor closed and reopened via the View menu; it should follow the current selection")
    }

    func openPianoRollWindow() async -> ChannelResult {
        for name in ["Open Piano Roll", "Piano Roll"] {
            switch AXLogicProElements.pressMenu(["Window", name]) {
            case .pressed(let title):
                return .unverified("Pressed Window > \(title)")
            case .disabled(let title):
                return .error("Window > \(title) is disabled. Select a MIDI region first")
            case .failed(let title):
                return .error("Failed to press Window > \(title)")
            case .notFound:
                continue
            }
        }
        let entries = AXLogicProElements.menuEntryTitles(path: ["Window"])
        return .error("Window > Open Piano Roll not found. Window entries: \(entries.joined(separator: ", "))")
    }

    // MARK: - Undo label

    func lastUndo() -> ChannelResult {
        guard let title = AXLogicProElements.undoMenuTitle() else {
            return .error("Cannot read the first Edit menu item")
        }
        return .success(title)
    }

    // MARK: - Track creation

    func createTrack(operation: String) async -> ChannelResult {
        let candidates: [String]
        switch operation {
        case "track.create_audio":
            candidates = ["New Audio Track"]
        case "track.create_instrument":
            candidates = ["New Software Instrument Track"]
        case "track.create_external_midi":
            candidates = ["New External MIDI Track"]
        case "track.create_drummer":
            candidates = ["New Drummer Track", "New Session Player"]
        default:
            return .error("Unsupported track creation operation: \(operation)")
        }

        for name in candidates {
            switch AXLogicProElements.pressMenu(["Track", name]) {
            case .pressed(let title):
                // Some Logic versions answer with the New Tracks dialog; confirm it.
                var confirmed = false
                for _ in 0..<8 {
                    guard await FilePanelAutomation.pause(ms: 100) else { return .error("Cancelled") }
                    if AXLogicProElements.pressNewTracksCreate() {
                        confirmed = true
                        break
                    }
                }
                let suffix = confirmed ? " (confirmed the New Tracks dialog)" : ""
                return .unverified("Pressed Track > \(title)\(suffix) — verify the new track exists")
            case .disabled(let title):
                return .error("Track > \(title) is disabled")
            case .failed(let title):
                return .error("Failed to press Track > \(title)")
            case .notFound:
                continue
            }
        }
        let entries = AXLogicProElements.menuEntryTitles(path: ["Track"])
        return .error("Track menu item not found (\(candidates.joined(separator: " / "))). Track entries: \(entries.joined(separator: ", "))")
    }
}
