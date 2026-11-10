import Foundation
import SFVerifyKit

/// The `swiftformal lsp` server: proves on save, and shows each function's verdict as a code lens, a diagnostic and a
/// hover, next to sourcekit-lsp (which it never replaces).
///
/// Everything runs on one serial queue. Checks run one at a time through `RunScheduler`; each records the generation
/// it started at, and `ResultStore` keeps its answers stale when the code changed after that. A verdict is shown as
/// proved only when it is current: nothing it depends on changed since its check started, and the file's text is
/// the text that check read.
package final class LanguageServer: @unchecked Sendable {
    /// An open document, as the editor has it.
    package struct Document: Sendable {
        package var uri: String
        package var version: Int?
        package var text: String
        /// SHA-256 of `text` (UTF-8).
        package var hash: String
    }

    /// What the client said it can do.
    package struct ClientSupport: Sendable {
        package var workDoneProgress = false
        package var codeLensRefresh = false
        package var watchedFilesRegistration = false
        package var documentChanges = false
        package var createFiles = false
    }

    /// Commands the server runs (`workspace/executeCommand`).
    package enum Command {
        /// Check the configured targets, or the targets of the open files.
        package static let check = "swiftformal.server.check"
        /// Stop the running check and drop the queued one.
        package static let cancel = "swiftformal.server.cancel"
    }

    let queue = DispatchQueue(label: "swiftformal.lsp")
    let send: @Sendable (RPCMessage) -> Void
    let manifests: ManifestCache
    let store = ResultStore()
    var scheduler: RunScheduler!  // swiftlint:disable:this implicitly_unwrapped_optional
    package internal(set) var documents: [String: Document] = [:]
    var roots: [String] = []
    var settings: JSONValue = .null
    var support = ClientSupport()
    var initialized = false
    var shuttingDown = false
    var shutdownReply: RequestID?
    var exitWaiting = false
    let onExit: @Sendable (Int32) -> Void
    var nextRequest = 1
    var progressTokens: [Int: String] = [:]
    /// SHA-256 of files on disk, by their signature, so a watched-file event that changed nothing is ignored.
    var diskHashes: [String: (signature: InputSnapshot.Signature, hash: String)] = [:]
    /// Each file's bytes on disk when the server last counted a change to it (a save or a watched change): a later
    /// save or watched event with the same bytes changes nothing. Other reads of the disk never update it, so a change
    /// nobody reported is still counted when it is reported.
    var acknowledgedHashes: [String: String] = [:]
    /// Files this server published diagnostics for, to clear them when they go away.
    var publishedDiagnostics: Set<String> = []
    var reportedConfigError: String?

    /// - Parameters:
    ///   - runner: starts checks (`ProcessCheckRunner` in the CLI; a fake in tests).
    ///   - send: writes a message to the client; called on the server's queue.
    ///   - onExit: called once, after `exit`, when no check runs any more, with the process's exit status.
    package init(
        runner: any CheckRunner, manifests: ManifestCache, send: @escaping @Sendable (RPCMessage) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.send = send
        self.manifests = manifests
        self.onExit = onExit
        let queue = queue
        scheduler = RunScheduler(
            runner: runner, generation: { [unowned self] in store.generation }, post: { work in queue.async(execute: work) },
            progress: { [unowned self] id, text in queue.async { self.runProgress(id: id, text) } })
        scheduler.onStart = { [unowned self] in runStarted($0) }
        scheduler.onEnd = { [unowned self] in runEnded($0, $1) }
    }

    /// Handles one message from the client, later, on the server's queue.
    package func receive(_ message: RPCMessage) {
        queue.async { self.handle(message) }
    }

    /// Runs `work` on the server's queue and waits for it (tests read state with it).
    package func sync<T>(_ work: () -> T) -> T { queue.sync(execute: work) }

    /// The stored verdicts (tests).
    package var resultStore: ResultStore { store }

    // MARK: dispatch

    func handle(_ message: RPCMessage) {
        switch message {
        case .request(let id, let method, let params):
            guard initialized || method == "initialize" else {
                return send(.errorResponse(id: id, code: RPCMessage.ErrorCode.serverNotInitialized, message: "not initialized"))
            }
            guard !shuttingDown || method == "shutdown" else {
                return send(.errorResponse(id: id, code: RPCMessage.ErrorCode.invalidRequest, message: "shutting down"))
            }
            request(id: id, method: method, params: params)
        case .notification(let method, let params):
            guard initialized || method == "exit" else { return }
            notification(method: method, params: params)
        case .response, .errorResponse:
            break
        }
    }

    private func request(id: RequestID, method: String, params: JSONValue) {
        switch method {
        case "initialize": send(.response(id: id, result: initialize(params)))
        case "shutdown": shutdown(id)
        case "textDocument/codeLens": send(.response(id: id, result: codeLenses(params)))
        case "textDocument/hover": send(.response(id: id, result: hover(params)))
        case "textDocument/codeAction": send(.response(id: id, result: codeActions(params)))
        case "workspace/executeCommand": send(.response(id: id, result: execute(params)))
        default: send(.errorResponse(id: id, code: RPCMessage.ErrorCode.methodNotFound, message: "unknown method \(method)"))
        }
    }

    private func notification(method: String, params: JSONValue) {
        switch method {
        case "initialized": registerWatchers()
        case "exit": exit()
        case _ where method.hasPrefix("textDocument/"): documentNotification(method: method, params: params)
        case "workspace/didChangeWatchedFiles": didChangeWatchedFiles(params)
        case "workspace/didChangeConfiguration": didChangeConfiguration(params)
        case "workspace/didChangeWorkspaceFolders": didChangeWorkspaceFolders(params)
        case "window/workDoneProgress/cancel": cancelProgress(params)
        default: break
        }
    }

    private func documentNotification(method: String, params: JSONValue) {
        switch method {
        case "textDocument/didOpen": didOpen(params)
        case "textDocument/didChange": didChange(params)
        case "textDocument/didSave": didSave(params)
        case "textDocument/didClose": didClose(params)
        default: break
        }
    }

    // MARK: lifecycle

    private func initialize(_ params: JSONValue) -> JSONValue {
        initialized = true
        let capabilities = params["capabilities"]
        support.workDoneProgress = capabilities["window"]["workDoneProgress"].bool ?? false
        support.codeLensRefresh = capabilities["workspace"]["codeLens"]["refreshSupport"].bool ?? false
        support.watchedFilesRegistration = capabilities["workspace"]["didChangeWatchedFiles"]["dynamicRegistration"].bool ?? false
        support.documentChanges = capabilities["workspace"]["workspaceEdit"]["documentChanges"].bool ?? false
        support.createFiles = (capabilities["workspace"]["workspaceEdit"]["resourceOperations"].array ?? []).contains("create")
        if let folders = params["workspaceFolders"].array {
            roots = folders.compactMap { $0["uri"].string.flatMap(Paths.path(uri:)) }
        }
        if roots.isEmpty, let root = params["rootUri"].string.flatMap(Paths.path(uri:)) { roots = [root] }
        if roots.isEmpty, let root = params["rootPath"].string { roots = [Paths.standard(root)] }
        settings = params["initializationOptions"]
        return [
            "capabilities": [
                "textDocumentSync": ["openClose": true, "change": 1, "save": ["includeText": false]],
                "codeLensProvider": ["resolveProvider": false],
                "hoverProvider": true,
                "codeActionProvider": ["codeActionKinds": ["quickfix", "refactor"]],
                "executeCommandProvider": ["commands": [.string(Command.check), .string(Command.cancel)]],
                "workspace": ["workspaceFolders": ["supported": true, "changeNotifications": true]],
            ],
            "serverInfo": ["name": "swiftformal"],
        ]
    }

    private func registerWatchers() {
        guard support.watchedFilesRegistration else { return }
        let globs = ["**/*.swift", "**/Package.swift", "**/Package.resolved", "**/swiftformal.json", "**/*.h", "**/*.modulemap"]
        let watchers: [JSONValue] = globs.map { ["globPattern": .string($0)] }
        sendRequest(
            "client/registerCapability",
            [
                "registrations": [
                    [
                        "id": "swiftformal-watched-files", "method": "workspace/didChangeWatchedFiles",
                        "registerOptions": ["watchers": .array(watchers)],
                    ]
                ]
            ])
    }

    private func shutdown(_ id: RequestID) {
        shuttingDown = true
        scheduler.cancelAll()
        if scheduler.isBusy { shutdownReply = id } else { send(.response(id: id, result: .null)) }
    }

    private func exit() {
        scheduler.cancelAll()
        if scheduler.isBusy { exitWaiting = true } else { onExit(shuttingDown ? 0 : 1) }
    }

    /// Called when a run ends: answers a waiting `shutdown` and finishes a waiting `exit`.
    func finishShutdownIfIdle() {
        guard !scheduler.isBusy else { return }
        if let id = shutdownReply {
            shutdownReply = nil
            send(.response(id: id, result: .null))
        }
        if exitWaiting {
            exitWaiting = false
            onExit(shuttingDown ? 0 : 1)
        }
    }

    // MARK: sending

    func sendRequest(_ method: String, _ params: JSONValue) {
        let id = RequestID.number(nextRequest)
        nextRequest += 1
        send(.request(id: id, method: method, params: params))
    }

    func notify(_ method: String, _ params: JSONValue) {
        send(.notification(method: method, params: params))
    }

    /// `window/showMessage` (1 error, 2 warning, 3 info) and the same text in the log.
    func show(_ message: String, type: Int) {
        notify("window/showMessage", ["type": .number(Double(type)), "message": .string("SwiftFormal: " + message)])
        log(message)
    }

    func log(_ message: String) {
        notify("window/logMessage", ["type": 4, "message": .string(message)])
    }
}
