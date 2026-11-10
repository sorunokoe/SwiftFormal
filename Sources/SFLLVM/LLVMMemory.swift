// Reading guide
// Where values live in memory, as LLVM IR itself says: the size, alignment and field offsets of LLVM types (the target
// is little-endian with natural alignment, arm64 and x86-64 alike), from which `getelementptr` offsets, `load` and
// `store` widths and `alloca` sizes follow. Swift prints its own types packed (`<{ ... }>`), with explicit padding.
// Memory itself is a map from (region, byte offset) to a byte: `LLVMEncoder` keeps it.
// Nothing here knows about Swift's own layout rules; that is `LLVMBridge.swift`, which reads SIL types.
// Tests: Tests/SFVerifyKitTests/CrossCheckTests.swift (real compiler output), Tests/SFOracleTests/LLVMTests.swift.

extension LType {
    /// The width of an integer type, nil for any other type.
    var integerWidth: Int? { if case .int(let n) = self { n } else { nil } }
}

/// Size and alignment of an LLVM type, in bytes.
struct TypeLayout: Equatable {
    let size: Int
    let align: Int
    /// The distance between two consecutive values of the type in memory: `size` rounded up to `align`.
    var allocSize: Int { (size + align - 1) / align * align }
}

extension LLVMModule {
    /// `type` with named types replaced by their definitions, one level.
    func resolved(_ type: LType) throws -> LType {
        guard case .named(let name) = type else { return type }
        guard let definition = namedTypes[name] else { throw LLVMError.unsupported("type %\(name) has no readable definition") }
        return definition
    }

    func layout(of type: LType, depth: Int = 0) throws -> TypeLayout {
        guard depth < 64 else { throw LLVMError.unsupported("type nesting too deep: \(type.description)") }
        switch type {
        case .int, .ptr:
            let n = type == .ptr ? 64 : (type.integerWidth ?? 0)
            guard [1, 8, 16, 32, 64, 128].contains(n) else { throw LLVMError.unsupported("memory layout of \(type.description)") }
            return TypeLayout(size: max(1, n / 8), align: max(1, n / 8))
        case .packed(let fields):
            return TypeLayout(size: try fields.reduce(0) { $0 + (try layout(of: $1, depth: depth + 1).allocSize) }, align: 1)
        case .tuple(let fields):
            return try structLayout(fields, depth: depth)
        case .array(let count, let element):
            let l = try layout(of: element, depth: depth + 1)
            guard count <= 1 << 20 else { throw LLVMError.unsupported("array of \(count) elements") }
            return TypeLayout(size: count * l.allocSize, align: l.align)
        case .named:
            return try layout(of: try resolved(type), depth: depth + 1)
        case .void, .other:
            throw LLVMError.unsupported("memory layout of \(type.description)")
        }
    }

    /// As LLVM's `StructLayout`: each field at its alignment taking its alloc size, and the struct ending on its alignment.
    private func structLayout(_ fields: [LType], depth: Int) throws -> TypeLayout {
        var offset = 0, align = 1
        for field in fields {
            let l = try layout(of: field, depth: depth + 1)
            offset = (offset + l.align - 1) / l.align * l.align + l.allocSize
            align = max(align, l.align)
        }
        return TypeLayout(size: (offset + align - 1) / align * align, align: align)
    }

    /// The byte offset and type of element `index` of an aggregate (struct field or array element).
    func element(_ index: Int64, of type: LType) throws -> (offset: Int, type: LType) {
        switch try resolved(type) {
        case .packed(let fields):
            guard index >= 0, index < fields.count else { throw LLVMError.invalid("field \(index) of \(type.description)") }
            var offset = 0
            for field in fields[..<Int(index)] { offset += try layout(of: field).allocSize }
            return (offset, fields[Int(index)])
        case .tuple(let fields):
            guard index >= 0, index < fields.count else { throw LLVMError.invalid("field \(index) of \(type.description)") }
            var offset = 0
            for (k, field) in fields.enumerated() {
                let l = try layout(of: field)
                offset = (offset + l.align - 1) / l.align * l.align
                if k == Int(index) { return (offset, field) }
                offset += l.allocSize
            }
            throw LLVMError.invalid("field \(index) of \(type.description)")
        case .array(let count, let element):
            guard index >= 0, index <= Int64(count) else { throw LLVMError.unsupported("array index \(index) out of range") }
            return (Int(index) * (try layout(of: element).allocSize), element)
        default:
            throw LLVMError.unsupported("element \(index) of \(type.description)")
        }
    }

    /// The bytes a `load` or `store` of `type` touches. Only whole bytes and `i1` (one byte, the value in bit 0).
    func storeSize(_ type: LType) throws -> Int {
        switch type {
        case .int(let n) where n == 1 || (n % 8 == 0 && n >= 8 && n <= 64): return max(1, n / 8)
        case .ptr: return 8
        default: throw LLVMError.unsupported("load or store of \(type.description)")
        }
    }
}
