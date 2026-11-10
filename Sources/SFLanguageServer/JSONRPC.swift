package import Foundation

/// The base protocol's framing: a `Content-Length: <n>` header, a blank line, then `n` bytes of JSON.
package struct MessageFramer: Sendable {
    /// A header that cannot be read: the stream is out of step and the server stops.
    package struct FramingError: Error, Equatable, CustomStringConvertible {
        package var description: String
    }

    private var buffer = Data()

    package init() {}

    /// The bytes of `body` with their header.
    package static func frame(_ body: Data) -> Data {
        Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    /// Adds `bytes` and returns every message body that is now complete, in order.
    package mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var bodies: [Data] = []
        let separator = Data("\r\n\r\n".utf8)
        while let end = buffer.range(of: separator) {
            let header = String(bytes: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) ?? ""
            let length = try Self.contentLength(header)
            let bodyStart = end.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            bodies.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer = Data(buffer[bodyEnd...])
        }
        return bodies
    }

    private static func contentLength(_ header: String) throws -> Int {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            guard let length = Int(parts[1].trimmingCharacters(in: .whitespaces)), length >= 0 else { break }
            return length
        }
        throw FramingError(description: "no valid Content-Length in header \(header.debugDescription)")
    }
}

/// A JSON-RPC 2.0 request id: a number or a string.
package enum RequestID: Hashable, Sendable, Codable, CustomStringConvertible {
    case number(Int)
    case string(String)

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        }
    }

    package var json: JSONValue {
        switch self {
        case .number(let n): .number(Double(n))
        case .string(let s): .string(s)
        }
    }

    package var description: String {
        switch self {
        case .number(let n): "\(n)"
        case .string(let s): s
        }
    }
}

/// One JSON-RPC 2.0 message.
package enum RPCMessage: Equatable, Sendable {
    case request(id: RequestID, method: String, params: JSONValue)
    case notification(method: String, params: JSONValue)
    case response(id: RequestID, result: JSONValue)
    case errorResponse(id: RequestID?, code: Int, message: String)

    /// Standard error codes.
    package enum ErrorCode {
        package static let parseError = -32_700
        package static let invalidRequest = -32_600
        package static let methodNotFound = -32_601
        package static let invalidParams = -32_602
        package static let internalError = -32_603
        package static let serverNotInitialized = -32_002
        package static let requestCancelled = -32_800
    }

    /// Reads one message body.
    package init(body: Data) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: body)
        guard case .object = value else { throw MessageError.notAnObject }
        let id = try? value["id"].decode(RequestID.self)
        if let method = value["method"].string {
            if let id {
                self = .request(id: id, method: method, params: value["params"])
            } else {
                self = .notification(method: method, params: value["params"])
            }
        } else if case .object = value["error"] {
            self = .errorResponse(id: id, code: value["error"]["code"].int ?? 0, message: value["error"]["message"].string ?? "")
        } else if let id {
            self = .response(id: id, result: value["result"])
        } else {
            throw MessageError.notAMessage
        }
    }

    package enum MessageError: Error { case notAnObject, notAMessage }

    /// The message as JSON.
    package var json: JSONValue {
        switch self {
        case .request(let id, let method, let params):
            params.isNull
                ? ["jsonrpc": "2.0", "id": id.json, "method": .string(method)]
                : ["jsonrpc": "2.0", "id": id.json, "method": .string(method), "params": params]
        case .notification(let method, let params):
            params.isNull
                ? ["jsonrpc": "2.0", "method": .string(method)] : ["jsonrpc": "2.0", "method": .string(method), "params": params]
        case .response(let id, let result):
            ["jsonrpc": "2.0", "id": id.json, "result": result]
        case .errorResponse(let id, let code, let message):
            ["jsonrpc": "2.0", "id": id?.json ?? .null, "error": ["code": .number(Double(code)), "message": .string(message)]]
        }
    }

    /// The body to frame.
    package func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(json)) ?? Data("{}".utf8)
    }
}
