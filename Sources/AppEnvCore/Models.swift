import Foundation

public struct AppEnvError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Adapter: String, Codable, CaseIterable, Identifiable {
    case chrome, vscode
    public var id: String { rawValue }
    public var name: String { self == .chrome ? "Google Chrome" : "Visual Studio Code" }
    public var bundleID: String { self == .chrome ? "com.google.Chrome" : "com.microsoft.VSCode" }
    public var teamID: String { self == .chrome ? "EQHXZ8M8AV" : "UBF8T346G9" }
    public var defaultURL: URL { URL(fileURLWithPath: "/Applications/\(name).app") }
    public var installedURL: URL? {
        [defaultURL, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(name).app")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
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
