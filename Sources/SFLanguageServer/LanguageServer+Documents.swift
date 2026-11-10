import Foundation

// Documents, files and settings: every change bumps the generation, and the verdicts it may affect turn stale at
// once. Saving a file starts a check (with `checkOn: save`).
extension LanguageServer {
    func didOpen(_ params: JSONValue) {
        let item = params["textDocument"]
        guard let uri = item["uri"].string, let path = Paths.path(uri: uri), let text = item["text"].string else { return }
        documents[path] = Document(uri: uri, version: item["version"].int, text: text, hash: InputSnapshot.digest(Data(text.utf8)))
        publishDiagnostics([path])
    }

    func didChange(_ params: JSONValue) {
        let item = params["textDocument"]
        guard let uri = item["uri"].string, let path = Paths.path(uri: uri), var document = documents[path] else { return }
        // Full sync: the last change without a range is the whole text.
        guard let text = params["contentChanges"].array?.last(where: { $0["range"].isNull })?["text"].string else { return }
        document.text = text
        document.version = item["version"].int
        document.hash = InputSnapshot.digest(Data(text.utf8))
        documents[path] = document
        changed(paths: [path])
    }

    func didSave(_ params: JSONValue) {
        guard let uri = params["textDocument"]["uri"].string, let path = Paths.path(uri: uri) else { return }
        // Saving the bytes the server last counted changes no verdict: what an edit turned stale stays stale.
        let hash = diskHash(path)
        if hash == nil || hash != acknowledgedHashes[path] { changed(paths: [path]) }
        acknowledgedHashes[path] = hash
        guard let config = config(for: path), config.checkOn == .save, path.hasSuffix(".swift") || isManifest(path) else { return }
        schedule(for: path, config: config)
    }

    func didClose(_ params: JSONValue) {
        guard let uri = params["textDocument"]["uri"].string, let path = Paths.path(uri: uri) else { return }
        documents[path] = nil
        publishDiagnostics([path])
    }

    /// Files changed on disk (another editor, `git`, a generator). Only verdicts turn stale; nothing is checked.
    func didChangeWatchedFiles(_ params: JSONValue) {
        var paths: Set<String> = []
        for change in params["changes"].array ?? [] {
            guard let path = change["uri"].string.flatMap(Paths.path(uri:)), !Paths.isIgnored(path, roots: roots) else { continue }
            // A save the server already counted reports the same bytes again.
            diskHashes[path] = nil
            let hash = diskHash(path)
            if change["type"].int == 2, let hash, hash == acknowledgedHashes[path] { continue }
            acknowledgedHashes[path] = hash
            paths.insert(path)
        }
        if !paths.isEmpty { changed(paths: paths) }
    }

    func didChangeConfiguration(_ params: JSONValue) {
        let value = params["settings"]
        settings = value["swiftformal"].isNull ? value : value["swiftformal"]
        reportedConfigError = nil
        changed(scope: .everything)
    }

    func didChangeWorkspaceFolders(_ params: JSONValue) {
        let event = params["event"]
        let removed = Set((event["removed"].array ?? []).compactMap { $0["uri"].string.flatMap(Paths.path(uri:)) })
        roots.removeAll { removed.contains($0) }
        for added in (event["added"].array ?? []).compactMap({ $0["uri"].string.flatMap(Paths.path(uri:)) }) where !roots.contains(added) {
            roots.append(added)
        }
        changed(scope: .everything)
    }

    func cancelProgress(_ params: JSONValue) {
        guard let token = params["token"].string, let active = scheduler.active, progressTokens[active.id] == token else { return }
        scheduler.cancelAll()
    }

    // MARK: staleness

    /// What a change to `path` may affect: its package, or everything for a manifest, the configuration, or a file
    /// outside any package. Nil for build products and other folders no check reads.
    func scope(of path: String) -> ChangeScope? {
        guard !Paths.isIgnored(path, roots: roots) else { return nil }
        if isManifest(path) || (path as NSString).lastPathComponent == "swiftformal.json" { return .everything }
        guard let root = Paths.packageRoot(of: path) else { return .everything }
        return .packages([root])
    }

    func isManifest(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix("Package.")
    }

    func changed(paths: Set<String>) {
        let scopes = paths.compactMap(scope(of:))
        guard let first = scopes.first else { return }
        changed(scope: scopes.dropFirst().reduce(first) { $0.union($1) })
    }

    /// Records the change; when verdicts turned stale, the editor shows it at once.
    func changed(scope: ChangeScope) {
        let staled = store.change(scope)
        // Only a running check needs the change log (to keep what it finds stale).
        if scheduler.active == nil { store.pruneEvents(upTo: store.generation) }
        if staled > 0 { refreshViews() }
    }

    /// SHA-256 of the file on disk, read again only when its signature changed.
    func diskHash(_ path: String) -> String? {
        guard let signature = InputSnapshot.signature(path) else {
            diskHashes[path] = nil
            return nil
        }
        if let known = diskHashes[path], known.signature == signature { return known.hash }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let hash = InputSnapshot.digest(data)
        diskHashes[path] = (signature, hash)
        return hash
    }

    /// The hash a verdict about `path` must match: the open buffer's, else the file's on disk.
    func currentHash(_ path: String) -> String? {
        documents[path]?.hash ?? diskHash(path)
    }

    /// The text of `path`: the open buffer, else the file on disk.
    func currentText(_ path: String) -> String? {
        documents[path]?.text ?? (try? String(contentsOfFile: path, encoding: .utf8))
    }

    // MARK: configuration

    /// The workspace folder that holds `path` (the deepest), else its package, else its folder.
    func workspaceRoot(of path: String) -> String {
        roots.filter { Paths.isInside(path, $0) }.max { $0.count < $1.count }
            ?? Paths.packageRoot(of: path) ?? (path as NSString).deletingLastPathComponent
    }

    /// The settings, with `<root>/swiftformal.json` over them. Nil (and one message) when either is not valid.
    func config(forRoot root: String) -> ServerConfig? {
        do {
            var config = try ServerConfig.parse(settings, base: root)
            if let file = try ServerConfig.file(root: root) { config = try ServerConfig.parse(file, base: root, defaults: config) }
            return config
        } catch {
            let message = "\(error)"
            if reportedConfigError != message {
                reportedConfigError = message
                show("the configuration is not valid, so nothing is checked: \(message)", type: 1)
            }
            return nil
        }
    }

    func config(for path: String) -> ServerConfig? { config(forRoot: workspaceRoot(of: path)) }
}
