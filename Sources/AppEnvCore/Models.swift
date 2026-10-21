import Foundation

public struct AppEnvError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Adapter: String, Codable, CaseIterable, Identifiable {
    case chrome, vscode, codex
    public var id: String { rawValue }
    public var name: String {
        switch self { case .chrome: return "Google Chrome"; case .vscode: return "Visual Studio Code"; case .codex: return "Codex" }
    }
    public var bundleID: String {
        switch self { case .chrome: return "com.google.Chrome"; case .vscode: return "com.microsoft.VSCode"; case .codex: return "com.openai.codex" }
    }
    public var teamID: String {
        switch self { case .chrome: return "EQHXZ8M8AV"; case .vscode: return "UBF8T346G9"; case .codex: return "2DC432GLL2" }
    }
    public static var supportedNames: String { allCases.map(\.name).joined(separator: ", ") }
    public var defaultURL: URL { URL(fileURLWithPath: "/Applications/\(name).app") }
    public var installedURL: URL? {
        let names = self == .codex ? ["Codex", "ChatGPT"] : [name]
        let directories = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        return directories.flatMap { directory in names.map { directory.appendingPathComponent("\($0).app") } }
            .first { Bundle(url: $0)?.bundleIdentifier == bundleID }
    }
    public static func resolve(_ value: String) -> Adapter? {
        allCases.first { [$0.rawValue, $0.name, $0.bundleID].contains { $0.caseInsensitiveCompare(value) == .orderedSame } }
    }
    public func arguments(data: URL) -> [String] {
        switch self {
        case .chrome:
            return ["--user-data-dir=\(data.appendingPathComponent("profile").path)", "--no-first-run", "--no-default-browser-check"]
        case .vscode:
            return ["--user-data-dir", data.appendingPathComponent("user-data").path,
                    "--extensions-dir", data.appendingPathComponent("extensions").path, "--new-window"]
        case .codex:
            return ["--user-data-dir=\(data.appendingPathComponent("user-data").path)"]
        }
    }
    public func environment(data: URL) -> [String: String] {
        guard self == .codex else { return [:] }
        return ["CODEX_HOME": data.appendingPathComponent("codex-home").path,
                "CODEX_ELECTRON_USER_DATA_PATH": data.appendingPathComponent("user-data").path]
    }
    public func readinessFiles(data: URL) -> [URL] {
        switch self {
        case .chrome: return [data.appendingPathComponent("profile/Local State")]
        case .vscode: return [data.appendingPathComponent("user-data/User")]
        case .codex: return [data.appendingPathComponent("user-data/Local State"), data.appendingPathComponent("codex-home/.codex-global-state.json")]
        }
    }
}

public struct Instance: Codable, Equatable {
    public var pid: Int32
    public var launchedAt: Date
    public var executablePath: String
}

public struct AppBinding: Codable, Identifiable {
    public var adapter: Adapter
    public var path: String
    public var lastVersion: String?
    public var instance: Instance?
    public var id: String { adapter.rawValue }
    public init(adapter: Adapter, path: String) { self.adapter = adapter; self.path = path }
}

public struct Environment: Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var apps: [AppBinding]
    public init(name: String, apps: [AppBinding] = []) {
        id = UUID(); self.name = name; createdAt = Date(); self.apps = apps
    }
    public var isRunning: Bool { apps.contains { $0.instance != nil } }
}

struct Registry: Codable {
    var schemaVersion = 1
    var environments: [Environment] = []
}
