import Testing

@testable import SFVerifyKit

/// App study round 6, bug A: a simulator platform has no macro plugins; a compile for it takes them from the device
/// platform, as the `swiftc` driver does, or every SwiftUI file (`@State`, `#Preview`) fails to compile.
@Suite struct PluginPlatformTests {
    private static let platforms = "/Applications/Xcode.app/Contents/Developer/Platforms"

    @Test(arguments: [
        ("iPhoneSimulator", "iPhoneOS"), ("AppleTVSimulator", "AppleTVOS"), ("WatchSimulator", "WatchOS"),
        ("XRSimulator", "XROS"),
    ])
    func aSimulatorWithoutPluginsUsesTheDevicePlatform(simulator: String, device: String) {
        let developer = "\(Self.platforms)/\(simulator).platform/Developer"
        let found = ModuleCompiler.pluginPlatformDeveloper(developer) { _ in false }
        #expect(found == "\(Self.platforms)/\(device).platform/Developer")
    }

    @Test func aSimulatorWithItsOwnPluginsKeepsThem() {
        let developer = "\(Self.platforms)/iPhoneSimulator.platform/Developer"
        let found = ModuleCompiler.pluginPlatformDeveloper(developer) { $0 == developer + "/usr/lib/swift/host/plugins" }
        #expect(found == developer)
    }

    @Test(arguments: [
        "\(platforms)/MacOSX.platform/Developer", "\(platforms)/iPhoneOS.platform/Developer", "/opt/toolchain/Developer",
    ])
    func anyOtherPlatformIsUnchanged(developer: String) {
        #expect(ModuleCompiler.pluginPlatformDeveloper(developer) { _ in false } == developer)
    }
}
