import Foundation

/// A plug-in in the Inspector channel strip (instrument or effect), read through Accessibility.
struct StripPlugin: Sendable, Codable, Equatable {
    let name: String
    let bypassed: Bool
    /// Global screen y of the slot group (smaller = higher on screen).
    let y: Double
}

/// The Stereo Out strip next to the selected track in the Inspector.
struct StripMaster: Sendable, Codable, Equatable {
    let volumeText: String?
    let peakText: String?
    let peakValue: String?
    let clipping: Bool
}

/// Sendable snapshot of the selected track's channel strip. Pure data: no AX elements.
struct StripModel: Sendable, Codable, Equatable {
    var trackName: String
    var volumeRaw: Double?
    /// Level text such as "0,0 dB" (decimal comma as Logic prints it), "-∞ dB" possible.
    var volumeText: String?
    var peakText: String?
    /// Raw value of the peak meter ("signal clipping off", "mixed", ...).
    var peakValue: String?
    var clipping: Bool
    var pan: Double?
    var instrument: StripPlugin?
    var effects: [StripPlugin]
    var hasMidiPluginButton: Bool
    var hasEmptyInstrumentSlot: Bool
    var hasEmptyEffectSlot: Bool
    var master: StripMaster?

    /// All plug-ins top to bottom: instrument first (when there is one), then the effects.
    var plugins: [StripPlugin] { (instrument.map { [$0] } ?? []) + effects }

    /// "Diva | Tape Delay, Compressor, ChromaVerb" (instrument | effects, "-" when empty).
    var chainText: String {
        let first = instrument?.name ?? "-"
        let rest = effects.isEmpty ? "-" : effects.map { $0.name }.joined(separator: ", ")
        return "\(first) | \(rest)"
    }

    /// Compact single-line JSON (snake_case keys), for error messages.
    func compactJSON() -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

/// Response of `logic_mixer strip`.
struct StripResponse: Codable, Sendable {
    let chain: String
    let trace: [String]
    let strip: StripModel

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{\"error\": \"Failed to encode response\"}"
        }
        return text
    }
}

/// Which slot an insert_plugin call addresses.
enum PluginSlotRequest: Sendable, Equatable {
    case instrument
    /// Add an effect in the empty slot under the last effect.
    case newEffect
    /// Replace the n-th existing effect (1-based, top to bottom).
    case effect(Int)

    /// nil or empty text -> newEffect (the default). "0" / "instrument" -> instrument,
    /// "new" / "add" / "append" -> newEffect, an integer n >= 1 -> effect(n). Anything else -> nil.
    static func parse(_ text: String?) -> PluginSlotRequest? {
        let raw = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.isEmpty { return .newEffect }
        switch raw {
        case "instrument", "0": return .instrument
        case "new", "add", "append": return .newEffect
        default:
            if let n = Int(raw), n >= 1 { return .effect(n) }
            return nil
        }
    }
}

/// Which plug-in a bypass call addresses.
enum PluginTarget: Sendable, Equatable {
    case instrument
    /// 1-based effect number, top to bottom.
    case effect(Int)
    /// Name substring (case-insensitive, either direction).
    case named(String)
}
