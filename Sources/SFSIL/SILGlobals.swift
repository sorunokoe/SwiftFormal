// Reading guide
// `static let` values and global `let`s (KNOWN-ISSUES 12; app study round 6, L13). At `-Onone` a read of one is a call
// to its addressor, which runs the one-time initializer (`builtin "once"`) and returns the global's address as a raw
// pointer; the caller turns it back with `pointer_to_address` and loads from it. (A `static let` of a literal integer
// is folded into its getter by the compiler and needs none of this.)
//
// Logic reads the addressor call as: run the initializer, which stores the global's value, then give the caller the
// address of a slot holding that value. This is the value every read gets: the global is a `let` (`sil_global [let]`,
// which the compiler checks is stored only by its initializer), and the initializer runs once per process, before the
// first read returns. Its traps are the read's traps: an initializer that traps has never finished, so every first
// read in a process runs it again and traps the same way (it reads no input; a value it does not know, such as a
// foreign result, is a fresh unknown). Only an addressor of the exact shape below is read, for a `[let]` global whose
// initializer logic can encode; a `static var` (mutable), a global read while its own initializer runs (a cycle), and
// any other `global_addr` stay `unsupported`.
//
// Within one encoder the initializer is encoded once and every read shares its value. Two encoders (a function and its
// `ensures`) each encode it: identical circuits for a known value; an unknown one is fresh in each, which only loses
// precision (the claim must then hold for more values than the program can produce).
// Tests: Tests/SFSILTests/SILGlobalTests.swift.

import Foundation
import SFBV
import SFSemantics

/// The addressor of a `let` global: the global, its type and its one-time initializer.
struct GlobalAccess: Sendable {
    let global: String
    let type: ValueType
    let initializer: String
}

/// What reading a `let` global gives: its value, and when the first read traps or is undefined.
struct GlobalValue {
    let leaves: [BV]
    let trap: Int32
    let undefined: Int32
    let trapSites: [TrapSite]
    let approximations: Set<String>
}

extension SILModule {
    /// The global behind `symbol` when `symbol` is the addressor of a `let` global with an initializer, nil otherwise:
    ///
    ///     sil hidden [global_init] @…vau : $@convention(thin) () -> Builtin.RawPointer {
    ///     bb0:
    ///       %0 = global_addr @…Wz : $*Builtin.Word
    ///       %1 = address_to_pointer %0 to $Builtin.RawPointer
    ///       %2 = function_ref @…WZ : $@convention(c) (Builtin.RawPointer) -> ()
    ///       %3 = builtin "once"(%1, %2) : $Builtin.SILToken
    ///       %4 = global_addr @G : $*T depends_on %3
    ///       %5 = address_to_pointer %4 to $Builtin.RawPointer
    ///       return %5
    func globalAccess(_ symbol: String) throws(SILError) -> GlobalAccess? {
        guard let header = header(of: symbol), header.contains("[global_init]"), let body = bodyLines(of: symbol) else { return nil }
        let lines = body.map { stripComment($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasSuffix(":") }
        let shape: [Regex<Substring>] = [
            /%0 = global_addr @\S+ : \$\*Builtin\.Word/,
            /%1 = address_to_pointer %0 to \$Builtin\.RawPointer/,
            /%2 = function_ref @\S+ : \$@convention\(c\) \(Builtin\.RawPointer\) -> \(\)/,
            /%3 = builtin "once"\(%1, %2\) : \$Builtin\.SILToken/,
            /%4 = global_addr @\S+ : \$\*.+ depends_on %3/,
            /%5 = address_to_pointer %4 to \$Builtin\.RawPointer/,
            /return %5/,
        ]
        guard lines.count == shape.count, zip(lines, shape).allSatisfy({ (try? $1.wholeMatch(in: $0)) != nil }),
            let initializer = lines[2].firstMatch(of: /@(\S+)/)?.1,
            let match = lines[4].wholeMatch(of: /%4 = global_addr @(\S+) : \$\*(.+) depends_on %3/)
        else { return nil }
        let global = String(match.1)
        guard isLetGlobal(global) else { throw SILError.unsupported("global variable \(global): only a `let` global is read") }
        return GlobalAccess(global: global, type: try types.resolve(String(match.2)), initializer: String(initializer))
    }
}

extension SILEncoder {
    /// The slot that holds the value of the `let` global `symbol`.
    static func globalSlot(_ symbol: String) -> String { "global:\(symbol)" }

    /// The value of the global `access` names, with the traps of its initializer (see the top of this file).
    func globalValue(_ access: GlobalAccess, stack: [String]) throws -> GlobalValue {
        if let known = globalValues[access.global] { return known }
        guard !initializingGlobals.contains(access.global) else {
            throw SILError.unsupported("global \(access.global) read while its own initializer runs")
        }
        initializingGlobals.insert(access.global)
        defer { initializingGlobals.remove(access.global) }
        let function = try module.function(access.initializer)
        let cfg = try CFG(function)
        guard cfg.headers.isEmpty else { throw SILError.unsupported("loops in the initializer \(access.initializer)") }
        let out = try run(
            function, cfg: cfg, arguments: fresh(.opaque(name: "Builtin.RawPointer")), assumed: [],
            makeState: { _, _ in throw SILError.invalid("no loop headers expected") }, stack: stack + [access.initializer])
        let slot = Self.globalSlot(access.global)
        let width = access.type.leafWidths.count
        var leaves: [BV]?
        for event in out.returns.reversed() {
            let stored = try (0..<width).map { (i) throws -> BV in
                guard let v = event.cells["\(slot)#\(i)"] else {
                    throw SILError.unsupported("the initializer \(access.initializer) may return without storing \(access.global)")
                }
                return v
            }
            leaves = leaves.map { zip(stored, $0).map { c.select(event.condition, $0, $1) } } ?? stored
        }
        guard let leaves else { throw SILError.unsupported("the initializer \(access.initializer) never returns") }
        let value = GlobalValue(
            leaves: leaves, trap: out.traps.reduce(c.falseLit) { c.or($0, $1.condition) },
            undefined: out.undefineds.reduce(c.falseLit) { c.or($0, $1.condition) },
            trapSites: out.traps.map { TrapSite(kind: $0.site, condition: $0.condition) }, approximations: out.approximations)
        globalValues[access.global] = value
        return value
    }
}

/// `global_addr @G : $*T` (with an optional `depends_on %token`).
func readGlobalAddress(_ t: InstructionText) throws(SILError) -> Instruction {
    guard let match = t.rest.wholeMatch(of: /@(\S+) : \$\*(.+?)(?: depends_on %\S+)?/) else {
        throw SILError.unsupported("global_addr: \(t.line)")
    }
    return .globalAddress(result: t.result, symbol: String(match.1), type: try t.types.resolve(String(match.2)))
}

/// `pointer_to_address %p to [strict] $*T`.
func readPointerToAddress(_ t: InstructionText) throws(SILError) -> Instruction {
    guard let to = t.rest.range(of: " to "), case let source = String(t.rest[..<to.lowerBound]), isValue(source) else {
        throw SILError.unsupported("pointer_to_address: \(t.line)")
    }
    let type = dropBracket(String(t.rest[to.upperBound...]))
    guard type.hasPrefix("$*") else { throw SILError.unsupported("pointer_to_address: \(t.line)") }
    return .pointerToAddress(result: t.result, source: source, type: try t.types.resolve(String(type.dropFirst(2))))
}

extension SILModule {
    /// Adds the global of a `sil_global [let] @G : $T` line to `globals`.
    static func recordLetGlobal(_ line: String, into globals: inout Set<String>) {
        guard line.hasPrefix("sil_global "), line.contains(" [let] "), let at = line.range(of: " @") else { return }
        globals.insert(String(line[at.upperBound...].prefix { $0 != " " }))
    }
}
