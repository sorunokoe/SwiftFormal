// swift-syntax is a dependency only with the `Generator` trait (on by default): without it, `sfgen generate` says so.
#if Generator
    public import Foundation
    import SwiftParser
    import SwiftSyntax

    private typealias SyntaxVisitorContinuation = SyntaxVisitorContinueKind

    /// Reads Swift sources with swift-syntax and fills a `TypeIndex` with the app's own enums, structs and classes
    /// (cases, stored properties, initialisers), plus the list of `Rule`s.
    public final class SourceIndexer {
        public let index: TypeIndex
        /// The module of sources that are not inside a Swift package (the app target).
        public let appModule: String?
        public private(set) var rules: [RuleInfo] = []
        public private(set) var filesParsed = 0

        public init(index: TypeIndex, appModule: String? = nil) {
            self.index = index
            self.appModule = appModule
        }

        /// Directory of each Swift package target (from its `Package.swift`), with the target's name.
        private var targetRoots: [(directory: String, name: String)] = []

        /// A file belongs to the target whose directory contains it (longest match, from the `Package.swift`
        /// files already read); a file under `Packages/…/Sources/<Dir>` without a manifest falls back to `<Dir>`;
        /// anything else belongs to the app module.
        func moduleName(forPath path: String) -> String? {
            if let match = targetRoots.filter({ path.hasPrefix($0.directory + "/") }).max(by: { $0.directory.count < $1.directory.count }) {
                return match.name
            }
            let parts = path.split(separator: "/").map(String.init)
            if parts.contains("Packages"), let sources = parts.lastIndex(of: "Sources"), sources + 1 < parts.count - 1 {
                return parts[sources + 1]
            }
            return appModule
        }

        /// Reads the targets (name and optional `path:`) of a `Package.swift`.
        func registerManifest(_ text: String, directory: String) {
            let collector = TargetCollector(viewMode: .sourceAccurate)
            collector.walk(Parser.parse(source: text))
            for target in collector.targets {
                targetRoots.append((directory + "/" + (target.path ?? "Sources/\(target.name)"), target.name))
            }
        }

        private final class TargetCollector: SyntaxVisitor {
            var targets: [(name: String, path: String?)] = []

            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinuation {
                guard let callee = node.calledExpression.as(MemberAccessExprSyntax.self),
                    ["target", "executableTarget", "macro"].contains(callee.declName.baseName.text)
                else { return .visitChildren }
                func literal(_ label: String) -> String? {
                    node.arguments.first { $0.label?.text == label }?
                        .expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
                }
                if let name = literal("name") { targets.append((name, literal("path"))) }
                return .visitChildren
            }
        }

        public func indexDirectory(_ root: URL) {
            let skipped: Set<String> = [".build", "DerivedData", "Pods", "Carthage", "node_modules", ".git"]
            guard
                let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )
            else { return }
            var files: [URL] = []
            for case let url as URL in walker {
                if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                if url.pathExtension == "swift" { files.append(url) }
            }
            for url in files where url.lastPathComponent == "Package.swift" {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    registerManifest(text, directory: url.deletingLastPathComponent().path)
                }
            }
            for url in files.sorted(by: { $0.path < $1.path }) where url.lastPathComponent != "Package.swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                indexSource(text, path: url.path)
            }
        }

        public func indexSource(_ text: String, path: String, module: String? = nil) {
            let tree = Parser.parse(source: text)
            let visitor = Visitor(
                index: index, path: path, module: module ?? moduleName(forPath: path),
                converter: SourceLocationConverter(fileName: path, tree: tree)
            )
            visitor.walk(tree)
            rules.append(contentsOf: visitor.rules)
            filesParsed += 1
        }

        private final class Visitor: SyntaxVisitor {
            let index: TypeIndex
            let path: String
            let module: String?
            let converter: SourceLocationConverter
            var stack: [String] = []
            var rules: [RuleInfo] = []
            var imports: [String] = []

            init(index: TypeIndex, path: String, module: String?, converter: SourceLocationConverter) {
                self.index = index
                self.path = path
                self.module = module
                self.converter = converter
                super.init(viewMode: .sourceAccurate)
            }

            override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinuation {
                if let first = node.path.first?.name.text { imports.append(first) }
                return .skipChildren
            }

            override func visit(_: FunctionDeclSyntax) -> SyntaxVisitorContinuation { .skipChildren }
            override func visit(_: InitializerDeclSyntax) -> SyntaxVisitorContinuation { .skipChildren }
            override func visit(_: VariableDeclSyntax) -> SyntaxVisitorContinuation { .skipChildren }
            override func visit(_: SubscriptDeclSyntax) -> SyntaxVisitorContinuation { .skipChildren }

            // MARK: Declarations

            override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinuation {
                var info = begin(node.name.text, .enumeration, node.modifiers, node.genericParameterClause != nil)
                for member in node.memberBlock.members {
                    guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
                    for element in caseDecl.elements {
                        let params =
                            element.parameterClause?.parameters.map { parameter -> TypeParam in
                                let label = parameter.firstName.map(\.text).flatMap { $0 == "_" ? nil : $0 }
                                return TypeParam(label: label, type: parameter.type.trimmedDescription)
                            } ?? []
                        info.cases.append(TypeEnumCase(name: element.name.text, params: params))
                    }
                }
                finish(info, node.inheritanceClause)
                return .visitChildren
            }
            override func visitPost(_: EnumDeclSyntax) { stack.removeLast() }

            override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinuation {
                var info = begin(node.name.text, .structure, node.modifiers, node.genericParameterClause != nil)
                fillMembers(node.memberBlock, into: &info, memberwise: true)
                finish(info, node.inheritanceClause)
                if isRule(node.inheritanceClause) {
                    let literals = LiteralCollector(viewMode: .sourceAccurate)
                    literals.walk(node)
                    let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
                    rules.append(
                        RuleInfo(
                            name: info.name, file: path, line: location.line, isPrivate: info.isPrivate,
                            isGeneric: info.isGeneric, ints: literals.ints, doubles: literals.doubles, strings: literals.strings,
                            module: module, imports: imports
                        ))
                }
                return .visitChildren
            }
            override func visitPost(_: StructDeclSyntax) { stack.removeLast() }

            override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinuation {
                var info = begin(node.name.text, .classType, node.modifiers, node.genericParameterClause != nil)
                fillMembers(node.memberBlock, into: &info, memberwise: false)
                finish(info, node.inheritanceClause)
                return .visitChildren
            }
            override func visitPost(_: ClassDeclSyntax) { stack.removeLast() }

            override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinuation {
                finish(begin(node.name.text, .protocolType, node.modifiers, false), node.inheritanceClause)
                return .visitChildren
            }
            override func visitPost(_: ProtocolDeclSyntax) { stack.removeLast() }

            override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinuation {
                stack.append(node.extendedType.trimmedDescription)
                return .visitChildren
            }
            override func visitPost(_: ExtensionDeclSyntax) { stack.removeLast() }

            override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinuation {
                if node.genericParameterClause == nil {
                    index.aliases[(stack + [node.name.text]).joined(separator: ".")] = node.initializer.value.trimmedDescription
                }
                return .skipChildren
            }

            // MARK: Helpers

            /// Pushes the type's name and returns its (not yet stored) description.
            private func begin(_ name: String, _ kind: TypeKind, _ modifiers: DeclModifierListSyntax, _ generic: Bool) -> TypeInfo {
                stack.append(name)
                var info = TypeInfo(name: stack.joined(separator: "."), kind: kind)
                info.fromSource = true
                info.module = module
                info.isGeneric = generic
                info.isPrivate = modifiers.contains { modifier in
                    modifier.detail == nil && [.keyword(.private), .keyword(.fileprivate)].contains(modifier.name.tokenKind)
                }
                info.isPublic = modifiers.contains { [.keyword(.public), .keyword(.open)].contains($0.name.tokenKind) }
                return info
            }

            private func finish(_ info: TypeInfo, _ inheritance: InheritanceClauseSyntax?) {
                index.add(info)
                for inherited in inheritance?.inheritedTypes ?? [] {
                    index.addSubtype(info.name, of: inherited.type.trimmedDescription)
                }
            }

            private func isRule(_ inheritance: InheritanceClauseSyntax?) -> Bool {
                (inheritance?.inheritedTypes ?? []).contains { inherited in
                    let text = inherited.type.trimmedDescription
                    return text == "Rule" || text.hasSuffix(".Rule") || text.hasPrefix("Rule<")
                }
            }

            private func fillMembers(_ block: MemberBlockSyntax, into info: inout TypeInfo, memberwise: Bool) {
                var memberwiseParams: [TypeParam] = []
                var explicitInits: [[TypeParam]] = []
                var internalInits: [[TypeParam]] = []
                for member in block.members {
                    if let variable = member.decl.as(VariableDeclSyntax.self) {
                        let isStatic = variable.modifiers.contains {
                            [.keyword(.static), .keyword(.class)].contains($0.name.tokenKind)
                        }
                        if isStatic { continue }
                        let hasWrapper = variable.attributes.contains { attribute in
                            guard let name = attribute.as(AttributeSyntax.self)?.attributeName.trimmedDescription else { return false }
                            return !["MainActor", "available", "usableFromInline", "inlinable", "nonisolated", "objc"].contains(name)
                        }
                        let isPrivateSet = variable.modifiers.contains { $0.detail != nil }
                        let isPrivate =
                            !isPrivateSet
                            && variable.modifiers.contains {
                                [.keyword(.private), .keyword(.fileprivate)].contains($0.name.tokenKind)
                            }
                        for binding in variable.bindings where binding.accessorBlock == nil {
                            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                            let hasDefault = binding.initializer != nil
                            if hasWrapper { info.unsupported = "property wrapper on \(pattern.identifier.text)"; continue }
                            guard let type = binding.typeAnnotation?.type.trimmedDescription else {
                                if !hasDefault { info.unsupported = "untyped stored property \(pattern.identifier.text)" }
                                continue
                            }
                            if hasDefault { continue }
                            if isPrivate { info.unsupported = "private stored property \(pattern.identifier.text)"; continue }
                            memberwiseParams.append(TypeParam(label: pattern.identifier.text, type: type))
                        }
                    } else if let initializer = member.decl.as(InitializerDeclSyntax.self) {
                        let isPrivate = initializer.modifiers.contains {
                            [.keyword(.private), .keyword(.fileprivate)].contains($0.name.tokenKind)
                        }
                        let throwing = initializer.signature.effectSpecifiers?.throwsClause != nil
                        guard initializer.optionalMark == nil, !isPrivate, !throwing, initializer.genericParameterClause == nil
                        else { continue }
                        let params = initializer.signature.parameterClause.parameters
                        if params.contains(where: { $0.ellipsis != nil }) { continue }
                        let isPublic = initializer.modifiers.contains { [.keyword(.public), .keyword(.open)].contains($0.name.tokenKind) }
                        let parameters = params.map {
                            TypeParam(label: $0.firstName.text == "_" ? nil : $0.firstName.text, type: $0.type.trimmedDescription)
                        }
                        if isPublic { explicitInits.append(parameters) } else { internalInits.append(parameters) }
                    }
                }
                if !explicitInits.isEmpty || !internalInits.isEmpty {
                    info.inits = explicitInits
                    info.internalOnlyInits = internalInits
                } else if memberwise {
                    info.internalOnlyInits = [memberwiseParams]
                }
            }
        }

        private final class LiteralCollector: SyntaxVisitor {
            var ints: [Int] = []
            var doubles: [Double] = []
            var strings: [String] = []

            override func visit(_ node: IntegerLiteralExprSyntax) -> SyntaxVisitorContinuation {
                let text = node.literal.text.replacingOccurrences(of: "_", with: "")
                let value: Int? =
                    if text.hasPrefix("0x") { Int(text.dropFirst(2), radix: 16) } else if text.hasPrefix("0b") {
                        Int(text.dropFirst(2), radix: 2)
                    } else { Int(text) }
                if let value, abs(value) < 1_000_000_000, !ints.contains(value) { ints.append(value) }
                return .skipChildren
            }

            override func visit(_ node: FloatLiteralExprSyntax) -> SyntaxVisitorContinuation {
                if let value = Double(node.literal.text.replacingOccurrences(of: "_", with: "")), value.isFinite, abs(value) < 1e9,
                    !doubles.contains(value)
                {
                    doubles.append(value)
                }
                return .skipChildren
            }

            override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinuation {
                var text = ""
                for segment in node.segments {
                    guard let plain = segment.as(StringSegmentSyntax.self) else { return .skipChildren }
                    text += plain.content.text
                }
                if text.count <= 40, !text.contains("\\"), !strings.contains(text) { strings.append(text) }
                return .skipChildren
            }
        }
    }
#endif
