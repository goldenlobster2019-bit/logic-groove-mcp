import ApplicationServices
import Foundation

/// `logic_project bounce`: best-effort flow through File > Bounce > Project or Section... with a full step
/// trace (the dialog has not been inspected live yet). Success only when the audio file exists with a
/// stable size. Straight-line async code; no AX element is held across an `await`.
extension AccessibilityChannel {
    private static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "caf"]

    /// The newest audio file in `directory` whose name starts with `prefix`, modified since `date`.
    private static func newestAudioFile(in directory: URL, prefix: String, since date: Date) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return nil
        }
        var best: (url: URL, date: Date)?
        for url in urls {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard url.lastPathComponent.hasPrefix(prefix) else { continue }
            guard let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  modified >= date.addingTimeInterval(-1) else { continue }
            if let current = best, current.date >= modified { continue }
            best = (url, modified)
        }
        return best?.url
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    func bounceProject(params: [String: String]) async -> ChannelResult {
        guard case .success(let path) = ComposeSupport.validateBouncePath(params["path"]) else {
            return .error("Invalid bounce path")
        }
        let targetURL = URL(fileURLWithPath: path)
        let directory = targetURL.deletingLastPathComponent()
        let baseName = targetURL.deletingPathExtension().lastPathComponent
        var trace: [String] = []
        func traceText() -> String { trace.joined(separator: "; ") }
        func bail(_ reason: String) -> ChannelResult {
            if AXLogicProElements.cancelBounceWindow() { trace.append("cancelled the Bounce dialog") }
            if AXLogicProElements.strictFilePanel() != nil, AXLogicProElements.cancelFilePanel() {
                trace.append("cancelled the save panel")
            }
            return .error("Bounce failed: \(reason). Trace: \(traceText())")
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .error("Cannot create \(directory.path): \(error.localizedDescription)")
        }
        if params["start_bar"] != nil || params["end_bar"] != nil {
            trace.append("start_bar / end_bar were NOT applied (the range fields are not driven in this version); the dialog's own range is used")
        }
        if AXLogicProElements.dismissDownloadPrompt() != nil { trace.append(AXLogicProElements.downloadPromptTraceText) }
        if let existing = AXLogicProElements.strictFilePanel() {
            return .error("A file panel is already open (\(AXLogicProElements.panelSummary(of: existing))); close it and retry. Nothing was done.")
        }
        guard await FilePanelAutomation.ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front. Nothing was done.")
        }
        let startedAt = Date()

        // 1. Open the dialog.
        switch AXLogicProElements.pressMenu(["File", "Bounce", "Project or Section"]) {
        case .pressed(let title):
            trace.append("menu pressed: File > Bounce > \(title)")
        case .notFound:
            let entries = AXLogicProElements.menuEntryTitles(path: ["File", "Bounce"])
            return .error("Menu item File > Bounce > Project or Section... not found. File > Bounce entries: \(entries.joined(separator: ", "))")
        case .disabled(let title):
            return .error("Menu item '\(title)' is disabled. Is a project open and is there something to bounce?")
        case .failed(let title):
            return .error("Failed to press menu item '\(title)'")
        }

        // 2. Wait for the dialog and record its controls.
        var waited = 0
        while waited < 3_000 && AXLogicProElements.bounceWindow() == nil {
            guard await FilePanelAutomation.pause(ms: 100) else { return .error("Cancelled") }
            waited += 100
        }
        guard AXLogicProElements.bounceWindow() != nil else {
            let titles = AXLogicProElements.windowTitles().map { "'\($0)'" }.joined(separator: ", ")
            return bail("no window titled 'Bounce...' within 3 seconds (windows: \(titles))")
        }
        trace.append("Bounce dialog up after \(waited) ms")
        for line in AXLogicProElements.bounceControlSummary(limit: 40) { trace.append("  control: \(line)") }

        // 3. Offline, then confirm.
        if let offline = AXLogicProElements.bounceSelectOffline() {
            trace.append(offline)
        } else {
            trace.append("no control titled 'Offline' found")
        }
        guard let confirmed = AXLogicProElements.pressBounceConfirm(titles: ["Bounce", "OK"]) else {
            return bail("no 'Bounce' / 'OK' button could be pressed in the dialog")
        }
        trace.append("pressed '\(confirmed)'")

        // 4. The save panel.
        guard await FilePanelAutomation.waitForPanel(timeoutMs: 3_000) else {
            // Some setups bounce straight to the default folder without a panel.
            trace.append("no save panel within 3 seconds; waiting for a file anyway")
            return await waitForBounceFile(directory: directory, baseName: baseName, startedAt: startedAt, trace: trace)
        }
        trace.append("save panel up: \(AXLogicProElements.filePanelSummary() ?? "?")")
        let pid = ProcessUtils.logicProPID() ?? 0
        if let failure = await FilePanelAutomation.goTo(path: directory.path, pid: pid) {
            return bail("Go to folder failed: \(failure)")
        }
        trace.append("went to \(directory.path)")
        var nameField = false
        var fieldWait = 0
        while fieldWait <= 2_000 {
            if let field = AXLogicProElements.saveNameField() {
                let written = AXHelpers.setAttribute(field, kAXValueAttribute, baseName as CFTypeRef)
                usleep(150_000)
                let readBack = AXLogicProElements.saveNameField().flatMap { AXLogicProElements.stringValue(of: $0) } ?? ""
                trace.append("name field set (\(written ? "ok" : "failed")), reads '\(readBack)'")
                nameField = written && readBack.lowercased().hasPrefix(baseName.lowercased())
                break
            }
            guard await FilePanelAutomation.pause(ms: 100) else { return .error("Cancelled") }
            fieldWait += 100
        }
        guard nameField else {
            return bail("the file name field could not be set and read back")
        }
        guard let saved = FilePanelAutomation.confirmPanel(buttonTitles: ["Save", "Bounce"]) else {
            return bail("could not press the Save button of the panel")
        }
        trace.append("pressed '\(saved)'")
        if let replaced = await FilePanelAutomation.handleReplaceAlert() {
            trace.append("pressed '\(replaced)' on the overwrite alert")
        }
        return await waitForBounceFile(directory: directory, baseName: baseName, startedAt: startedAt, trace: trace)
    }

    /// Wait up to 120 s for the bounced file (name starting with `baseName`) and for its size to stay the
    /// same for 1 s.
    private func waitForBounceFile(directory: URL, baseName: String, startedAt: Date, trace: [String]) async -> ChannelResult {
        var trace = trace
        var waited = 0
        var lastSize: Int64 = -1
        var stableSince = 0
        var found: URL?
        while waited < 120_000 {
            guard await FilePanelAutomation.pause(ms: 250) else { return .error("Cancelled") }
            waited += 250
            if let url = Self.newestAudioFile(in: directory, prefix: baseName, since: startedAt),
               let size = Self.fileSize(url), size > 0 {
                if url == found && size == lastSize {
                    if waited - stableSince >= 1_000 {
                        return .success("Bounced to \(url.path) (\(size) bytes, after \(waited / 1000) s). Trace: \(trace.joined(separator: "; "))")
                    }
                } else {
                    found = url
                    lastSize = size
                    stableSince = waited
                }
            }
        }
        trace.append("no stable audio file starting with '\(baseName)' appeared in \(directory.path) within 120 s")
        if AXLogicProElements.cancelBounceWindow() { trace.append("cancelled the Bounce dialog") }
        return .error("Bounce failed: the file did not appear. Trace: \(trace.joined(separator: "; "))")
    }
}
