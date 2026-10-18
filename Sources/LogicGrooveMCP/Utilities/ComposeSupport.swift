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
}
