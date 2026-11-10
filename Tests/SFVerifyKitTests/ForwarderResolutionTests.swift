import Foundation
import Testing

@testable import SFVerifyKit

/// Mapper plan T2: a walk over `X(input: $0).execute()`, where `execute()` is a protocol extension that only returns
/// `body`, checks `X.body`. Before, its subject was `X.execute()`, which names no scanned function: the walk was not run.
@Suite struct ForwarderResolutionTests {
    static let rule = """
        public protocol Rule<Input, Output> {
            associatedtype Input
            associatedtype Output
            var input: Input { get }
            var body: Output { get }
        }
        public extension Rule {
            func execute() -> Output {
                body
            }
            func callAsFunction<R: Rule>(_ next: (Output) -> R) -> R.Output { next(execute()).execute() }
        }
        """
    static let textRule = """
        public struct TextRule: Rule {
            public let input: Int
            public var body: String { input == 0 ? "none" : "some" }
        }
        """

    private static func walk(_ line: String, subject: String = "TextRule.execute()") -> (WalkCheck, [String]) {
        let lines = ["    @Test func text() {", "        " + line, "    }"]
        return (WalkCheck(subject: subject, file: "/t/Walks.swift", line: 2, suite: "Walks", test: "text"), lines)
    }

    private static func resolved(_ line: String, subject: String = "TextRule.execute()", sources: [String]) -> String {
        let (walk, lines) = walk(line, subject: subject)
        let forwarders = Check.Forwarders(sources: sources)
        return Check.resolvingForwarders([walk], forwarders: forwarders) { _ in lines }[0].subject
    }

    @Test func aConstructedRuleThroughAOneLineForwarderNamesItsBody() {
        let sources = [Self.rule, Self.textRule]
        #expect(Self.resolved("Prove(it: { TextRule(input: $0).execute() }, over: .int(0...3)) {", sources: sources) == "TextRule.body")
        #expect(
            Self.resolved("Prove(it: { n in try TextRule(input: f(n, 2)).execute() }, over: xs) {", sources: sources) == "TextRule.body")
        // A written subject keeps what follows its `Type.member`.
        #expect(
            Self.resolved(
                #"Prove("TextRule.execute (finite)", it: { TextRule(input: $0).execute() }, over: xs) {"#,
                subject: "TextRule.execute (finite)",
                sources: sources) == "TextRule.body (finite)")
        for forward in ["return body", "self.body", "return self.body"] {
            let rule = Self.rule.replacingOccurrences(of: "        body\n", with: "        \(forward)\n")
            #expect(
                Self.resolved("Prove(it: { TextRule(input: $0).execute() }, over: xs) {", sources: [rule, Self.textRule]) == "TextRule.body"
            )
        }
        // A forwarder that calls one method the protocol requires names that method.
        let calling = Self.rule.replacingOccurrences(of: "    var body: Output { get }\n", with: "    func make() -> Output\n")
            .replacingOccurrences(of: "        body\n", with: "        make()\n")
        let maker = Self.textRule.replacingOccurrences(of: "var body: String {", with: "func make() -> String {")
        #expect(Self.resolved("Prove(it: { TextRule(input: $0).execute() }, over: xs) {", sources: [calling, maker]) == "TextRule.make()")
    }

    @Test func anythingButAOneMemberForwardKeepsTheSubject() {
        let walk = "Prove(it: { TextRule(input: $0).execute() }, over: xs) {"
        let unchanged = "TextRule.execute()"
        let bodies = ["log(); return body", "body.uppercased()", "input == 0 ? body : body", "other", "Self.body"]
        for body in bodies {
            let rule = Self.rule.replacingOccurrences(of: "        body\n", with: "        \(body)\n")
            #expect(Self.resolved(walk, sources: [rule, Self.textRule]) == unchanged, "\(body)")
        }
        // A constrained extension may not apply to the type; a member that is not a requirement is not the type's.
        let constrained = Self.rule.replacingOccurrences(
            of: "public extension Rule {", with: "public extension Rule where Output == String {")
        #expect(Self.resolved(walk, sources: [constrained, Self.textRule]) == unchanged)
        let notRequired = Self.rule.replacingOccurrences(of: "    var body: Output { get }\n", with: "")
        #expect(Self.resolved(walk, sources: [notRequired, Self.textRule]) == unchanged)
        // The type declares its own `execute()`, or another one is declared somewhere: the call may not be the forwarder.
        let shadowed = Self.textRule.replacingOccurrences(
            of: "public let input: Int", with: "public let input: Int\n    func execute() -> String { \"x\" }")
        #expect(Self.resolved(walk, sources: [Self.rule, shadowed]) == unchanged)
        #expect(
            Self.resolved(walk, sources: [Self.rule, Self.textRule, "extension TextRule { func execute() -> String { \"\" } }"])
                == unchanged)
        // The type does not conform, is declared twice, or is not declared in the sources.
        let notConforming = Self.textRule.replacingOccurrences(of: "TextRule: Rule", with: "TextRule")
        #expect(Self.resolved(walk, sources: [Self.rule, notConforming]) == unchanged)
        #expect(Self.resolved(walk, sources: [Self.rule, Self.textRule, "enum TextRule {}"]) == unchanged)
        #expect(Self.resolved(walk, sources: [Self.rule]) == unchanged)
    }

    @Test func onlyACallOnAValueTheClosureBuildsIsFollowed() {
        let sources = [Self.rule, Self.textRule]
        for line in [
            "Prove(it: { TextRule.shared.execute() }, over: xs) {",
            "Prove(it: { TextRule(input: $0).execute().count }, over: xs) {",
            "Prove(it: { TextRule(input: $0)?.execute() }, over: xs) {",
            "Prove(it: { TextRule(input: $0).execute(); other() }, over: xs) {",
            "Prove(it: { $0.execute() }, over: xs) {",
        ] {
            #expect(Self.resolved(line, sources: sources) == "TextRule.execute()", "\(line)")
        }
        // The subject names another type than the closure builds.
        #expect(
            Self.resolved(
                "Prove(\"Other.execute()\", it: { TextRule(input: $0).execute() }, over: xs) {", subject: "Other.execute()",
                sources: sources) == "Other.execute()")
    }

    @Test func aWalkThatStillNamesNoScannedMemberOfAScannedTypeSaysWhichToName() throws {
        let json = #"{"name":"TextRule.body.getter","symbol":"s","status":"unsupported","hasContract":false,"seconds":0}"#
        let function = try JSONDecoder().decode(FunctionReport.self, from: Data(json.utf8))
        let timing = try JSONDecoder().decode(
            ScanReport.Timing.self, from: Data(#"{"compileSeconds":0,"parseSeconds":0,"verifySeconds":0,"silBytes":0}"#.utf8))
        let scan = ScanReport(module: "App", optimization: "-Onone", functions: [function], timing: timing)
        let walks = [
            WalkCheck(subject: "TextRule.execute()", file: "/t/W.swift", line: 1, suite: nil, test: nil),
            WalkCheck(subject: "Elsewhere.run()", file: "/t/W.swift", line: 2, suite: nil, test: nil),
        ]
        let (hints, rest) = Check.memberHints(for: walks, scans: [scan])
        #expect(rest.map(\.subject) == ["Elsewhere.run()"])
        let hint = try #require(hints.first)
        #expect(hint.contains("TextRule.execute"), "\(hint)")
        #expect(hint.contains("\"TextRule.body\""), "\(hint)")
    }

    @Test func theSourcesReadAreThoseTheWalksImport() {
        let text = "import Foundation\n@testable import App\nimport struct Mapper.Rule\n// import Probe\nlet important = 1\n"
        #expect(ForwarderSource.imports(text) == ["Foundation", "App", "Mapper"])
    }

    /// Soundness review P1: a module a walk's code imports but that is not read (a remote dependency, or a path
    /// dependency outside the roots) may declare `extension TextRule { func execute() }`, which Swift picks over the
    /// forwarder. Its declarations are unknown, not zero, so the subject is kept.
    @Test func aModuleThatIsNotReadKeepsTheSubject() {
        let walk = "Prove(it: { TextRule(input: $0).execute() }, over: 0 ... 3) {"
        let (check, lines) = Self.walk(walk)
        let files = [
            "/p/App/Rule.swift": Self.rule, "/p/App/TextRule.swift": Self.textRule, "/p/App/Remote.swift": "import RemoteRules\n",
            "/p/ObjC/include/Plain.h": "@interface Plain : NSObject\n@end\n",
            "/p/ObjC/include/Category.h": "@interface NSObject (Run)\n- (int)execute;\n@end\n",
        ]
        let app = Check.SourceTarget(package: "/p", name: "App", files: ["/p/App/Rule.swift", "/p/App/TextRule.swift"])
        func resolved(_ test: String, targets: [Check.SourceTarget] = [app]) -> String {
            Check.resolvingForwarders(
                [check], testTexts: [test], scanned: ["App"], targets: targets,
                read: { $0 == check.file ? lines.joined(separator: "\n") : files[$0] }
            )[0].subject
        }
        let system = "import Foundation\nimport Testing\nimport SwiftFormalTesting\n@testable import App\n"
        #expect(resolved(system) == "TextRule.body")
        #expect(resolved(system + "import RemoteRules\n") == "TextRule.execute()")
        var importsRemote = app
        importsRemote.files.append("/p/App/Remote.swift")
        #expect(resolved(system, targets: [importsRemote]) == "TextRule.execute()")
        // An Objective-C target is read through its headers: a category may add `execute` to a class.
        let plain = Check.SourceTarget(package: "/p", name: "ObjC", files: ["/p/ObjC/include/Plain.h"])
        let category = Check.SourceTarget(package: "/p", name: "ObjC", files: ["/p/ObjC/include/Category.h"])
        #expect(resolved(system + "import ObjC\n", targets: [app, plain]) == "TextRule.body")
        #expect(resolved(system + "import ObjC\n", targets: [app, category]) == "TextRule.execute()")
        var unreadable = app
        unreadable.files.append("/p/App/Gone.swift")
        #expect(resolved(system, targets: [unreadable]) == "TextRule.execute()")
    }

    /// Soundness review P1: a `/*` inside a string or regex literal is not a comment, so the declarations after it
    /// count; a comment or literal that is not closed makes the file unknown, which keeps the subject.
    @Test func commentsAreStrippedOnlyOutsideLiteralsAndAnOpenOneKeepsTheSubject() {
        let walk = "Prove(it: { TextRule(input: $0).execute() }, over: 0 ... 3) {"
        let shadow = "\nextension TextRule { func execute() -> String { \"\" } }\n"
        for literal in [
            "let a = \"\"\"\n  /* in a string\n  \"\"\"",
            "let b = #\"\\\"# + \"/*\"",
            "let c = #/\\/*/#",
            "let d = \"\\(\"/*\")\"",
        ] {
            #expect(
                Self.resolved(walk, sources: [Self.rule, Self.textRule + "\n" + literal + shadow]) == "TextRule.execute()", "\(literal)")
            #expect(Self.resolved(walk, sources: [Self.rule, Self.textRule + "\n" + literal + "\n"]) == "TextRule.body", "\(literal)")
        }
        for open in ["/* not closed", "let e = \"\"\"\n not closed", "let f = \"not closed\n", "let g = #\"not closed\"\n", "func h() {"] {
            #expect(ForwarderSource.strippingComments(open) == nil, "\(open)")
            #expect(Self.resolved(walk, sources: [Self.rule, Self.textRule + "\n" + open]) == "TextRule.execute()", "\(open)")
        }
        #expect(ForwarderSource.strippingComments("/* a /* nested */ b */ let x = 1 // end") == "  let x = 1 ")
        #expect(
            Self.resolved(walk, sources: [Self.rule, Self.textRule, "extension TextRule { func `execute`() -> String { \"\" } }"])
                == "TextRule.execute()")
    }
}
