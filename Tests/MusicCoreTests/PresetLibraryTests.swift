import XCTest
@testable import MusicCore

final class PresetLibraryTests: XCTestCase {
    var tmp: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("preset-tests-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    @discardableResult
    func make(_ rel: String, _ content: String = "x") throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    let metaText = """
    /*@Meta

    Author:
    'Howard Scarr'

    Description:
    'Deep sub bass'

    Usage:
    'MW = vibrato'

    Categories:
    'Bass:Sub, Bass:Analogue'

    Features:
    'Mono, Glide'

    Character:
    'Dark, Phat'

    */
    #AM=Diva
    """

    // MARK: parseMeta

    func testParseMetaFull() {
        let m = PresetLibrary.parseMeta(metaText)
        XCTAssertEqual(m.author, "Howard Scarr")
        XCTAssertEqual(m.description, "Deep sub bass")
        XCTAssertEqual(m.usage, "MW = vibrato")
        XCTAssertEqual(m.categories, ["Bass:Sub", "Bass:Analogue"])
        XCTAssertEqual(m.features, ["Mono", "Glide"])
        XCTAssertEqual(m.character, ["Dark", "Phat"])
    }

    func testParseMetaMissingBlockCRLFEmptyAndMissingKeys() {
        XCTAssertEqual(PresetLibrary.parseMeta("#AM=Diva\nfoo"), PresetMeta())
        let crlf = metaText.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(PresetLibrary.parseMeta(crlf), PresetLibrary.parseMeta(metaText))
        let partial = "/*@Meta\n\nAuthor:\n''\n\nCategories:\n'Pad'\n\n*/"
        let m = PresetLibrary.parseMeta(partial)
        XCTAssertNil(m.author)
        XCTAssertNil(m.description)
        XCTAssertEqual(m.categories, ["Pad"])
        XCTAssertEqual(m.features, [])
    }

    // MARK: scan / folderCounts

    func testScan() throws {
        try make("1 BASS/Sub One.h2p", metaText)
        try make("1 BASS/notes.txt")
        try make("2 LEAD/Zed.H2P")
        try make("THIRD PARTY/Pack/Deep.h2p")
        try make("Root.h2p")
        try make("MIDI Programs/Hidden.h2p")
        try make("midi programs/Hidden2.h2p")
        try make(".hidden/Secret.h2p")
        try make("1 BASS/.dot.h2p")
        let found = PresetLibrary.scan(roots: [tmp, tmp.appendingPathComponent("nope")])
        XCTAssertEqual(found.map { $0.name }, ["Root", "Sub One", "Zed", "Deep"])
        XCTAssertEqual(found.map { $0.folder }, ["", "1 BASS", "2 LEAD", "THIRD PARTY/Pack"])
        XCTAssertEqual(found[1].author, "Howard Scarr")
        XCTAssertEqual(found[1].categories, ["Bass:Sub", "Bass:Analogue"])
        XCTAssertTrue(found[1].path.hasSuffix("1 BASS/Sub One.h2p"))

        let fast = PresetLibrary.scan(roots: [tmp], readMeta: false)
        XCTAssertEqual(fast.count, 4)
        XCTAssertNil(fast[1].author)
        XCTAssertEqual(fast[1].categories, [])

        let counts = PresetLibrary.folderCounts(found)
        XCTAssertEqual(counts.map { $0.folder }, ["", "1 BASS", "2 LEAD", "THIRD PARTY/Pack"])
        XCTAssertEqual(counts.map { $0.count }, [1, 1, 1, 1])
    }

    func testScanLatin1Meta() throws {
        let url = tmp.appendingPathComponent("L.h2p")
        var data = Data("/*@Meta\n\nAuthor:\n'Ren".utf8)
        data.append(0xE9)
        data.append(Data("'\n\n*/".utf8))
        try data.write(to: url)
        let p = PresetLibrary.scan(roots: [tmp])
        XCTAssertEqual(p.first?.author, "Ren\u{e9}")
    }

    // MARK: search

    func testSearch() {
        let a = SynthPreset(name: "Deep Sub", path: "/a", folder: "1 BASS", author: "Howard", categories: ["Bass:Sub"], character: ["Dark"])
        let b = SynthPreset(name: "Lead X", path: "/b", folder: "2 LEAD", author: "Deep Dave", categories: ["Lead"], features: ["Mono"])
        let c = SynthPreset(name: "Pad", path: "/c", folder: "3 PAD", description: "deep warm sub pad", categories: ["Pad"])
        let all = [a, b, c]
        XCTAssertEqual(PresetLibrary.search(all).count, 3)
        XCTAssertEqual(PresetLibrary.search(all, query: "deep").map { $0.name }, ["Deep Sub", "Lead X", "Pad"].filter { ["Deep Sub", "Lead X", "Pad"].contains($0) })
        // name-first ranking
        XCTAssertEqual(PresetLibrary.search([b, a], query: "deep").map { $0.name }, ["Deep Sub", "Lead X"])
        // AND across terms and fields
        XCTAssertEqual(PresetLibrary.search(all, query: "deep dark").map { $0.name }, ["Deep Sub"])
        XCTAssertEqual(PresetLibrary.search(all, query: "deep warm").map { $0.name }, ["Pad"])
        XCTAssertEqual(PresetLibrary.search(all, folder: "lead").map { $0.name }, ["Lead X"])
        XCTAssertEqual(PresetLibrary.search(all, category: "bass").map { $0.name }, ["Deep Sub"])
        XCTAssertEqual(PresetLibrary.search(all, query: "mono").map { $0.name }, ["Lead X"])
        XCTAssertEqual(PresetLibrary.search(all, query: "  ", limit: 2).count, 2)
        XCTAssertEqual(PresetLibrary.search(all, query: "zzz").count, 0)
    }

    // MARK: resolve

    func testResolve() {
        let a = SynthPreset(name: "Deep Sub", path: "/r/1 BASS/Deep Sub.h2p", folder: "1 BASS")
        let b = SynthPreset(name: "Deep Lead", path: "/r/2 LEAD/Deep Lead.h2p", folder: "2 LEAD")
        let c = SynthPreset(name: "Pad", path: "/r/1 BASS/Pad.h2p", folder: "1 BASS")
        let d = SynthPreset(name: "Pad", path: "/r/3 PAD/Pad.h2p", folder: "3 PAD")
        let all = [a, b, c, d]
        XCTAssertEqual(try? PresetLibrary.resolve("/r/2 LEAD/Deep Lead.h2p", in: all).get(), b)
        XCTAssertEqual(try? PresetLibrary.resolve("deep sub", in: all).get(), a)
        XCTAssertEqual(try? PresetLibrary.resolve("3 pad/pad", in: all).get(), d)
        XCTAssertEqual(try? PresetLibrary.resolve("lead", in: all).get(), b)
        if case .failure(let e) = PresetLibrary.resolve("deep", in: all) {
            XCTAssertTrue(e.description.contains("ambiguous"))
        } else { XCTFail("expected ambiguity") }
        if case .failure(let e) = PresetLibrary.resolve("pad", in: all) {
            XCTAssertTrue(e.description.contains("ambiguous"))
        } else { XCTFail("expected ambiguity") }
        if case .failure(let e) = PresetLibrary.resolve("nothing", in: all) {
            XCTAssertTrue(e.description.contains("no preset matches"))
        } else { XCTFail("expected none") }
    }

    // MARK: names / order

    func testBankNames() {
        XCTAssertEqual(PresetLibrary.bankFileName(index: 3, name: "HS Stabz"), "003 HS Stabz.h2p")
        XCTAssertEqual(PresetLibrary.bankFileName(index: 12, name: "007 A/B:C "), "012 A-B-C.h2p")
        XCTAssertEqual(PresetLibrary.bankFileName(index: 0, name: "  "), "000 preset.h2p")
        XCTAssertEqual(PresetLibrary.displayName(fromBankFileName: "003 HS Stabz.h2p"), "HS Stabz")
        XCTAssertEqual(PresetLibrary.displayName(fromBankFileName: "HS Stabz.h2p"), "HS Stabz")
        XCTAssertEqual(PresetLibrary.displayName(fromBankFileName: "12 x.h2p"), "12 x")
        XCTAssertTrue(PresetLibrary.bankOrder("002 y.h2p", "010 x.h2p"))
        XCTAssertFalse(PresetLibrary.bankOrder("010 x.h2p", "002 y.h2p"))
        XCTAssertTrue(PresetLibrary.bankOrder("a.h2p", "B.h2p"))
        XCTAssertTrue(PresetLibrary.bankOrder("A.h2p", "a.h2p"))
    }

    func testReadBank() throws {
        let bank = tmp.appendingPathComponent("bank")
        XCTAssertEqual(PresetLibrary.readBank(folder: bank), [])
        try make("bank/010 x.h2p")
        try make("bank/002 y.h2p")
        try make("bank/.hid.h2p")
        try make("bank/readme.txt")
        let e = PresetLibrary.readBank(folder: bank)
        XCTAssertEqual(e.map { $0.fileName }, ["002 y.h2p", "010 x.h2p"])
        XCTAssertEqual(e.map { $0.program }, [0, 1])
        XCTAssertEqual(e.map { $0.name }, ["y", "x"])
        for i in 0..<130 { try make("big/\(String(format: "%03d", i)) p.h2p") }
        XCTAssertEqual(PresetLibrary.readBank(folder: tmp.appendingPathComponent("big")).count, 128)
    }

    // MARK: installBank

    func presets(_ names: [String], content: String = "data") throws -> [SynthPreset] {
        try names.map { n in
            let u = try make("src/\(n).h2p", content + n)
            return SynthPreset(name: n, path: u.path, folder: "src")
        }
    }

    func testInstallReplace() throws {
        let bank = tmp.appendingPathComponent("bank")
        let manifest = tmp.appendingPathComponent("meta/" + PresetLibrary.manifestFileName)
        let r1 = try PresetLibrary.installBank(presets: presets(["A", "B"]), bankFolder: bank, manifestURL: manifest)
        XCTAssertEqual(r1.copied, ["000 A.h2p", "001 B.h2p"])
        XCTAssertEqual(r1.entries.map { $0.name }, ["A", "B"])
        XCTAssertEqual(r1.removed, [])
        let mdata = try Data(contentsOf: manifest)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: mdata), ["000 A.h2p", "001 B.h2p"])

        try make("bank/zz foreign.h2p")
        let r2 = try PresetLibrary.installBank(presets: presets(["C"]), bankFolder: bank, manifestURL: manifest)
        XCTAssertEqual(Set(r2.removed), ["000 A.h2p", "001 B.h2p"])
        XCTAssertEqual(r2.copied, ["000 C.h2p"])
        XCTAssertEqual(r2.foreignFiles, ["zz foreign.h2p"])
        XCTAssertEqual(r2.entries.map { $0.fileName }, ["000 C.h2p", "zz foreign.h2p"])
        XCTAssertTrue(r2.warnings.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: bank.appendingPathComponent("zz foreign.h2p").path))
    }

    func testInstallAppendAndSkipIdentical() throws {
        let bank = tmp.appendingPathComponent("bank")
        let manifest = tmp.appendingPathComponent("m.json")
        _ = try PresetLibrary.installBank(presets: presets(["A", "B"]), bankFolder: bank, manifestURL: manifest)
        let again = try presets(["A", "C"])
        let r = try PresetLibrary.installBank(presets: again, bankFolder: bank, manifestURL: manifest, mode: .append)
        XCTAssertEqual(r.copied, ["002 C.h2p"])
        XCTAssertEqual(r.entries.map { $0.fileName }, ["000 A.h2p", "001 B.h2p", "002 C.h2p"])
        XCTAssertTrue(r.warnings.contains { $0.contains("already installed") })
        let m = try JSONDecoder().decode([String].self, from: Data(contentsOf: manifest))
        XCTAssertEqual(m.count, 3)
    }

    func testInstallValidationLeavesFolderUntouched() throws {
        let bank = tmp.appendingPathComponent("bank")
        let manifest = tmp.appendingPathComponent("m.json")
        _ = try PresetLibrary.installBank(presets: presets(["A"]), bankFolder: bank, manifestURL: manifest)
        let before = PresetLibrary.readBank(folder: bank)
        let manifestBefore = try Data(contentsOf: manifest)

        let a = try presets(["A"])
        XCTAssertThrowsError(try PresetLibrary.installBank(presets: a + a, bankFolder: bank, manifestURL: manifest)) {
            XCTAssertEqual($0 as? PresetLibraryError, .duplicatePreset(a[0].path))
        }
        let missing = SynthPreset(name: "Nope", path: tmp.appendingPathComponent("src/Nope.h2p").path)
        XCTAssertThrowsError(try PresetLibrary.installBank(presets: [missing], bankFolder: bank, manifestURL: manifest)) {
            XCTAssertEqual($0 as? PresetLibraryError, .notAPreset(missing.path))
        }
        let txt = try make("src/x.txt")
        XCTAssertThrowsError(try PresetLibrary.installBank(presets: [SynthPreset(name: "x", path: txt.path)], bankFolder: bank, manifestURL: manifest)) {
            XCTAssertEqual($0 as? PresetLibraryError, .notAPreset(txt.path))
        }
        let many = try presets((0..<129).map { "P\($0)" })
        XCTAssertThrowsError(try PresetLibrary.installBank(presets: many, bankFolder: bank, manifestURL: manifest)) {
            XCTAssertEqual($0 as? PresetLibraryError, .tooManyPresets(129))
        }
        // append overflow: 1 owned + 128 new
        XCTAssertThrowsError(try PresetLibrary.installBank(presets: Array(many.prefix(128)), bankFolder: bank, manifestURL: manifest, mode: .append)) {
            XCTAssertEqual($0 as? PresetLibraryError, .tooManyPresets(129))
        }
        XCTAssertEqual(PresetLibrary.readBank(folder: bank), before)
        XCTAssertEqual(try Data(contentsOf: manifest), manifestBefore)
    }

    func testForeignSortingBeforeWarning() throws {
        let bank = tmp.appendingPathComponent("bank")
        try make("bank/000 0 foreign.h2p")
        let r = try PresetLibrary.installBank(presets: presets(["A"]), bankFolder: bank, manifestURL: tmp.appendingPathComponent("m.json"))
        // Same name would collide only if identical; here "001"? index 0 -> "000 A.h2p" differs from foreign.
        XCTAssertEqual(r.foreignFiles, ["000 0 foreign.h2p"])
        XCTAssertTrue(r.warnings.contains { $0.contains("program numbers") })
    }

    func testProgramLookup() {
        let bank = [
            BankEntry(program: 0, fileName: "000 HS Stabz.h2p", name: "HS Stabz"),
            BankEntry(program: 1, fileName: "001 MK Bass Sub Tri.h2p", name: "MK Bass Sub Tri"),
            BankEntry(program: 2, fileName: "002 IW Lush PWM Pad.h2p", name: "IW Lush PWM Pad"),
        ]
        XCTAssertEqual(PresetLibrary.program(for: "1", in: bank)?.program, 1)
        XCTAssertNil(PresetLibrary.program(for: "99", in: bank))
        XCTAssertEqual(PresetLibrary.program(for: "hs stabz", in: bank)?.program, 0)
        XCTAssertEqual(PresetLibrary.program(for: "lush", in: bank)?.program, 2)
        XCTAssertNil(PresetLibrary.program(for: "s", in: bank))
        XCTAssertNil(PresetLibrary.program(for: "zzz", in: bank))
    }
}
