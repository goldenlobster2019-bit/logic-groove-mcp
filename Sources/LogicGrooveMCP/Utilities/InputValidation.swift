import Foundation
import MCP

enum Validation<Success> {
    case success(Success)
    case failure(String)
}

enum InputValidation {
    /// A JSON number as Double: accepts .double, .int and numeric strings (an integer such as -6 is
    /// delivered as .int, which `doubleValue` alone does not convert).
    static func looseDouble(_ value: Value?) -> Double? {
        guard let value else { return nil }
        if let number = value.doubleValue { return number }
        if let number = value.intValue { return Double(number) }
        if let text = value.stringValue { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// A JSON number as Int: accepts .int, whole .double values and integer strings.
    static func looseInt(_ value: Value?) -> Int? {
        guard let value else { return nil }
        if let number = value.intValue { return number }
        if let number = value.doubleValue, number.isFinite, number == number.rounded(), abs(number) < 1e15 {
            return Int(number)
        }
        if let text = value.stringValue { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func int(
        _ params: [String: Value],
        keys: [String],
        default defaultValue: Int? = nil,
        range: ClosedRange<Int>,
        label: String
    ) -> Validation<Int> {
        for key in keys {
            guard let supplied = params[key] else { continue }
            guard let value = supplied.intValue ?? supplied.stringValue.flatMap(Int.init) else {
                return .failure("\(label) must be an integer")
            }
            return range.contains(value)
                ? .success(value)
                : .failure("\(label) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        if let defaultValue {
            return .success(defaultValue)
        }
        return .failure("\(label) is required")
    }

    static func double(
        _ params: [String: Value],
        keys: [String],
        default defaultValue: Double? = nil,
        range: ClosedRange<Double>,
        label: String
    ) -> Validation<Double> {
        for key in keys {
            guard let supplied = params[key] else { continue }
            guard let value = supplied.doubleValue ?? supplied.intValue.map(Double.init)
                ?? supplied.stringValue.flatMap(Double.init) else {
                return .failure("\(label) must be a number")
            }
            return value.isFinite && range.contains(value)
                ? .success(value)
                : .failure("\(label) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        if let defaultValue {
            return .success(defaultValue)
        }
        return .failure("\(label) is required")
    }

    static func string(
        _ params: [String: Value],
        keys: [String],
        default defaultValue: String? = nil,
        maxLength: Int,
        label: String
    ) -> Validation<String> {
        for key in keys {
            guard let supplied = params[key] else { continue }
            guard let value = supplied.stringValue else {
                return .failure("\(label) must be a string")
            }
            guard !value.isEmpty else { return .failure("\(label) must not be empty") }
            guard value.count <= maxLength else {
                return .failure("\(label) must be \(maxLength) characters or fewer")
            }
            return .success(value)
        }
        if let defaultValue { return .success(defaultValue) }
        return .failure("\(label) is required")
    }

    static func midiChannel(_ params: [String: Value]) -> Validation<Int> {
        switch int(params, keys: ["channel"], default: 1, range: 1...16, label: "channel") {
        case .success(let channel): return .success(channel - 1)
        case .failure(let message): return .failure(message)
        }
    }

    static func midiNotes(_ params: [String: Value]) -> Validation<String> {
        let notes: [Int]
        if let values = params["notes"]?.arrayValue {
            let parsed = values.compactMap(\.intValue)
            guard parsed.count == values.count else {
                return .failure("notes must contain only MIDI note numbers")
            }
            notes = parsed
        } else if let value = params["notes"]?.stringValue {
            let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
            let parsed = tokens.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parsed.count == tokens.count else {
                return .failure("notes must contain only MIDI note numbers")
            }
            notes = parsed
        } else {
            return .failure("notes is required")
        }
        guard !notes.isEmpty, notes.count <= 128, notes.allSatisfy((0...127).contains) else {
            return .failure("notes must contain 1-128 values between 0 and 127")
        }
        return .success(notes.map(String.init).joined(separator: ","))
    }

    static func logicProjectPath(
        _ params: [String: Value],
        mustExist: Bool,
        label: String = "path"
    ) -> Validation<String> {
        guard let rawPath = params["path"]?.stringValue, !rawPath.isEmpty else {
            return .failure("\(label) is required")
        }
        guard rawPath.count <= 4_096 else {
            return .failure("\(label) must be 4096 characters or fewer")
        }

        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard url.pathExtension.lowercased() == "logicx" else {
            return .failure("\(label) must point to a .logicx project")
        }

        var isDirectory = ObjCBool(false)
        if mustExist {
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return .failure("\(label) does not exist: \(expanded)")
            }
        } else {
            let parent = url.deletingLastPathComponent().path
            guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return .failure("\(label) parent directory does not exist: \(parent)")
            }
        }
        return .success(expanded)
    }
}
