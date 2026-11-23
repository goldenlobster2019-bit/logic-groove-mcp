import Foundation

/// Pure helpers for the compose tool and the menu/file-panel automation.
/// Foundation only (no ApplicationServices) so they are unit-testable.
enum ComposeSupport {
    // MARK: - File names and paths

    /// Keep only [A-Za-z0-9 _-]; collapse spaces to single dashes; never empty.
    static func sanitizeFileName(_ raw: String, fallback: String = "clip", maxLength: Int = 60) -> String {
        var out = ""
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            let isDigit = v >= 48 && v <= 57
            let isUpper = v >= 65 && v <= 90
            let isLower = v >= 97 && v <= 122
            if isDigit || isUpper || isLower || scalar == "_" || scalar == "-" {
                out.unicodeScalars.append(scalar)
            } else if scalar == " " {
                out.append("-")
            }
        }
        while out.contains("--") {
            out = out.replacingOccurrences(of: "--", with: "-")
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if out.count > maxLength {
            out = String(out.prefix(maxLength))
        }
        return out.isEmpty ? fallback : out
    }

    /// Validate a MIDI file path: absolute or "~"-prefixed, .mid/.midi, must exist
    /// (unless `mustExist` is false). Returns the standardized absolute path.
    static func validateMIDIPath(_ raw: String, mustExist: Bool = true) -> Validation<String> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("path is required") }
        guard trimmed.count <= 4_096 else { return .failure("path must be 4096 characters or fewer") }
        guard !trimmed.contains("\0") else { return .failure("path contains an invalid character") }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else {
            return .failure("path must be absolute or start with ~")
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .failure("path must be absolute or start with ~")
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let ext = url.pathExtension.lowercased()
        guard ext == "mid" || ext == "midi" else {
            return .failure("path must point to a .mid or .midi file")
        }
        let resolved = url.path
        if mustExist {
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return .failure("file does not exist: \(resolved)")
            }
        }
        return .success(resolved)
    }

    /// Directory for generated MIDI files (not created here).
    static func generatedDirectory() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent("Music/LogicGrooveMCP/Generated", isDirectory: true)
    }

    /// Fixed staging file for imports: ~/Music/LogicGrooveMCP/Import/clip.mid (not created here).
    /// The Go to sheet remembers the last path, so a fixed path normally already matches.
    static func importStagingURL() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent("Music/LogicGrooveMCP/Import/clip.mid", isDirectory: false)
    }

    /// True when two paths are the same after trimming whitespace, expanding a leading "~"
    /// and standardizing ("." / ".." / duplicate slashes). Empty strings never match.
    static func pathsEqual(_ a: String, _ b: String) -> Bool {
        func normalize(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let expanded = (trimmed as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        guard let left = normalize(a), let right = normalize(b) else { return false }
        return left == right
    }

    /// Folder for the sound bank manifests: ~/Music/LogicGrooveMCP (not created here).
    static func soundsDirectory() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent("Music/LogicGrooveMCP", isDirectory: true)
    }

    /// Manifest of the installed MIDI Programs bank of a synth: ~/Music/LogicGrooveMCP/<plugin>-bank.json.
    static func soundBankManifestURL(plugin: String) -> URL {
        soundsDirectory().appendingPathComponent("\(plugin)-bank.json", isDirectory: false)
    }

    /// System-wide ("local") u-he preset root of a plug-in: /Library/Audio/Presets/u-he/<plugin>.
    static func uheLocalRoot(plugin: String) -> URL {
        URL(fileURLWithPath: "/Library/Audio/Presets/u-he", isDirectory: true)
            .appendingPathComponent(plugin, isDirectory: true)
    }

    /// Per-user u-he preset root of a plug-in: ~/Library/Audio/Presets/u-he/<plugin>.
    static func uheUserRoot(plugin: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Audio/Presets/u-he", isDirectory: true)
            .appendingPathComponent(plugin, isDirectory: true)
    }

    /// The synth's MIDI Programs folder (inside the local root).
    static func uheBankFolder(plugin: String) -> URL {
        uheLocalRoot(plugin: plugin).appendingPathComponent("MIDI Programs", isDirectory: true)
    }

    /// A plug-in name that is safe to use as a folder name: letters, digits, space, dash, underscore,
    /// 1-40 characters. Returns the trimmed name.
    static func validatePluginFolderName(_ raw: String) -> Validation<String> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("plugin must not be empty") }
        guard trimmed.count <= 40 else { return .failure("plugin must be 40 characters or fewer") }
        for scalar in trimmed.unicodeScalars {
            let v = scalar.value
            let isDigit = v >= 48 && v <= 57
            let isUpper = v >= 65 && v <= 90
            let isLower = v >= 97 && v <= 122
            if isDigit || isUpper || isLower || scalar == " " || scalar == "-" || scalar == "_" { continue }
            return .failure("plugin may only contain letters, digits, space, dash and underscore")
        }
        return .success(trimmed)
    }

    /// A preset reference (name, "folder/name" or absolute path) that is safe to hand to the library:
    /// 1-512 characters, no "..", no NUL, no control characters.
    static func isSafePresetReference(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return false }
        guard !trimmed.contains("..") else { return false }
        for scalar in trimmed.unicodeScalars where scalar.value < 32 || scalar.value == 127 {
            return false
        }
        return true
    }

    /// True when `path` lies inside one of the `roots` (after standardizing both).
    static func path(_ path: String, isInside roots: [URL]) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            if standardized == rootPath || standardized.hasPrefix(rootPath + "/") { return true }
        }
        return false
    }

    /// Level text the way Logic prints it, in the style of `sample` (decimal comma when the sample
    /// uses one): (-6.0, "0,0 dB") -> "-6,0 dB"; (-6.0, "0.0 dB") -> "-6.0 dB".
    static func formatDecibels(_ value: Double, like sample: String) -> String {
        var text = String(format: "%.1f", value)
        if sample.contains(",") { text = text.replacingOccurrences(of: ".", with: ",") }
        return "\(text) dB"
    }

    /// Directory for MIDI exported from Logic regions (not created here).
    static func exportsDirectory() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent("Music/LogicGrooveMCP/Exports", isDirectory: true)
    }

    /// "yyyyMMdd-HHmmss" in the local time zone.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: - Positions

    /// Bar.beat.sixteenth (all 1-based) for a tick position, assuming 4/4 at 480 PPQ.
    /// tick 0 -> "1.1.1", tick 240 -> "1.1.3". Rounds to the NEAREST 16th, so a humanized
    /// note a few ticks early (e.g. 236) still reads as "1.1.3", not "1.1.2".
    static func positionString(tick: Int, ppq: Int = 480, beatsPerBar: Int = 4) -> String {
        let ticksPerBeat = max(1, ppq)
        let ticksPerSixteenth = max(1, ppq / 4)
        let safeTick = max(0, ((tick + ticksPerSixteenth / 2) / ticksPerSixteenth) * ticksPerSixteenth)
        let ticksPerBar = ticksPerBeat * max(1, beatsPerBar)
        let bar = safeTick / ticksPerBar + 1
        let beat = (safeTick % ticksPerBar) / ticksPerBeat + 1
        let sixteenth = (safeTick % ticksPerBeat) / ticksPerSixteenth + 1
        return "\(bar).\(beat).\(sixteenth)"
    }

    /// Position of a 16th-step index (0...15) inside bar 1: step 2 -> "1.1.3".
    static func positionString(step16: Int, bar: Int = 1) -> String {
        let step = max(0, step16)
        return "\(bar + step / 16).\((step % 16) / 4 + 1).\(step % 4 + 1)"
    }

    // MARK: - Menu titles

    /// Lowercase, trim, unify curly apostrophes and the ellipsis character,
    /// and drop a trailing "..." so "MIDI File…" equals "midi file...".
    static func normalizeMenuTitle(_ title: String) -> String {
        var s = title.lowercased()
        s = s.replacingOccurrences(of: "\u{2026}", with: "...")
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("...") {
            s = String(s.dropLast(3))
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// True when `title` matches `wanted` after normalization (exact match).
    static func menuTitleEquals(_ title: String, _ wanted: String) -> Bool {
        normalizeMenuTitle(title) == normalizeMenuTitle(wanted)
    }

    /// True when `title` starts with `wanted` after normalization.
    static func menuTitleHasPrefix(_ title: String, _ wanted: String) -> Bool {
        normalizeMenuTitle(title).hasPrefix(normalizeMenuTitle(wanted))
    }

    // MARK: - Levels and plug-in names

    /// Parse a Logic level text into dB: "0,0 dB" -> 0, "-7,9 dB" -> -7.9, "3.9 dB" -> 3.9,
    /// "-\u{221E} dB" -> -infinity. nil when the text is not a level.
    static func parseDecibels(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "\u{2212}", with: "-")
        if s.hasSuffix("db") {
            s = String(s.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        s = s.replacingOccurrences(of: " ", with: "")
        if s.contains("\u{221E}") || s == "-inf" || s == "inf" || s == "-infinity" {
            return -Double.infinity
        }
        s = s.replacingOccurrences(of: ",", with: ".")
        if s.hasPrefix("+") { s.removeFirst() }
        return Double(s)
    }

    /// The text after the first ", " of an AX title: "volume fader level, 0,0 dB" -> "0,0 dB".
    /// nil when there is no comma or nothing follows it ("peak level meter" -> nil).
    static func textAfterFirstComma(_ title: String) -> String? {
        guard let range = title.range(of: ", ") else { return nil }
        let rest = title[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// Case-insensitive substring match in either direction ("Tape Delay" vs "tape").
    static func pluginNameMatches(_ actual: String, _ wanted: String) -> Bool {
        let a = actual.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let w = wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !a.isEmpty, !w.isEmpty else { return false }
        return a.contains(w) || w.contains(a)
    }

    /// Newest modification date among a folder and its non-hidden direct entries (nil when the folder
    /// does not exist). Used to tell whether a MIDI Programs bank changed after Logic was launched.
    static func newestModificationDate(in folder: URL) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        var newest: Date? = (try? folder.resourceValues(forKeys: keys))?.contentModificationDate
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        for url in urls {
            guard let date = (try? url.resourceValues(forKeys: keys))?.contentModificationDate else { continue }
            if let current = newest, current >= date { continue }
            newest = date
        }
        return newest
    }

    /// Number of non-hidden entries directly inside a folder (0 when it cannot be read).
    static func nonHiddenEntryCount(in directory: URL) -> Int {
        let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return urls?.count ?? 0
    }
}
