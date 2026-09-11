import Foundation

enum AccountLoginPhase { case waiting, saving }
enum AccountLoginError: Error { case invalidCredentials, importUnconfirmed }

enum AccountLogin {
    // Resolve the native CLI, including npm's launcher layout. Owning the actual
    // login process lets cancellation stop its localhost listener, without an
    // orphaned Node child continuing to accept credentials after cancellation.
    static func findCodex(candidates: [URL]? = nil) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path,
                     home.appendingPathComponent(".cargo/bin").path] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for candidate in candidates ?? paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("codex") }) {
            let resolved = candidate.resolvingSymlinksInPath()
            if isNativeExecutable(resolved) { return resolved }
            guard resolved.lastPathComponent == "codex.js" else { continue }
            let package = resolved.deletingLastPathComponent().deletingLastPathComponent()
            #if arch(arm64)
            let platform = "codex-darwin-arm64", triple = "aarch64-apple-darwin"
            #else
            let platform = "codex-darwin-x64", triple = "x86_64-apple-darwin"
            #endif
            // npm can nest optional platform dependencies or hoist them beside
            // @openai/codex. Older distributions kept vendor inside that package.
            let roots = [package.appendingPathComponent("node_modules/@openai/" + platform),
                         package.deletingLastPathComponent().appendingPathComponent(platform), package]
            for root in roots {
                for suffix in ["bin/codex", "codex/codex"] {
                    let binary = root.appendingPathComponent("vendor/" + triple + "/" + suffix)
                    if isNativeExecutable(binary) { return binary }
                }
            }
        }
        return nil
    }

    private static func isNativeExecutable(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path), let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 4) else { return false }
        return [[0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf],
                [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
                [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca]].contains(Array(bytes))
    }

    static func add(codex: URL, importer: URL, home: URL, proxy: Bool,
                    temporaryRoot: URL = FileManager.default.temporaryDirectory, timeout: Double = 300,
                    willImport: @MainActor () -> Void) async throws -> String {
        try Task.checkCancellation()
        let scratch = temporaryRoot.appendingPathComponent("codex-auth-login-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let runner = CommandRunner()
        // Official browser OAuth owns PKCE, callback validation and token exchange.
        // Force file storage in a private home; never sign into the shared keychain
        // or overwrite the currently selected auth.json just to add a saved account.
        try await runner.run(executable: codex, arguments: ["login", "-c", "cli_auth_credentials_store=\"file\""],
                             home: scratch, proxy: proxy, timeout: timeout, workingDirectory: scratch)
        try Task.checkCancellation()
        let auth = scratch.appendingPathComponent("auth.json")
        guard let metadata = LocalData.metadata(at: auth) else { throw AccountLoginError.invalidCredentials }
        await willImport()
        try Task.checkCancellation()
        try await runner.run(executable: importer, arguments: ["import", auth.path], home: home, proxy: proxy)
        let registry = try LocalData.registry(home: home)
        guard registry.accounts.contains(where: { $0.id == metadata.key }) else { throw AccountLoginError.importUnconfirmed }
        return metadata.key
    }
}
