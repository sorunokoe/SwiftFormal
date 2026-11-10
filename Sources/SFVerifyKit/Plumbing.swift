/// Code that wires an app together rather than computing something: property wrappers and dependency injection
/// (SwiftUI, Observation, TCA, swift-dependencies, Factory), `@ObservableState` setters and the `body` of a view or
/// reducer. In app code most `unsupported` functions are of this kind (app study round 6), so the summary counts them as
/// their own group (`ScanReport.Summary.plumbing`). Only a count: no verdict depends on it.
enum Plumbing {
    /// Generic property wrappers and injection types: `Injected<AuthService>`, `Binding<String>`, `Store<S, A>`.
    private static let genericWrappers: Set = [
        "Injected", "LazyInjected", "WeakLazyInjected", "InjectedObject", "Factory", "Dependency", "Environment",
        "EnvironmentObject", "State", "StateObject", "ObservedObject", "Binding", "Bindable", "FocusState", "GestureState",
        "AppStorage", "SceneStorage", "Published", "Store", "StoreOf", "Shared", "SharedReader",
    ]
    /// Injection containers without generic arguments (Factory's `Container`, SwiftUI's `EnvironmentValues`).
    private static let containers: Set = ["Container", "EnvironmentValues", "DependencyValues", "Namespace"]

    /// Whether an unsupported, hand-written `function` is plumbing.
    static func isPlumbing(_ function: FunctionReport) -> Bool {
        // `var body: some View` (or `some Reducer`): a getter with an opaque result type named `body`.
        if function.symbol.hasSuffix("4bodyQrvg") { return true }
        let category = function.category ?? ""
        if category.hasPrefix("type ") {
            let type = category.dropFirst(5)
            let name = type.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            let rest = type.dropFirst(name.count)
            // `State<UnitSystem>` is SwiftUI's wrapper; a bare `State` or `MyStore.State` is a feature's own type.
            return (genericWrappers.contains(String(name)) && rest.hasPrefix("<")) || (containers.contains(String(name)) && rest.isEmpty)
        }
        return isObservableStateSetter(function)
    }

    /// A TCA `@ObservableState` setter: it stops at the identity comparison closure the registrar is given
    /// (`(T, T) -> Bool` made from the state), see KNOWN-ISSUES 10.
    private static func isObservableStateSetter(_ function: FunctionReport) -> Bool {
        guard function.name.hasSuffix(".setter") || function.name.hasSuffix(".modify"), let detail = function.detail else {
            return false
        }
        return detail.hasPrefix("UNSUPPORTED: apply:") && detail.contains("@callee_guaranteed (") && detail.hasSuffix("-> Bool")
    }
}
