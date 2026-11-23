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
        guard ProcessUtils.logicProPID() != nil else {
            return .error("Logic Pro is not running")
        }
        let fileName = (path as NSString).lastPathComponent
        let barText = params["at_bar"].map { " at bar \($0)" } ?? ""

        // Stage the file at a fixed path: the Go to sheet remembers the last path, so with a
        // fixed path the pre-filled value normally already matches and nothing has to be typed.
        let staging = ComposeSupport.importStagingURL()
        let stagedPath = staging.path
        let stagedName = staging.lastPathComponent
        var didStage = false
        if !ComposeSupport.pathsEqual(path, stagedPath) {
            do {
                try FileManager.default.createDirectory(
                    at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: stagedPath) {
                    try FileManager.default.removeItem(atPath: stagedPath)
                }
                try FileManager.default.copyItem(atPath: path, toPath: stagedPath)
                didStage = true
            } catch {
                return .error("Could not stage \(fileName) at \(stagedPath): \(error.localizedDescription). Nothing was done.")
            }
        }

        let tracksBefore = AXLogicProElements.trackHeaderCount()
        let undoBefore = AXLogicProElements.undoMenuTitle()
        // Strict check: a plug-in window (an AXDialog) must not block the import.
        if let existingPanel = AXLogicProElements.importPanel() {
            let existing = AXLogicProElements.panelSummary(of: existingPanel)
            return .error("A file panel is already open (\(existing)); close it and retry. Nothing was done.")
        }
        guard await FilePanelAutomation.ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front")
        }

        var trace: [String] = []
        if didStage { trace.append("staged as \(stagedPath)") }
        func traceText() -> String { trace.joined(separator: "; ") }
        func finish(_ message: String, isError: Bool) -> ChannelResult {
            Log.info("midi.import_file: \(message)", subsystem: "ax")
            return isError ? .error(message) : .success(message)
        }
        func bail(_ reason: String) -> ChannelResult {
            if AXLogicProElements.cancelFilePanel() { trace.append("cancelled the panel") }
            return finish("Import of \(fileName) failed: \(reason). Trace: \(traceText())", isError: true)
        }

        switch AXLogicProElements.pressMenu(["File", "Import", "MIDI File"]) {
        case .pressed:
            trace.append("menu pressed")
        case .notFound:
            let entries = AXLogicProElements.menuEntryTitles(path: ["File", "Import"])
            return .error("Menu item File > Import > MIDI File... not found. File > Import entries: \(entries.joined(separator: ", "))")
        case .disabled(let title):
            return .error("Menu item '\(title)' is disabled. Is a project open?")
        case .failed(let title):
            return .error("Failed to press menu item '\(title)'")
        }

        guard await FilePanelAutomation.waitForImportPanel() else {
            let other = AXLogicProElements.filePanelSummary() ?? "none"
            return finish("Import of \(fileName) failed: the import panel did not appear within 5 seconds (other panel: \(other)). Trace: \(traceText())", isError: true)
        }
        trace.append("import panel up")

        // Strategy A: select the file through Accessibility, then press Import. Only when the panel
        // exposes file rows at all (it does not in column view).
        var pressed = false
        var buttonState = "missing"
        if AXLogicProElements.panelExposesRows() {
            let selection = AXLogicProElements.selectFileInPanel(named: stagedName)
            trace.append("A \(selection)")
            guard await FilePanelAutomation.pause(ms: 400) else { return bail("cancelled") }
            buttonState = AXLogicProElements.panelConfirmButtonState(titles: ["Import", "Open"])
            trace.append("A button \(buttonState)")
            if buttonState.hasPrefix("enabled:") {
                if let title = AXLogicProElements.pressImportPanelButton(titles: ["Import", "Open"]) {
                    trace.append("pressed '\(title)'")
                    pressed = true
                } else {
                    trace.append("press failed")
                }
            }
        } else {
            trace.append("A skipped: no rows exposed")
        }

        // Strategy K (keyboard, no typing): the panel reopens in the last used folder. When that is the
        // staging folder and it holds exactly one file, focus the column browser and let Right / Down
        // arrow select the file; Import is pressed only when it enabled and the folder is unchanged.
        if !pressed {
            let folder = staging.deletingLastPathComponent()
            let folderName = folder.lastPathComponent
            let whereValue = AXLogicProElements.panelWhereValue()
            let entryCount = ComposeSupport.nonHiddenEntryCount(in: folder)
            let stagedExists = FileManager.default.fileExists(atPath: stagedPath)
            let whereMatches = whereValue.map { $0.caseInsensitiveCompare(folderName) == .orderedSame } ?? false
            if whereMatches && entryCount == 1 && stagedExists {
                trace.append("K Where='\(whereValue ?? "")', 1 file in the staging folder")
                trace.append("K \(AXLogicProElements.focusPanelBrowser())")
                guard await FilePanelAutomation.ensureFrontmost() else { return bail("Could not bring Logic Pro to the front") }
                guard FilePanelAutomation.postKeyGlobal(124, flags: []) else { return bail("Failed to post Right") }
                guard await FilePanelAutomation.pause(ms: 350) else { return bail("cancelled") }
                buttonState = AXLogicProElements.panelConfirmButtonState(titles: ["Import", "Open"])
                trace.append("K after Right: button \(buttonState)")
                if !buttonState.hasPrefix("enabled:") {
                    guard FilePanelAutomation.postKeyGlobal(125, flags: []) else { return bail("Failed to post Down") }
                    guard await FilePanelAutomation.pause(ms: 350) else { return bail("cancelled") }
                    buttonState = AXLogicProElements.panelConfirmButtonState(titles: ["Import", "Open"])
                    trace.append("K after Down: button \(buttonState)")
                }
                if buttonState.hasPrefix("enabled:") {
                    let whereAgain = AXLogicProElements.panelWhereValue()
                    let stillThere = whereAgain.map { $0.caseInsensitiveCompare(folderName) == .orderedSame } ?? false
                    if stillThere, let title = AXLogicProElements.pressImportPanelButton(titles: ["Import", "Open"]) {
                        trace.append("K pressed '\(title)'")
                        pressed = true
                    } else {
                        trace.append("K not pressed: Where is now '\(whereAgain ?? "?")' (need '\(folderName)') or the press failed")
                    }
                } else {
                    trace.append("K: the Import button stayed disabled; going on to B")
                }
            } else {
                trace.append("K skipped: Where='\(whereValue ?? "?")' (need '\(folderName)'), \(entryCount) entr\(entryCount == 1 ? "y" : "ies") in the staging folder (need 1), staged file exists: \(stagedExists)")
            }
        }

        // Strategy B: Go to sheet (path pasted, typed only as a fallback), only when A and K did not press Import.
        if !pressed {
            let goTo = await FilePanelAutomation.goToChecked(path: stagedPath)
            trace.append(contentsOf: goTo.notes.map { "B \($0)" })
            if let error = goTo.error {
                return bail(error)
            }
            if AXLogicProElements.importPanel() == nil {
                trace.append("panel closed by Return")
            } else {
                buttonState = AXLogicProElements.panelConfirmButtonState(titles: ["Import", "Open"])
                trace.append("B button \(buttonState)")
                if !buttonState.hasPrefix("enabled:") {
                    let again = AXLogicProElements.selectFileInPanel(named: stagedName)
                    trace.append("B \(again)")
                    guard await FilePanelAutomation.pause(ms: 400) else { return bail("cancelled") }
                    buttonState = AXLogicProElements.panelConfirmButtonState(titles: ["Import", "Open"])
                    trace.append("B button \(buttonState)")
                }
                guard buttonState.hasPrefix("enabled:"),
                      let title = AXLogicProElements.pressImportPanelButton(titles: ["Import", "Open"]) else {
                    return bail("the Import button stayed disabled or could not be pressed")
                }
                trace.append("pressed '\(title)'")
            }
        }

        let closed = await FilePanelAutomation.waitForImportPanelToClose(timeoutMs: 3_000)
        trace.append(closed ? "panel closed" : "panel still open 3 s later")
        if let tempoNote = await FilePanelAutomation.handleTempoDialog() {
            trace.append(tempoNote)
        }
        // Logic may ask to download missing content for the patch picked from the file's Program Change.
        var promptWaited = 0
        while promptWaited <= 1_500 {
            if AXLogicProElements.dismissDownloadPrompt() != nil {
                trace.append(AXLogicProElements.downloadPromptTraceText)
                break
            }
            guard await FilePanelAutomation.pause(ms: 100) else { break }
            promptWaited += 100
        }

        // Verify by track count only. The Undo title is read for the message but is not a
        // reliable signal (it flips between "Can't Undo" and "Undo" without any import).
        var tracksAfter = AXLogicProElements.trackHeaderCount()
        var undoAfter = AXLogicProElements.undoMenuTitle()
        var waited = 0
        while tracksAfter <= tracksBefore && waited < 6_000 {
            guard await FilePanelAutomation.pause(ms: 300) else { break }
            waited += 300
            tracksAfter = AXLogicProElements.trackHeaderCount()
            undoAfter = AXLogicProElements.undoMenuTitle()
        }
        if AXLogicProElements.importPanel() != nil, AXLogicProElements.cancelFilePanel() {
            trace.append("cancelled a leftover panel")
        }
        let undoOld = undoBefore ?? "none"
        let undoNew = undoAfter ?? "none"
        let verified = tracksAfter > tracksBefore
        if verified {
            return finish(
                "Imported \(fileName)\(barText) (verified: tracks \(tracksBefore) -> \(tracksAfter), undo '\(undoOld)' -> '\(undoNew)'). Trace: \(traceText())",
                isError: false
            )
        }
        return finish(
            "Import of \(fileName) was NOT confirmed (tracks \(tracksBefore) -> \(tracksAfter), undo '\(undoOld)' -> '\(undoNew)'). Trace: \(traceText())",
            isError: true
        )
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
            _ = AXLogicProElements.cancelFilePanel()
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

    // MARK: - Verified track selection

    /// Select a track (0-based) and read the selection back through Accessibility. Returns ok only
    /// when `AXLogicProElements.selectedTrackIndex()` equals `index`. Attempts, in order, each followed
    /// by a 200 ms wait and a re-read: (1) AXPress on the header, (2) AXSelected = true, (3) Up/Down
    /// arrow keys (only when nothing but the project window is focused), (4) a real mouse click on the
    /// track number column of the header.
    ///
    /// This is the ONLY place in the server where a synthetic mouse click is allowed (last resort).
    func selectTrackVerified(index: Int) async -> (ok: Bool, trace: [String]) {
        var trace: [String] = []
        if AXLogicProElements.dismissDownloadPrompt() != nil {
            trace.append(AXLogicProElements.downloadPromptTraceText)
            _ = await FilePanelAutomation.pause(ms: 300)
        }
        let count = AXLogicProElements.trackHeaderCount()
        guard index >= 0, index < count else {
            trace.append("track \(index) out of range (\(count) track headers visible)")
            return (false, trace)
        }
        var current = AXLogicProElements.selectedTrackIndex()
        if current == index {
            trace.append("track \(index) already selected")
            return (true, trace)
        }
        trace.append("select track \(index): selected now \(current.map(String.init) ?? "unknown")")

        // 1. The existing AX way.
        let pressed = selectTrack(params: ["index": String(index)])
        guard await FilePanelAutomation.pause(ms: 200) else { return (false, trace + ["cancelled"]) }
        current = AXLogicProElements.selectedTrackIndex()
        trace.append("AXPress \(pressed.isSuccess ? "ok" : "failed") -> selected \(current.map(String.init) ?? "unknown")")
        if current == index { return (true, trace) }

        // 2. AXSelected on the header.
        let attribute = AXLogicProElements.setTrackHeaderSelected(index: index)
        guard await FilePanelAutomation.pause(ms: 200) else { return (false, trace + ["cancelled"]) }
        current = AXLogicProElements.selectedTrackIndex()
        trace.append("\(attribute) -> selected \(current.map(String.init) ?? "unknown")")
        if current == index { return (true, trace) }

        // 3. Arrow keys, relative to the known selection.
        if let known = current, let pid = ProcessUtils.logicProPID() {
            if await FilePanelAutomation.ensureFrontmost() {
                if let reason = AXLogicProElements.arrowKeysUnsafeReason() {
                    trace.append("arrow keys skipped: \(reason)")
                } else {
                    let delta = index - known
                    let keyCode: CGKeyCode = delta > 0 ? 125 : 126 // Down / Up
                    for _ in 0..<abs(delta) {
                        _ = FilePanelAutomation.postKey(keyCode, flags: [], pid: pid)
                        guard await FilePanelAutomation.pause(ms: 60) else { return (false, trace + ["cancelled"]) }
                    }
                    guard await FilePanelAutomation.pause(ms: 200) else { return (false, trace + ["cancelled"]) }
                    current = AXLogicProElements.selectedTrackIndex()
                    trace.append("arrow \(delta > 0 ? "Down" : "Up") x\(abs(delta)) -> selected \(current.map(String.init) ?? "unknown")")
                    if current == index { return (true, trace) }
                }
            } else {
                trace.append("arrow keys skipped: Logic Pro could not be brought to the front")
            }
        } else {
            trace.append("arrow keys skipped: current selection unknown or Logic Pro not running")
        }

        // 4. Last resort: a real click on the track number column.
        if AXLogicProElements.importPanel() != nil {
            trace.append("click skipped: a file panel is open")
        } else if let point = AXLogicProElements.trackHeaderClickPoint(index: index) {
            if await FilePanelAutomation.ensureFrontmost() {
                let clicked = await FilePanelAutomation.clickGlobal(at: point)
                guard await FilePanelAutomation.pause(ms: 200) else { return (false, trace + ["cancelled"]) }
                current = AXLogicProElements.selectedTrackIndex()
                trace.append("click at (\(Int(point.x)),\(Int(point.y))) \(clicked ? "posted" : "failed") -> selected \(current.map(String.init) ?? "unknown")")
                if current == index { return (true, trace) }
            } else {
                trace.append("click skipped: Logic Pro could not be brought to the front")
            }
        } else {
            trace.append("click skipped: no usable header frame inside the project window")
        }
        trace.append("track \(index) could not be selected")
        return (false, trace)
    }

    // MARK: - Plugin insertion

    /// Press Escape once (closes a possibly open menu) and return an error carrying the trace.
    private func failWithEscape(trace: [String], reason: String) async -> ChannelResult {
        await FilePanelAutomation.pressEscape()
        return .error("\(reason). Trace: \((trace + ["pressed Escape"]).joined(separator: "; "))")
    }

    /// Insert a plug-in through the Inspector slot menu: press the slot (found by structure), type the
    /// name into the menu's search field, Down / Right / Return, confirm by the new plug-in window and
    /// then by the channel strip structure. Never types or presses Return unless the focused element was
    /// confirmed through AX; never acts when the target track selection could not be read back.
    ///
    /// `slot`: "instrument" / 0 = the instrument slot; "new" / "add" / "append" (default) = add an effect
    /// in the empty slot; n >= 1 = REPLACE the n-th existing effect (n beyond the effect count = new).
    func insertPlugin(params: [String: String]) async -> ChannelResult {
        let trackIndex = Int(params["track_index"] ?? "-1") ?? -1
        let pluginName = (params["plugin_name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pluginName.isEmpty else {
            return .error("Missing 'plugin_name' parameter")
        }
        guard let request = PluginSlotRequest.parse(params["slot"]) else {
            return .error("Invalid 'slot': use \"instrument\"/0, \"new\" (default, adds an effect) or 1, 2, ... (replaces that effect)")
        }
        let closeWindow = (params["close_window"] ?? "true").lowercased() != "false"
        guard let resultIndex = Int(params["result_index"] ?? "1"), (1...50).contains(resultIndex) else {
            return .error("'result_index' must be between 1 and 50")
        }
        guard let variantIndex = Int(params["variant_index"] ?? "1"), (1...20).contains(variantIndex) else {
            return .error("'variant_index' must be between 1 and 20")
        }

        // 1-2. Verified track selection and Inspector strip.
        let prep = await prepareStrip(trackIndex: trackIndex, requireTrack: true)
        var trace: [String] = prep.trace
        func traceText() -> String { trace.joined(separator: "; ") }
        if let error = prep.error { return .error(error) }

        // 3. Read the strip and decide which button to press.
        guard let before = AXLogicProElements.stripModel() else {
            return .error("Could not read the selected track's channel strip. Nothing was changed. Trace: \(traceText())")
        }
        trace.append("strip before: \(before.chainText)")
        let kind: PluginSlotKind
        let slotLabel: String
        switch request {
        case .instrument:
            guard before.instrument != nil || before.hasMidiPluginButton || before.hasEmptyInstrumentSlot else {
                return .error("This strip has no instrument slot (no instrument plug-in group and no 'MIDI plug-in' button); nothing was changed. Strip: \(before.compactJSON()). Trace: \(traceText())")
            }
            kind = .instrument
            slotLabel = "instrument slot"
        case .newEffect:
            guard before.hasEmptyEffectSlot else {
                return .error("This strip has no empty audio effect slot ('audio plug-in' button); nothing was changed. Strip: \(before.compactJSON()). Trace: \(traceText())")
            }
            kind = .newEffect
            slotLabel = "new audio effect slot"
        case .effect(let n):
            if n > before.effects.count {
                trace.append("slot \(n) is beyond the \(before.effects.count) existing effect(s); treating it as new")
                guard before.hasEmptyEffectSlot else {
                    return .error("Slot \(n) does not exist and there is no empty audio effect slot; nothing was changed. Strip: \(before.compactJSON()). Trace: \(traceText())")
                }
                kind = .newEffect
                slotLabel = "new audio effect slot"
            } else {
                kind = .effect(n)
                slotLabel = "audio effect \(n) (replaced)"
            }
        }

        guard await FilePanelAutomation.ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front. Trace: \(traceText())")
        }

        // 4. Press the slot and wait for the menu's search field to take the focus.
        let titlesBefore = AXLogicProElements.windowTitles()
        let focusBefore = AXLogicProElements.focusedFieldSummary()
        let tokenBefore = AXLogicProElements.focusedElementToken()
        trace.append("windows before: \(titlesBefore.count); focus before: \(focusBefore ?? "none")")

        let press = AXLogicProElements.pressPluginList(slotKind: kind)
        guard press.found else {
            return await failWithEscape(trace: trace, reason: "Cannot find the \(slotLabel) in the Inspector channel strip (\(press.diagnostic))")
        }
        trace.append(press.traceText)
        var foundField: String?
        var waited = 0
        while waited <= 3_000, foundField == nil {
            guard await FilePanelAutomation.pause(ms: 100) else { return .error("Cancelled") }
            waited += 100
            if AXLogicProElements.focusedIsAnyTextField() {
                let summary = AXLogicProElements.focusedFieldSummary()
                if summary != focusBefore || AXLogicProElements.focusedElementToken() != tokenBefore {
                    foundField = summary ?? "text field"
                }
            }
        }
        guard let fieldSummary = foundField else {
            return await failWithEscape(trace: trace, reason: "The slot menu did not open or has no search field (\(AXLogicProElements.openedMenuSummary()); focus now: \(AXLogicProElements.focusedFieldSummary() ?? "none"))")
        }
        trace.append("menu search field focused: \(fieldSummary)")

        // 5. Type the name and read it back.
        guard await FilePanelAutomation.ensureFrontmost() else { return await failWithEscape(trace: trace, reason: "Could not bring Logic Pro to the front") }
        guard await FilePanelAutomation.typeTextGlobal(pluginName) else { return await failWithEscape(trace: trace, reason: "Failed to type the plug-in name") }
        guard await FilePanelAutomation.pause(ms: 500) else { return .error("Cancelled") }
        let typed = (AXLogicProElements.focusedFieldValue() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        trace.append("typed '\(pluginName)', field holds '\(String(typed.prefix(60)))'")
        guard typed.lowercased() == pluginName.lowercased() else {
            return await failWithEscape(trace: trace, reason: "The search field does not hold the typed name ('\(String(typed.prefix(60)))'); nothing was selected")
        }

        // 6. Down (result_index times), Right (submenu), Down (variant_index - 1 times), Return.
        guard await FilePanelAutomation.ensureFrontmost() else { return await failWithEscape(trace: trace, reason: "Could not bring Logic Pro to the front") }
        for _ in 0..<resultIndex {
            guard FilePanelAutomation.postKeyGlobal(125, flags: []) else { return await failWithEscape(trace: trace, reason: "Failed to post Down") }
            guard await FilePanelAutomation.pause(ms: 60) else { return .error("Cancelled") }
        }
        guard await FilePanelAutomation.pause(ms: 150) else { return .error("Cancelled") }
        guard FilePanelAutomation.postKeyGlobal(124, flags: []) else { return await failWithEscape(trace: trace, reason: "Failed to post Right") }
        guard await FilePanelAutomation.pause(ms: 250) else { return .error("Cancelled") }
        for _ in 0..<(variantIndex - 1) {
            guard FilePanelAutomation.postKeyGlobal(125, flags: []) else { return await failWithEscape(trace: trace, reason: "Failed to post Down") }
            guard await FilePanelAutomation.pause(ms: 60) else { return .error("Cancelled") }
        }
        guard FilePanelAutomation.postKeyGlobal(36, flags: []) else { return await failWithEscape(trace: trace, reason: "Failed to post Return") }
        trace.append("keys: Down x\(resultIndex), Right, Down x\(variantIndex - 1), Return")

        // 7. Confirm by the new plug-in window.
        var newTitles: [String] = []
        waited = 0
        while waited <= 5_000 {
            guard await FilePanelAutomation.pause(ms: 100) else { return .error("Cancelled") }
            waited += 100
            newTitles = AXLogicProElements.newWindowTitles(since: titlesBefore)
            if !newTitles.isEmpty { break }
        }
        guard !newTitles.isEmpty else {
            // The window may simply not have been detected: trust the strip structure when it shows the plug-in.
            var recheck: StripModel?
            var confirmedByStrip = false
            var extra = 0
            while extra <= 1_500 {
                recheck = AXLogicProElements.stripModel()
                if let recheck, Self.stripConfirmsInsert(kind: kind, before: before, after: recheck, pluginName: pluginName) {
                    confirmedByStrip = true
                    break
                }
                guard await FilePanelAutomation.pause(ms: 300) else { return .error("Cancelled") }
                extra += 300
            }
            if confirmedByStrip, let recheck {
                trace.append("no new plug-in window within 5 seconds, but the strip shows the plug-in")
                let trackText = trackIndex >= 0 ? String(trackIndex) : AXLogicProElements.selectedTrackSummary()
                return .success("Inserted \(pluginName) in \(slotLabel) of track \(trackText); the plug-in window did not appear but the channel strip confirms the insert (nothing was closed). chain: \(recheck.chainText). Trace: \(traceText())")
            }
            return await failWithEscape(trace: trace, reason: "Plug-in '\(pluginName)' was not confirmed (no new plug-in window within 5 seconds and the strip does not show it; strip now: \(recheck?.chainText ?? "unreadable"))")
        }
        let windowTitle = newTitles.joined(separator: " | ")
        trace.append("new window: '\(windowTitle)' after \(waited) ms")

        // 8. Close only the new window(s).
        if closeWindow {
            _ = await FilePanelAutomation.pause(ms: 300)
            let closed = AXLogicProElements.closeNewWindows(since: titlesBefore)
            trace.append("closed \(closed) new window(s) through their close button")
        }

        // 9. Verify by the strip structure (poll up to 2 s while the strip refreshes).
        var after: StripModel?
        var structural = false
        waited = 0
        while waited <= 2_000 {
            guard await FilePanelAutomation.pause(ms: 300) else { return .error("Cancelled") }
            waited += 300
            after = AXLogicProElements.stripModel()
            if let after {
                structural = Self.stripConfirmsInsert(kind: kind, before: before, after: after, pluginName: pluginName)
            }
            if structural { break }
        }
        let afterChain = after?.chainText ?? "strip unreadable"
        trace.append("strip after: \(afterChain)")
        guard structural else {
            return .error("A plug-in window appeared ('\(windowTitle)') but the channel strip does not show '\(pluginName)' in the \(slotLabel). Strip before: \(before.compactJSON()). Strip after: \(after?.compactJSON() ?? "unreadable"). Trace: \(traceText())")
        }

        let trackText = trackIndex >= 0 ? String(trackIndex) : AXLogicProElements.selectedTrackSummary()
        return .success("Inserted \(pluginName) in \(slotLabel) of track \(trackText) (window '\(windowTitle)'). chain: \(afterChain). Trace: \(traceText())")
    }

    /// Whether `after` shows `pluginName` in the slot kind that was addressed, compared with `before`.
    static func stripConfirmsInsert(kind: PluginSlotKind, before: StripModel, after: StripModel, pluginName: String) -> Bool {
        switch kind {
        case .instrument:
            return after.instrument.map { ComposeSupport.pluginNameMatches($0.name, pluginName) } ?? false
        case .newEffect:
            return after.effects.count == before.effects.count + 1
                && (after.effects.last.map { ComposeSupport.pluginNameMatches($0.name, pluginName) } ?? false)
        case .effect(let n):
            return after.effects.count == before.effects.count
                && after.effects.indices.contains(n - 1)
                && ComposeSupport.pluginNameMatches(after.effects[n - 1].name, pluginName)
        }
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

        var trace: [String] = []
        if AXLogicProElements.dismissDownloadPrompt() != nil {
            trace.append(AXLogicProElements.downloadPromptTraceText)
        }
        if !AXLogicProElements.focusedWindowIsProject() {
            let raised = AXLogicProElements.raiseProjectWindow()
            trace.append("project window was not the focused window (\(AXLogicProElements.focusedWindowSummary())); raise \(raised ? "ok" : "failed")")
            guard await FilePanelAutomation.pause(ms: 250) else { return .error("Cancelled") }
        }
        guard await FilePanelAutomation.ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front. Nothing was done. Trace: \(trace.joined(separator: "; "))")
        }
        let tracksBefore = AXLogicProElements.trackHeaderCount()
        for name in candidates {
            switch AXLogicProElements.pressMenu(["Track", name]) {
            case .pressed(let title):
                trace.append("pressed Track > \(title)")
                // Some Logic versions answer with the New Tracks dialog; confirm it.
                for _ in 0..<8 {
                    guard await FilePanelAutomation.pause(ms: 100) else { return .error("Cancelled") }
                    if AXLogicProElements.pressNewTracksCreate() {
                        trace.append("confirmed the New Tracks dialog")
                        break
                    }
                }
                var tracksAfter = AXLogicProElements.trackHeaderCount()
                var waited = 0
                while tracksAfter <= tracksBefore && waited < 3_000 {
                    guard await FilePanelAutomation.pause(ms: 200) else { return .error("Cancelled") }
                    waited += 200
                    tracksAfter = AXLogicProElements.trackHeaderCount()
                }
                if tracksAfter == tracksBefore + 1 {
                    return .success("Created a track with Track > \(title) (verified: track headers \(tracksBefore) -> \(tracksAfter)). Trace: \(trace.joined(separator: "; "))")
                }
                return .error("Track > \(title) was pressed but the track header count went \(tracksBefore) -> \(tracksAfter) (expected +1). Trace: \(trace.joined(separator: "; "))")
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
