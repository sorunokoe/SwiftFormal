import Foundation

// Reading guide
// What destroying a value may run. Destroys are not encoded (`destroy_value`, `release_value` are ignored), so a value
// is read only when its destruction cannot run code of the read modules, or when the scan assumes what that code does.
//
// - Each deinit of the read modules is inspected (`codeRunningDeinits`, an allow-list): one that only releases, reads
//   and branches, cancels a task or destroys a default actor runs no code. Any other deinit runs code: its class is
//   listed. A call to the superclass's deinit (`function_ref …fd`, or an Objective-C superclass's `-dealloc` through
//   `objc_super_method`) runs no code only when the superclass is a class of the read modules, whose deinit is
//   inspected the same way, or exactly `NSObject`. Any other superclass (of an SDK or a binary framework) has a deinit
//   Scan has no body of, which may trap or call back into the read modules: the superclass is listed.
// - A closure, an existential, a key path or an object of a read module may hold the last reference to an object of any
//   class, so destroying one may run any listed deinit. With no class listed, that is safe. Otherwise, with calls
//   without a body assumed (`OpaqueCallMode.all`, the scan's default), it is an assumption per listed class, "the deinit
//   of X does not trap", which the verdict lists (`Assumptions`); with `--no-opaque-calls` (or outside a scan) the
//   type is refused. The assumption is that the deinit does not trap; its other effects (a global it writes, a
//   notification it posts) are outside what Scan models for a mapper, which reads no mutable global state.
// - A parsed body is cached (`SILParseCache.swift`), so the assumptions its types took are kept with it
//   (`SILFunction.assumptions`) and noted each time it runs.
//
// Tests: Tests/SFSILTests/SILDeinitTests.swift, SILClosureTests.swift.

/// The assumption a verdict lists when destroying a value may run a deinit that calls code or can trap.
package enum DeinitAssumption {
    /// The assumption for `className`, whose deinit runs code: it names the class.
    package static func text(_ className: String) -> String {
        "deinit of \(className) does not trap (destroying a closure, existential or object may run it)"
    }

    /// `parse()`, with the assumptions its type resolutions noted kept in the function.
    static func collecting(_ parse: () throws(SILError) -> SILFunction) throws(SILError) -> SILFunction {
        let notes = Assumptions()
        var function = try Assumptions.$current.withValue(notes) { Result { () throws(SILError) in try parse() } }.get()
        function.assumptions = notes.all
        return function
    }
}

extension TypeContext {
    /// Whether some deinit of the read modules calls code or can trap.
    var deinitsMayRunCode: Bool { codeRunningDeinits != [] }

    /// Whether a value that may hold the last reference to an object of any class may be destroyed: when no deinit of
    /// the read modules runs code, or, with `OpaqueCallMode.all`, assuming each one that does cannot trap (noted).
    func acceptsUnknownReleases() -> Bool {
        guard let classes = codeRunningDeinits else { return false }
        if classes.isEmpty { return true }
        guard binary.opaqueCalls == .all else { return false }
        for name in classes { Assumptions.note(DeinitAssumption.text(name)) }
        return true
    }

    /// Releasing an object of a class or actor of the read modules runs its deinit and destroys its fields: any deinit
    /// of the read modules. `kind` is the reason the type is in `rejected`; other kinds are not objects.
    func objectReleaseRunsNoModuleCode(_ kind: String) -> Bool {
        ["class", "generic class", "actor", "generic actor"].contains(kind) && acceptsUnknownReleases()
    }

    /// Why a refused type's destruction is unsafe: the classes whose deinit runs code, and what would accept it.
    var deinitRefusalNote: String {
        guard let classes = codeRunningDeinits, !classes.isEmpty else { return "" }
        let named = " (the deinit of \(classes.prefix(3).joined(separator: ", "))\(classes.count > 3 ? ", …" : ""))"
        return named + (binary.opaqueCalls == .none ? " " + OpaqueCallMode.strictNote : "")
    }
}

extension SILModule {
    /// The classes whose deinit may do more than release, read and branch, sorted: classes of `bodies`, and the
    /// superclasses outside them that a deinit of `bodies` calls. Allowed: field projections and reads, releases,
    /// branches, the deinit of a superclass of the read modules or of `NSObject`, an actor's `destroyDefaultActor`, and
    /// the reviewed calls in `reviewedCalls`. Anything else counts as code (an allow-list): a trap (`precondition`,
    /// `fatalError`), any other call (a function of an unread module can trap too, like `Data`'s subscript), dynamic
    /// dispatch, a store, a global.
    static func codeRunningDeinits(_ bodies: [String: [String]], headers: [String: String]) -> [String] {
        let reviewed = reviewedCalls(allowedBy: bodies)
        let deinits = bodies.filter { $0.key.hasSuffix("fd") || $0.key.hasSuffix("fD") }
        let readClasses = Set(deinits.keys.map { deinitClass($0, header: headers[$0]) })
        var listed: Set<String> = []
        for (symbol, body) in deinits {
            let inspected = inspectDeinit(body, reviewed: reviewed, isRead: { bodies[$0] != nil }, readClasses: readClasses)
            if inspected.runsCode { listed.insert(deinitClass(symbol, header: headers[symbol])) }
            listed.formUnion(inspected.unreadSuperclasses)
        }
        return listed.sorted()
    }

    /// The class a deinit belongs to: its `self` parameter's type, `(@owned Loud) -> ()`; the symbol if not printed.
    private static func deinitClass(_ symbol: String, header: String?) -> String {
        guard let header, let open = header.range(of: ") (", options: .backwards) ?? header.range(of: " (") else { return symbol }
        var type = String(header[open.upperBound...].prefix { $0 != ")" && $0 != "," })
        for convention in ["@owned ", "@guaranteed "] where type.hasPrefix(convention) { type.removeFirst(convention.count) }
        return type.isEmpty ? symbol : type
    }

    /// Calls that take only `self`, cannot trap, and run no code of the read modules. `Task.cancel()` runs the task's
    /// cancellation callbacks, so it is reviewed only while no read module registers one.
    private static func reviewedCalls(allowedBy bodies: [String: [String]]) -> Set<String> {
        var calls: Set<String> = ["$s7Network13NWPathMonitorC6cancelyyF"]
        let registersCallback = bodies.values.contains { body in
            body.contains { $0.containsText("TaskCancellationHandler") || $0.containsText("onTermination") }
        }
        if !registersCallback { calls.insert("$sScT6cancelyyF") }
        return calls
    }

    private static let readOnly: Set<String> = [
        "debug_value", "debug_step", "ref_element_addr", "struct_element_addr", "tuple_element_addr", "begin_access",
        "end_access", "destroy_addr", "destroy_value", "strong_release", "release_value", "strong_retain", "retain_value",
        "copy_value", "unchecked_ref_cast", "upcast", "dealloc_ref", "return", "load", "load_borrow", "begin_borrow",
        "end_borrow", "integer_literal", "tuple", "struct", "enum", "struct_extract", "tuple_extract", "select_enum",
        "select_enum_addr", "unchecked_enum_data", "unchecked_take_enum_data_addr", "unchecked_inplace_enum_data_addr",
        "switch_enum", "switch_enum_addr", "br", "cond_br", "alloc_stack", "dealloc_stack", "end_lifetime",
    ]

    private static let objcDealloc = ".deinit!deallocator.foreign"

    /// The superclass a superclass-deinit call (`function_ref …fd`, or `[super dealloc]` through `objc_super_method`)
    /// runs code of Scan has no body of; nil for a class of the read modules, whose deinit is inspected on its own, and
    /// for `NSObject`, whose `-dealloc` releases only.
    private static func unreadSuperclass(
        _ operand: String, _ member: String, _ line: String, _ isRead: (String) -> Bool, _ readClasses: Set<String>
    ) -> String? {
        guard member.hasPrefix("#"), member.hasSuffix(objcDealloc) else {
            return isRead(String(operand.dropFirst())) ? nil : deinitClass(operand, header: line)
        }
        let superclass = String(member.dropFirst().dropLast(objcDealloc.count))
        return superclass == "NSObject" || readClasses.contains(superclass) ? nil : superclass
    }

    /// Whether a deinit runs code, and the superclasses outside the read modules whose deinit it calls.
    private static func inspectDeinit(
        _ body: [String], reviewed: Set<String>, isRead: (String) -> Bool, readClasses: Set<String>
    ) -> (runsCode: Bool, unreadSuperclasses: Set<String>) {
        var callees: Set<String> = []
        var unread: Set<String> = []
        var runsCode = false
        for raw in body {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("bb") || line.hasPrefix("}") { continue }
            let words = line.split(separator: " ").map(String.init)
            let head = words.count > 2 && words[1] == "=" ? words[2] : words[0]
            let operand = words.count > 3 && words[1] == "=" ? words[3] : ""
            let member = words.count > 4 && words[1] == "=" ? words[4] : ""
            switch head {
            case _ where readOnly.contains(head):
                continue
            case "function_ref" where reviewed.contains(String(operand.dropFirst())):
                callees.insert(words[0])
            case "function_ref" where operand.hasSuffix("fd"),
                "objc_super_method" where member.hasPrefix("#") && member.hasSuffix(objcDealloc):
                callees.insert(words[0])
                if let name = unreadSuperclass(operand, member, line, isRead, readClasses) { unread.insert(name) }
            case "apply" where callees.contains(String(operand.prefix { $0 != "(" && $0 != "<" })):
                continue
            case "builtin" where operand.hasPrefix("\"destroyDefaultActor\""):
                continue
            default:
                runsCode = true
            }
        }
        return (runsCode, unread)
    }
}
