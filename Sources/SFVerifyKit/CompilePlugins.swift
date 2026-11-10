import Foundation

extension ModuleCompiler {
    /// The simulator platforms and the device platform whose macro plugins the driver uses for them.
    private static let devicePlatforms = [
        "iPhoneSimulator": "iPhoneOS", "AppleTVSimulator": "AppleTVOS", "WatchSimulator": "WatchOS", "XRSimulator": "XROS",
    ]

    /// The platform `Developer` folder whose macro plugins (`usr/lib/swift/host/plugins`) a compile for `developer`
    /// uses. A simulator platform ships none: the driver takes them from the device platform
    /// (`iPhoneSimulator.platform` → `iPhoneOS.platform`), where SwiftUI's `@State` and `#Preview` macros live. Any other
    /// folder, and a simulator folder that has plugins of its own, is returned unchanged.
    ///
    /// - Parameter exists: whether a path exists (injectable for tests).
    static func pluginPlatformDeveloper(
        _ developer: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        guard !exists(developer + "/usr/lib/swift/host/plugins") else { return developer }
        for (simulator, device) in devicePlatforms.sorted(by: { $0.key < $1.key }) {
            let component = "/\(simulator).platform/"
            guard developer.contains(component) else { continue }
            return developer.replacingOccurrences(of: component, with: "/\(device).platform/")
        }
        return developer
    }
}
