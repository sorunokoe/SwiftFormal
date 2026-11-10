import Foundation

extension FileManager {
    /// Whether `path` is a directory, following symbolic links as `fileExists(atPath:isDirectory:)` does, without its
    /// `ObjCBool` out-parameter (a pointer, which `-strict-memory-safety` reports; plan item H7).
    func isDirectory(atPath path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
