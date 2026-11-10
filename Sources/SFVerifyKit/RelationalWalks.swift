import Foundation

// Reading guide
// The walks' relational claims, read from the test sources for logic (`RelationalProofs.swift`), and logic's results
// laid over the walks' records. A walk
//
//     Prove("SeatRule.body", it: { SeatRule(input: $0).execute() }, over: seats) {
//         Injective()
//         RoundTrip(through: { SeatBack(input: $0).execute() })
//     }
//
// asks for `Injective` and `RoundTrip` of the chain `SeatRule.init(input:)`, `SeatRule.execute()` (and `execute()` that
// only returns `body` is followed to `body`, as for a walk's subject: `ForwarderResolution.swift`). Only closures that
// are one chain of calls on `$0` (or a named parameter) are read: `f($0)`, `T.f(x: $0)`, `T(x: $0).m()`, `$0.p`, `\.p`,
// an optional `try`, and a `!` that ends an inverse. Anything else (a captured value, a second argument, a loop over
// rules) is not read, and the walk's verdict stands. Tests that declare a `==` are not read at all: the walk would
// compare with it, and logic compares with the derived one.
//
// Overlay: a claim logic proved makes the property proved for every input (unless the walk found a failing input:
// then the walk's verdict stands). A counterexample makes it fail only when the walk was bounded because its domain
// is a sample (`.samples`, `.boundaries`, a generated type): a complete domain, even one too big to walk (`.int(0...n)`),
// states a precondition logic does not know. Either result is laid over a walk only when the rule's first step takes the
// walk's input type exactly (`RelationalInputType.swift`: `$0.code` may have read another type's `code`; a rule over
// `T?` says nothing about `T`), and only over the walk at the request's full path and line. An unknown result changes
// nothing, except that one from a scan that read the rule cancels another scan's proof.
// Tests: Tests/SFVerifyKitTests/RelationalWalkTests.swift.

extension Check {
    /// The relational claims of the walks in the `.swift` files under `testSources`, with forwarders resolved from
    /// the targets under `packages` that the tests or the `scanned` targets import.
    public static func relationalRequests(testSources: String, packages: [String], scanned: [String]) -> [RelationalRequest] {
        let files =
            (FileManager.default.enumerator(atPath: testSources)?.compactMap { $0 as? String } ?? [])
            .filter { $0.hasSuffix(".swift") }.map { testSources + "/" + $0 }.sorted()
        var texts: [String] = []
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
            texts.append(text)
        }
        let requests = relationalRequests(files: files, texts: texts)
        guard !requests.isEmpty else { return [] }
        var roots: [String] = []
        for root in packages
        where !roots.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL == URL(fileURLWithPath: root).standardizedFileURL }) {
            roots.append(root)
        }
        return resolvingForwarders(
            requests, testTexts: texts, scanned: scanned, targets: roots.flatMap { sourceTargets(under: $0, extensions: ["swift", "h"]) },
            read: { try? String(contentsOfFile: $0, encoding: .utf8) })
    }

    /// The claims of the walks in `texts` (the contents of `files`); none when a test declares a `==`, and none that
    /// call a function, or use a type, that a test declares or extends: the walk may call that one, not the app's.
    static func relationalRequests(files: [String], texts: [String]) -> [RelationalRequest] {
        guard !texts.contains(where: { $0.contains("func ==") }) else { return [] }
        let requests = zip(files, texts).flatMap { RelationalWalkParser.requests(in: $1, file: $0) }
        let all = texts.joined(separator: "\n")
        func declared(_ pattern: String) -> Bool { all.range(of: pattern, options: .regularExpression) != nil }
        var verdicts: [RelationalStep: Bool] = [:]
        func shadowed(_ step: RelationalStep) -> Bool {
            if let known = verdicts[step] { return known }
            let name = NSRegularExpression.escapedPattern(for: step.name)
            var found = declared(#"\bfunc\s+"# + name + #"\b"#) || declared(#"\bvar\s+"# + name + #"\s*:"#)
            if let type = step.type.map(NSRegularExpression.escapedPattern) {
                found = found || declared(#"\b(struct|class|enum|actor|typealias|protocol|extension)\s+"# + type + #"\b"#)
            }
            verdicts[step] = found
            return found
        }
        return requests.filter { !($0.forward + $0.other).contains(where: shadowed) }
    }

    /// `requests` with each step `execute()` of `T(…).execute()` replaced by the member it only returns (`body`).
    static func resolvingForwarders(
        _ requests: [RelationalRequest], testTexts: [String], scanned: [String], targets: [SourceTarget], read: (String) -> String?
    ) -> [RelationalRequest] {
        // Each `T.m()` is asked as the walk `Prove(it: { T(x: $0).m() })` in a file of its own.
        var synthetic: [String: String] = [:]
        var walks: [WalkCheck] = []
        for request in requests {
            for step in request.forward + request.other where step.kind == .method && step.labels.isEmpty {
                guard let type = step.type, !type.contains(".") else { continue }
                let file = "relational-forwarder:\(type).\(step.name)"
                guard synthetic[file] == nil else { continue }
                synthetic[file] = "Prove(it: { \(type)(x: $0).\(step.name)() })"
                walks.append(WalkCheck(subject: "\(type).\(step.name)()", file: file, line: 1, suite: nil, test: nil))
            }
        }
        guard !walks.isEmpty else { return requests }
        let resolved = resolvingForwarders(walks, testTexts: testTexts, scanned: scanned, targets: targets) { synthetic[$0] ?? read($0) }
        var forwarded: [RelationalStep: RelationalStep] = [:]
        for (walk, after) in zip(walks, resolved) where after.subject != walk.subject {
            let type = String(walk.subject.prefix { $0 != "." })
            let name = walk.subject.dropFirst(type.count + 1).dropLast(2)
            let member = after.subject.dropFirst(type.count + 1)
            let target =
                member.hasSuffix("()")
                ? RelationalStep(.method, type: type, name: String(member.dropLast(2)))
                : RelationalStep(.getter, type: type, name: String(member))
            forwarded[RelationalStep(.method, type: type, name: String(name))] = target
        }
        return requests.map { request in
            var request = request
            request.forward = request.forward.map { forwarded[$0] ?? $0 }
            request.other = request.other.map { forwarded[$0] ?? $0 }
            return request
        }
    }

    /// `records` with logic's `results` laid over their properties (see the top of this file).
    public static func applyingRelational(_ results: [RelationalResult], to records: [WalkRecord]) -> [WalkRecord] {
        let decided = decidedResults(results)
        return records.map { record in
            var record = record
            var changed = false
            var returnsNormally: RelationalResult?
            for index in record.properties.indices {
                let name = record.properties[index].name
                guard let result = decided[relationalKey(record.file, record.line, name)],
                    record.properties.count(where: { $0.name == name }) == 1,
                    let property = overlaid(result, on: record.properties[index], of: record)
                else { continue }
                record.properties[index] = property
                changed = true
                if result.verdict == .proved { returnsNormally = returnsNormally ?? result }
            }
            // Logic proves a claim only after proving the rule returns normally for every input: that is `total`.
            if let returnsNormally, let index = record.properties.firstIndex(where: { $0.name == "total" && $0.verdict != "failed" }) {
                record.properties[index].verdict = "proved"
                record.properties[index].logic = "proved"
                record.properties[index].detail = Self.byLogic(returnsNormally)
            }
            if changed {
                if record.properties.contains(where: { $0.verdict == "failed" }) {
                    record.verdict = "failed"
                } else if record.properties.allSatisfy({ $0.verdict == "proved" }) {
                    record.verdict = "proved"
                }
            }
            return record
        }
    }

    /// The place of a claim: the walk's file by its full path (a request names it relative to where the tests were
    /// read; a walk by its `#filePath`), its line and the property.
    private static func relationalKey(_ file: String, _ line: Int, _ property: String) -> String {
        "\(URL(fileURLWithPath: file).standardizedFileURL.resolvingSymlinksInPath().path):\(line):\(property)"
    }

    /// The decided results by place. Several scans may answer one claim: one in which no function matches the rule
    /// says nothing; one that read the rule and could not decide, or two that disagree, cancel out.
    private static func decidedResults(_ results: [RelationalResult]) -> [String: RelationalResult] {
        var decided: [String: RelationalResult] = [:]
        var conflicting: Set<String> = []
        for result in results where result.unresolved == nil {
            let place = relationalKey(result.request.file, result.request.line, result.request.property)
            if result.verdict == .unknown {
                conflicting.insert(place)
            } else if let earlier = decided[place], earlier.verdict != result.verdict || earlier.inputType != result.inputType {
                conflicting.insert(place)
            } else if decided[place] == nil {
                decided[place] = result
            }
        }
        return decided.filter { !conflicting.contains($0.key) }
    }

    /// `property` with `result` laid over it; nil when the result does not change it (a result about another input type,
    /// or one whose type is not known, says nothing; a walk's failure stands; a counterexample replaces only a bound that
    /// comes from sampling).
    private static func overlaid(_ result: RelationalResult, on property: WalkRecord.Property, of record: WalkRecord) -> WalkRecord
        .Property?
    {
        guard property.verdict != "failed", let walked = record.inputType, let rule = result.inputType,
            RelationalTypeSource.canonical(walked) == RelationalTypeSource.canonical(rule)
        else { return nil }
        var property = property
        switch result.verdict {
        case .proved:
            property.verdict = "proved"
            property.logic = "proved"
            property.input = nil
            property.detail = Self.byLogic(result)
        case .refuted:
            guard !record.domainComplete, property.verdict == "bounded", property.detail == sampleReason else { return nil }
            property.verdict = "failed"
            property.logic = "refuted"
            property.input = result.inputs
            property.detail = (result.detail.map { $0 + " " } ?? "") + "(found by logic, outside the walked inputs)"
        case .unknown:
            return nil
        }
        return property
    }

    private static func byLogic(_ result: RelationalResult) -> String {
        "for every input, by logic" + (result.assumptions.map { ", assuming \($0.joined(separator: "; "))" } ?? "")
    }

    /// The reason a walk gives for `bounded` when its domain is a sample of the input type (`Verify.swift`), not a
    /// range that states a precondition and was too big to walk, nor one where inputs threw.
    static let sampleReason = "the domain is a sample, not the whole input space"
}
