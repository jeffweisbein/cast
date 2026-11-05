// Cast — mirrored from OpenClawKit (MIT, © 2025 Peter Steinberger). See ATTRIBUTION.md.
import Foundation

/// Minimal type-erased Codable used for gateway frame payloads.
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any?

    public init(_ value: Any?) {
        if let any = value as? AnyCodable {
            self.value = any.value
        } else {
            self.value = value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = nil
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self.value {
        case nil:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [AnyCodable]:
            try container.encode(array)
        case let array as [Any?]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: AnyCodable]:
            try container.encode(dict)
        case let dict as [String: Any?]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(
                self.value as Any,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "unsupported JSON value"))
        }
    }
}

extension AnyCodable: Equatable {
    /// Structural JSON equality. Transcript rows carry tool arguments as `AnyCodable`, and
    /// SwiftUI can only skip re-rendering an unchanged row when the whole row is `Equatable`.
    /// Mixed numeric representations (an `Int` beside a `Double`) compare unequal, which at
    /// worst costs one extra render rather than a missed update.
    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        Self.isEqual(lhs.value, rhs.value)
    }

    private static func isEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs as Bool, rhs as Bool):
            return lhs == rhs
        case let (lhs as Int, rhs as Int):
            return lhs == rhs
        case let (lhs as Double, rhs as Double):
            return lhs == rhs
        case let (lhs as String, rhs as String):
            return lhs == rhs
        case let (lhs as [AnyCodable], rhs as [AnyCodable]):
            return lhs == rhs
        case let (lhs as [String: AnyCodable], rhs as [String: AnyCodable]):
            return lhs == rhs
        case let (lhs as [Any?], rhs as [Any?]):
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { Self.isEqual($0, $1) }
        case let (lhs as [String: Any?], rhs as [String: Any?]):
            return lhs.count == rhs.count && lhs.allSatisfy { key, value in
                guard let other = rhs[key] else { return false }
                return Self.isEqual(value, other)
            }
        default:
            return false
        }
    }
}

public extension AnyCodable {
    var stringValue: String? { self.value as? String }
    var boolValue: Bool? { self.value as? Bool }
    var intValue: Int? {
        if let int = self.value as? Int { return int }
        // Int(exactly:) instead of Int(): a gateway number outside Int's range
        // (e.g. 1e300) must yield nil, not a runtime trap.
        if let double = self.value as? Double { return Int(exactly: double.rounded()) }
        return nil
    }

    var doubleValue: Double? {
        if let double = self.value as? Double { return double }
        if let int = self.value as? Int { return Double(int) }
        return nil
    }

    var arrayValue: [AnyCodable]? { self.value as? [AnyCodable] }
    var dictValue: [String: AnyCodable]? { self.value as? [String: AnyCodable] }

    subscript(key: String) -> AnyCodable? { self.dictValue?[key] }
}
