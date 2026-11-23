import Foundation

// u-he style preset (*.h2p) library: scanning, searching, and installing presets into the
// synth's "MIDI Programs" folder so they can be selected by MIDI Program Change.
// Foundation only (Linux-testable).

public struct SynthPreset: Codable, Sendable, Equatable {
    public var name: String
    public var path: String
    public var folder: String
    public var author: String?
    public var description: String?
    public var usage: String?
    public var categories: [String]
    public var features: [String]
    public var character: [String]

    public init(name: String, path: String, folder: String = "", author: String? = nil,
                description: String? = nil, usage: String? = nil, categories: [String] = [],
                features: [String] = [], character: [String] = []) {
        self.name = name
        self.path = path
        self.folder = folder
        self.author = author
        self.description = description
        self.usage = usage
        self.categories = categories
        self.features = features
        self.character = character
    }
}

public struct PresetMeta: Sendable, Equatable {
    public var author: String?
    public var description: String?
    public var usage: String?
    public var categories: [String]
    public var features: [String]
    public var character: [String]

    public init(author: String? = nil, description: String? = nil, usage: String? = nil,
                categories: [String] = [], features: [String] = [], character: [String] = []) {
        self.author = author
        self.description = description
        self.usage = usage
        self.categories = categories
        self.features = features
        self.character = character
    }
}

public struct BankEntry: Codable, Sendable, Equatable {
    public var program: Int
    public var fileName: String
    public var name: String

    public init(program: Int, fileName: String, name: String) {
        self.program = program
        self.fileName = fileName
        self.name = name
    }
}

public struct BankInstallResult: Sendable, Equatable {
    public var entries: [BankEntry]
    public var copied: [String]
    public var removed: [String]
    public var foreignFiles: [String]
    public var warnings: [String]

    public init(entries: [BankEntry], copied: [String], removed: [String], foreignFiles: [String], warnings: [String]) {
        self.entries = entries
        self.copied = copied
        self.removed = removed
        self.foreignFiles = foreignFiles
        self.warnings = warnings
    }
}

public enum PresetLibraryError: Error, Sendable, Equatable, CustomStringConvertible {
    case folderMissing(String)
    case notAPreset(String)
    case tooManyPresets(Int)
    case duplicatePreset(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .folderMissing(let p): return "Folder does not exist: \(p)"
        case .notAPreset(let m): return m
        case .tooManyPresets(let n): return "Too many presets for the bank: \(n) (the synth loads at most \(PresetLibrary.bankCapacity))"
        case .duplicatePreset(let p): return "Preset listed more than once: \(p)"
        case .writeFailed(let m): return "Write failed: \(m)"
        }
    }
}

public enum PresetLibrary {
    public static let fileExtension = "h2p"
    public static let bankFolderName = "MIDI Programs"
    public static let bankCapacity = 128
    public static let manifestFileName = "logic-groove-bank.json"

    // MARK: Meta parsing

    public static func parseMeta(_ text: String) -> PresetMeta {
        var meta = PresetMeta()
        guard let startRange = text.range(of: "/*@Meta") else { return meta }
        let afterStart = text[startRange.upperBound...]
        let block: Substring
        if let endRange = afterStart.range(of: "*/") {
            block = afterStart[..<endRange.lowerBound]
        } else {
            block = afterStart
        }
        let normalized = String(block).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r \t")) }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard line.hasSuffix(":"), !line.hasPrefix("'") else { continue }
            let key = String(line.dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
            // Next non-empty line holds the quoted value.
            while i < lines.count, lines[i].isEmpty { i += 1 }
            guard i < lines.count, lines[i].hasPrefix("'") else { continue }
            var value = String(lines[i].dropFirst())
            i += 1
            while !value.hasSuffix("'"), i < lines.count {
                value += "\n" + lines[i]
                i += 1
            }
            if value.hasSuffix("'") { value.removeLast() }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let optional: String? = trimmed.isEmpty ? nil : trimmed
            func list(_ s: String) -> [String] {
                s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            switch key {
            case "author": meta.author = optional
            case "description": meta.description = optional
            case "usage": meta.usage = optional
            case "categories": meta.categories = list(trimmed)
            case "features": meta.features = list(trimmed)
            case "character": meta.character = list(trimmed)
            default: break
            }
        }
        return meta
    }

    // MARK: Scanning

    private static func readHead(_ url: URL, limit: Int = 8192) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        // Strict UTF-8 (the 8 KB cut may split a character, so allow dropping up to 3 trailing bytes).
        for drop in 0...3 where data.count > drop {
            let slice = data.prefix(data.count - drop)
            if let s = String(data: slice, encoding: .utf8), s.data(using: .utf8) == slice { return s }
        }
        // ISO Latin 1 decoded by hand (String(data:encoding:.isoLatin1) is unreliable on Linux).
        var scalars = String.UnicodeScalarView()
        for byte in data { scalars.append(Unicode.Scalar(byte)) }
        return String(scalars)
    }

    private static func hasPresetExtension(_ name: String) -> Bool {
        name.lowercased().hasSuffix("." + fileExtension)
    }

    private static func stripExtension(_ name: String) -> String {
        hasPresetExtension(name) ? String(name.dropLast(fileExtension.count + 1)) : name
    }

    public static func scan(roots: [URL], readMeta: Bool = true) -> [SynthPreset] {
        let fm = FileManager.default
        var result: [SynthPreset] = []

        func walk(_ dir: URL, relative: String, root: URL) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names.sorted() {
                if name.hasPrefix(".") { continue }
                let url = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if name.lowercased() == bankFolderName.lowercased() { continue }
                    walk(url, relative: relative.isEmpty ? name : relative + "/" + name, root: root)
                } else if hasPresetExtension(name) {
                    var preset = SynthPreset(name: stripExtension(name), path: url.path, folder: relative)
                    if readMeta, let text = readHead(url) {
                        let meta = parseMeta(text)
                        preset.author = meta.author
                        preset.description = meta.description
                        preset.usage = meta.usage
                        preset.categories = meta.categories
                        preset.features = meta.features
                        preset.character = meta.character
                    }
                    result.append(preset)
                }
            }
        }

        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
            walk(root, relative: "", root: root)
        }
        return result.sorted {
            let f0 = $0.folder.lowercased(), f1 = $1.folder.lowercased()
            if f0 != f1 { return f0 < f1 }
            let n0 = $0.name.lowercased(), n1 = $1.name.lowercased()
            if n0 != n1 { return n0 < n1 }
            return $0.path < $1.path
        }
    }

    public static func folderCounts(_ presets: [SynthPreset]) -> [(folder: String, count: Int)] {
        var counts: [String: Int] = [:]
        for p in presets { counts[p.folder, default: 0] += 1 }
        return counts.map { (folder: $0.key, count: $0.value) }.sorted {
            let a = $0.folder.lowercased(), b = $1.folder.lowercased()
            return a != b ? a < b : $0.folder < $1.folder
        }
    }

    // MARK: Search / resolve

    public static func search(_ presets: [SynthPreset], query: String? = nil, folder: String? = nil,
                              category: String? = nil, limit: Int = 0) -> [SynthPreset] {
        let terms = (query ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let folderFilter = (folder ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let categoryFilter = (category ?? "").trimmingCharacters(in: .whitespaces).lowercased()

        var nameHits: [SynthPreset] = []
        var otherHits: [SynthPreset] = []
        for p in presets {
            if !folderFilter.isEmpty, !p.folder.lowercased().contains(folderFilter) { continue }
            if !categoryFilter.isEmpty, !p.categories.contains(where: { $0.lowercased().contains(categoryFilter) }) { continue }
            let lowerName = p.name.lowercased()
            if !terms.isEmpty {
                var fields = [lowerName, p.folder.lowercased()]
                if let a = p.author { fields.append(a.lowercased()) }
                if let d = p.description { fields.append(d.lowercased()) }
                fields += p.categories.map { $0.lowercased() }
                fields += p.features.map { $0.lowercased() }
                fields += p.character.map { $0.lowercased() }
                let ok = terms.allSatisfy { t in fields.contains(where: { $0.contains(t) }) }
                if !ok { continue }
                if terms.allSatisfy({ lowerName.contains($0) }) { nameHits.append(p) } else { otherHits.append(p) }
            } else {
                nameHits.append(p)
            }
        }
        let all = nameHits + otherHits
        return limit > 0 ? Array(all.prefix(limit)) : all
    }

    public static func resolve(_ reference: String, in presets: [SynthPreset]) -> Result<SynthPreset, PresetLibraryError> {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = ref.lowercased()
        if ref.isEmpty { return .failure(.notAPreset("no preset matches an empty reference")) }

        func describe(_ list: [SynthPreset]) -> String {
            list.prefix(8).map { $0.folder.isEmpty ? $0.name : $0.folder + "/" + $0.name }.joined(separator: ", ")
        }
        func decide(_ list: [SynthPreset]) -> Result<SynthPreset, PresetLibraryError>? {
            if list.count == 1 { return .success(list[0]) }
            if list.count > 1 {
                return .failure(.notAPreset("'\(ref)' is ambiguous (\(list.count) matches): \(describe(list))"))
            }
            return nil
        }

        if let hit = presets.first(where: { $0.path == ref }) { return .success(hit) }
        if let r = decide(presets.filter { $0.name.lowercased() == lower }) { return r }
        if lower.contains("/") {
            let wanted = lower.hasPrefix("/") ? String(lower.dropFirst()) : lower
            let list = presets.filter {
                let full = ($0.folder.isEmpty ? $0.name : $0.folder + "/" + $0.name).lowercased()
                return full == wanted || full.hasSuffix("/" + wanted)
            }
            if let r = decide(list) { return r }
        }
        if let r = decide(presets.filter { $0.name.lowercased().contains(lower) }) { return r }
        return .failure(.notAPreset("no preset matches '\(ref)'"))
    }

    // MARK: Bank naming

    public static func bankOrder(_ a: String, _ b: String) -> Bool {
        let x = stripExtension(a), y = stripExtension(b)
        let lx = x.lowercased(), ly = y.lowercased()
        if lx != ly { return lx < ly }
        return x < y
    }

    public static func bankFileName(index: Int, name: String) -> String {
        var clean = name.trimmingCharacters(in: .whitespaces)
        if hasPresetExtension(clean) { clean = stripExtension(clean) }
        clean = displayName(fromBankFileName: clean)
        clean = String(clean.map { ($0 == "/" || $0 == ":") ? "-" : $0 })
        clean = clean.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { clean = "preset" }
        let n = String(max(0, index))
        let padded = String(repeating: "0", count: max(0, 3 - n.count)) + n
        return "\(padded) \(clean).\(fileExtension)"
    }

    public static func displayName(fromBankFileName fileName: String) -> String {
        let base = stripExtension(fileName)
        let chars = Array(base)
        if chars.count > 4, chars[0...2].allSatisfy({ $0 >= "0" && $0 <= "9" }), chars[3] == " " {
            return String(chars[4...]).trimmingCharacters(in: .whitespaces)
        }
        return base
    }

    private static func bankIndex(of fileName: String) -> Int? {
        let chars = Array(fileName)
        if chars.count > 4, chars[0...2].allSatisfy({ $0 >= "0" && $0 <= "9" }), chars[3] == " " {
            return Int(String(chars[0...2]))
        }
        return nil
    }

    // MARK: Bank

    private static func bankFiles(in folder: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { name in
            guard !name.hasPrefix("."), hasPresetExtension(name) else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDir) && !isDir.boolValue
        }.sorted(by: bankOrder)
    }

    public static func readBank(folder: URL) -> [BankEntry] {
        bankFiles(in: folder).prefix(bankCapacity).enumerated().map { idx, file in
            BankEntry(program: idx, fileName: file, name: displayName(fromBankFileName: file))
        }
    }

    public enum BankMode: String, Sendable { case replace, append }

    public static func installBank(presets: [SynthPreset], bankFolder: URL, manifestURL: URL,
                                   mode: BankMode = .replace) throws -> BankInstallResult {
        let fm = FileManager.default

        // 1. Validate everything before touching the disk.
        var seen = Set<String>()
        for p in presets {
            let std = URL(fileURLWithPath: p.path).standardizedFileURL.path
            if !seen.insert(std).inserted { throw PresetLibraryError.duplicatePreset(p.path) }
            var isDir: ObjCBool = false
            guard hasPresetExtension(p.path), fm.fileExists(atPath: p.path, isDirectory: &isDir), !isDir.boolValue else {
                throw PresetLibraryError.notAPreset(p.path)
            }
        }
        if presets.count > bankCapacity { throw PresetLibraryError.tooManyPresets(presets.count) }

        var manifest: [String] = []
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            manifest = decoded
        }
        let existingFiles = Set(bankFiles(in: bankFolder))
        let owned = manifest.filter { existingFiles.contains($0) }

        var warnings: [String] = []
        var toRemove: [String] = []
        var keep: [String] = []
        var plan: [(source: String, fileName: String)] = []

        switch mode {
        case .replace:
            toRemove = owned
            for (i, p) in presets.enumerated() {
                plan.append((p.path, bankFileName(index: i, name: p.name)))
            }
        case .append:
            keep = owned
            var next = (owned.compactMap { bankIndex(of: $0) }.max() ?? -1) + 1
            for p in presets {
                let target = displayName(fromBankFileName: bankFileName(index: 0, name: p.name))
                if let dup = owned.first(where: { displayName(fromBankFileName: $0) == target }) {
                    let a = try? Data(contentsOf: URL(fileURLWithPath: p.path))
                    let b = try? Data(contentsOf: bankFolder.appendingPathComponent(dup))
                    if let a, let b, a == b {
                        warnings.append("'\(p.name)' is already installed as '\(dup)'; skipped")
                        continue
                    }
                }
                plan.append((p.path, bankFileName(index: next, name: p.name)))
                next += 1
            }
        }
        let finalOwned = keep + plan.map { $0.fileName }
        if finalOwned.count > bankCapacity { throw PresetLibraryError.tooManyPresets(finalOwned.count) }

        let ownedSet = Set(finalOwned)
        let removeSet = Set(toRemove)
        for item in plan where existingFiles.contains(item.fileName) && !removeSet.contains(item.fileName) {
            throw PresetLibraryError.writeFailed("\(bankFolder.appendingPathComponent(item.fileName).path): would overwrite a file this library does not own")
        }

        // 2. Apply.
        do {
            try fm.createDirectory(at: bankFolder, withIntermediateDirectories: true)
        } catch {
            throw PresetLibraryError.writeFailed("\(bankFolder.path): \(error)")
        }
        var removed: [String] = []
        for name in toRemove {
            let url = bankFolder.appendingPathComponent(name)
            do { try fm.removeItem(at: url) } catch {
                throw PresetLibraryError.writeFailed("\(url.path): \(error)")
            }
            removed.append(name)
        }
        var copied: [String] = []
        for item in plan {
            let url = bankFolder.appendingPathComponent(item.fileName)
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: item.source))
                try data.write(to: url, options: .atomic)
            } catch {
                throw PresetLibraryError.writeFailed("\(url.path): \(error)")
            }
            copied.append(item.fileName)
        }
        do {
            try fm.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(finalOwned.sorted(by: bankOrder)).write(to: manifestURL, options: .atomic)
        } catch {
            throw PresetLibraryError.writeFailed("\(manifestURL.path): \(error)")
        }

        // 3. Report.
        let allFiles = bankFiles(in: bankFolder)
        let foreign = allFiles.filter { !ownedSet.contains($0) }
        if let lastOwned = finalOwned.sorted(by: bankOrder).last,
           foreign.contains(where: { bankOrder($0, lastOwned) }) {
            warnings.append("Files not installed by this library sort before the installed presets, so program numbers do not match the NNN file indexes; use the bank listing for the real program numbers.")
        }
        if allFiles.count > bankCapacity {
            warnings.append("The bank folder holds \(allFiles.count) presets; the synth only loads the first \(bankCapacity).")
        }
        return BankInstallResult(entries: readBank(folder: bankFolder), copied: copied, removed: removed,
                                 foreignFiles: foreign, warnings: warnings)
    }

    public static func program(for reference: String, in bank: [BankEntry]) -> BankEntry? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(ref), (0...127).contains(n), let hit = bank.first(where: { $0.program == n }) { return hit }
        let lower = ref.lowercased()
        if lower.isEmpty { return nil }
        let exact = bank.filter { $0.name.lowercased() == lower }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        let subs = bank.filter { $0.name.lowercased().contains(lower) }
        return subs.count == 1 ? subs[0] : nil
    }
}
