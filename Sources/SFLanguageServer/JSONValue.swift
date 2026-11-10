import Foundation

/// Any JSON value: the params and results of JSON-RPC messages, read and written without a schema.
package enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if let int = JSONValue.number(value).int { try container.encode(int) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The member `key` of an object; `.null` for anything else.
    package subscript(key: String) -> JSONValue {
        if case .object(let members) = self { return members[key] ?? .null }
        return .null
    }

    package var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    package var int: Int? {
        if case .number(let value) = self, value == value.rounded(), abs(value) < 9e15 { return Int(value) }
        return nil
    }

    // swiftlint:disable:next discouraged_optional_boolean
    package var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    package var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    package var isNull: Bool { self == .null }

    /// Any `Encodable` as a JSON value.
    package static func from(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// The value decoded as `type`.
    package func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    package init(stringLiteral value: String) { self = .string(value) }
    package init(integerLiteral value: Int) { self = .number(Double(value)) }
    package init(booleanLiteral value: Bool) { self = .bool(value) }
    package init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    package init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}
