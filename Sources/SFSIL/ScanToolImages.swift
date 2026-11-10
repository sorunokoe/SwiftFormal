import Foundation
import SFProve
import SFSemantics

#if canImport(Darwin)
    import Darwin
    import MachO
#endif

/// The loaded images the encoder, the solver and the checker run from, named by the UUIDs their linker wrote into them.
///
/// A proof cache's key names the tool that made and checked an answer. The name comes from memory: from the Mach-O
/// header of the loaded image that holds a type of each module, which is what this process runs whatever happens to
/// the file on disk afterwards, and which is the library itself when the modules are used from someone else's
/// executable. The linker gives each image a UUID made from its contents unless told not to (`-no_uuid`); an image
/// without one, an address in no image, or a platform without Mach-O gives no identity, and so no cache.
package enum ScanToolImages {
    /// A loaded image: its path, its UUID (nil when it has none), and the address ranges of its mapped segments.
    package struct Image: Sendable {
        /// The path dyld loaded it from.
        package let path: String
        /// The `LC_UUID`, in `UUID.uuidString` form; nil when the image has none.
        package let uuid: String?
        let segments: [Range<UInt>]
    }

    /// One type of each module the Scan claim's answers come from: the SIL encoder, the semantics and the prover.
    package static func encoderTypes() -> [Any.Type] {
        [SILModule.self, SILEncoder.self, S0Instance.self] + ProverTypes.all()
    }

    /// The sorted, comma-separated UUIDs of the images that hold `types`' metadata; nil if one is in no image or has
    /// no UUID.
    package static func identity(of types: [Any.Type]) -> String? {
        let images = loaded()
        var uuids: Set<String> = []
        for type in types {
            guard let uuid = image(containing: UInt(bitPattern: ObjectIdentifier(type)), in: images)?.uuid else { return nil }
            uuids.insert(uuid)
        }
        return uuids.isEmpty ? nil : uuids.sorted().joined(separator: ",")
    }

    /// The loaded image one of whose segments holds `address`; nil if none does.
    package static func image(containing address: UInt, in images: [Image] = loaded()) -> Image? {
        images.first { image in image.segments.contains { $0.contains(address) } }
    }

    /// The images dyld has loaded into this process.
    package static func loaded() -> [Image] {
        #if canImport(Darwin)
            return (0..<_dyld_image_count()).compactMap { index in
                guard let header = _dyld_get_image_header(index), let name = _dyld_get_image_name(index) else { return nil }
                // The header and its load commands, copied: 32 bytes, then as many as the header says the commands take.
                let fixed = Data(bytes: header, count: headerSize)
                guard fixed.word(at: 0) == MH_MAGIC_64 else { return nil }
                let commands = Data(bytes: header, count: headerSize + Int(fixed.word(at: 20)))
                let slide = UInt(bitPattern: _dyld_get_image_vmaddr_slide(index))
                return image(commands, count: Int(fixed.word(at: 16)), slide: slide, path: String(cString: name))
            }
        #else
            return []
        #endif
    }

    /// The size of `mach_header_64`; its load commands follow it.
    private static let headerSize = 32

    /// The segments and the UUID that the `count` load commands of the Mach-O header `bytes` give; nil if one
    /// runs past the end.
    private static func image(_ bytes: Data, count: Int, slide: UInt, path: String) -> Image? {
        var segments: [Range<UInt>] = []
        var uuid: String?
        var offset = headerSize
        for _ in 0..<count {
            guard offset + 8 <= bytes.count else { return nil }
            let command = bytes.word(at: offset)
            let size = Int(bytes.word(at: offset + 4))
            guard size >= 8, offset + size <= bytes.count else { return nil }
            if command == lcSegment64, size >= 72, bytes.word(at: offset + 60) != 0 {
                // segment_command_64: vmaddr at 24, vmsize at 32, initprot at 60 (0 for __PAGEZERO).
                let start = UInt(bytes.doubleWord(at: offset + 24)) &+ slide
                segments.append(start..<(start &+ UInt(bytes.doubleWord(at: offset + 32))))
            } else if command == lcUUID, size >= 24 {
                uuid = uuidString(Array(bytes[(bytes.startIndex + offset + 8)..<(bytes.startIndex + offset + 24)]))
            }
            offset += size
        }
        return Image(path: path, uuid: uuid, segments: segments)
    }

    private static let lcSegment64: UInt32 = 0x19
    private static let lcUUID: UInt32 = 0x1b

    /// `bytes` as `UUID.uuidString` writes it (8-4-4-4-12 upper-case hex digits); nil when all are zero.
    private static func uuidString(_ bytes: [UInt8]) -> String? {
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        let hex = bytes.map { ProofDigest.hex($0, digits: 2).uppercased() }
        return [0..<4, 4..<6, 6..<8, 8..<10, 10..<16].map { hex[$0].joined() }.joined(separator: "-")
    }
}

extension Data {
    /// The little-endian 32-bit word `offset` bytes in.
    fileprivate func word(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }

    /// The little-endian 64-bit word `offset` bytes in.
    fileprivate func doubleWord(at offset: Int) -> UInt64 {
        UInt64(word(at: offset)) | UInt64(word(at: offset + 4)) << 32
    }
}
