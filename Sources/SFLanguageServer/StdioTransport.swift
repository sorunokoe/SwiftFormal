package import Foundation
import Darwin

/// JSON-RPC over a pair of file handles (standard input and output), with `Content-Length` framing.
package final class StdioTransport: @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let lock = NSLock()

    package init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    /// Writes one message. Safe from any thread; a closed output is ignored (the client is gone).
    package func send(_ message: RPCMessage) {
        let data = MessageFramer.frame(message.encoded())
        lock.lock()
        defer { lock.unlock() }
        try? output.write(contentsOf: data)
    }

    /// Reads messages until the input ends, handing each to `handler`. A body that is not JSON-RPC gets a parse
    /// error back; a broken header ends the stream (nothing after it can be framed). Returns why it stopped.
    package func run(_ handler: (RPCMessage) -> Void) -> String {
        var framer = MessageFramer()
        while true {
            guard let chunk = input.readAvailable() else { return "the input ended" }
            let bodies: [Data]
            do { bodies = try framer.append(chunk) } catch { return "\(error)" }
            for body in bodies {
                do { handler(try RPCMessage(body: body)) } catch {
                    send(.errorResponse(id: nil, code: RPCMessage.ErrorCode.parseError, message: "not a JSON-RPC message: \(error)"))
                }
            }
        }
    }
}

extension FileHandle {
    /// The bytes that are ready (at least one, waiting for them), or nil at the end of the input or on an error.
    /// `read(upToCount:)` waits until it has all of them, which never comes on a pipe that stays open.
    package func readAvailable(upTo count: Int = 65_536) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        while true {
            let read = Darwin.read(fileDescriptor, &buffer, count)
            if read > 0 { return Data(buffer[0..<read]) }
            if read < 0, errno == EINTR { continue }
            return nil
        }
    }
}
