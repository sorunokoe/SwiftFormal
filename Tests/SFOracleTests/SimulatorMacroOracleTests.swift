import Foundation
import SFTestSupport
import SFVerifyKit
import Testing

/// App study round 6, bug A: SwiftUI's `@State` is a macro on the iOS 27 SDK, and its plugin lives in the device platform
/// (`iPhoneOS.platform`), not in `iPhoneSimulator.platform`. A file that uses it must compile for the simulator, as it
/// does with the `swiftc` driver; before the fix every SwiftUI module of an app built for the simulator failed.
@Suite(.tags(.oracle, .slow), .requiresPinnedCompiler) struct SimulatorMacroOracleTests {
    /// `xcrun --sdk iphonesimulator --show-sdk-path`, nil when there is no such SDK.
    static let simulatorSDK: String? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "iphonesimulator", "--show-sdk-path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }()

    @Test(.enabled(if: simulatorSDK != nil, "needs the iPhoneSimulator SDK (xcrun --sdk iphonesimulator)"))
    func aStateMacroCompilesForTheSimulator() throws {
        let sdk = try #require(Self.simulatorSDK)
        let directory = NSTemporaryDirectory() + "sfv-sim-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/Counter.swift"
        try """
        import SwiftUI
        public struct CounterView: View {
            @State private var count = 0
            public init() {}
            public var body: some View { Text("\\(count)") }
        }
        public func half(_ x: Int8) -> Int8 { x / 2 }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions()
        options.configurations = [.debug]
        let compile = CompileOptions(
            files: [file], moduleName: "SimulatorCounter", extraArguments: ["-sdk", sdk, "-target", "arm64-apple-ios18.5-simulator"])
        let report = try SFVerify.run(compile, options)
        #expect(report.functions.first { $0.name.hasPrefix("half(") }?.status == .safe)
    }
}
