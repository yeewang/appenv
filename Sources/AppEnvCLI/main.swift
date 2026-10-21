import AppEnvCore
import Foundation
import Darwin

@main struct CLI {
    static let help = """
    AppEnv — independent native app profiles (macOS 14+)

    appenv create NAME
    appenv list [--json]
    appenv add --env NAME --app chrome|vscode|codex [--path /path/App.app]
    appenv run --env NAME --app chrome|vscode|codex [--allow-version-change]
    appenv stop NAME [--app chrome|vscode|codex] [--force]
    appenv rename NAME NEW_NAME
    appenv duplicate NAME NEW_NAME
    appenv export NAME /absolute/path/backup.zip
    appenv delete NAME --yes
    appenv path NAME

    APPENV_HOME overrides storage. APPENV selects the default for add/run.
    Example: export APPENV=work; appenv run --app chrome
    Native profiles share your macOS account, Keychain and system permissions.
    Exports may contain signed-in sessions; store them privately.
    """
    @MainActor static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch { fputs("appenv: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first, !["help", "--help", "-h"].contains(command) else { print(help); return }
        var positional: [String] = [], options: [String: String] = [:], flags = Set<String>()
        let valueOptions: Set<String> = ["--env", "--app", "--path"]
        let boolOptions: Set<String> = ["--json", "--force", "--yes", "--allow-version-change"]
        var i = 1
        while i < arguments.count {
            let value = arguments[i]
            if valueOptions.contains(value) {
                i += 1
                guard i < arguments.count, !arguments[i].hasPrefix("--"), options[value] == nil else { throw AppEnvError("Missing or repeated option: \(value)") }
                options[value] = arguments[i]
            } else if boolOptions.contains(value) { flags.insert(value) }
            else if value.hasPrefix("--") { throw AppEnvError("Unknown option: \(value)") }
            else { positional.append(value) }
            i += 1
        }
        func require(_ count: Int) throws {
            guard positional.count == count else { throw AppEnvError("Wrong number of arguments. Run appenv --help.") }
        }
        func env() throws -> String {
            guard let name = options["--env"] ?? ProcessInfo.processInfo.environment["APPENV"], !name.isEmpty else { throw AppEnvError("Specify --env NAME or set APPENV.") }
            return name
        }
        func adapter() throws -> Adapter {
            guard let name = options["--app"], let adapter = Adapter.resolve(name) else { throw AppEnvError("Specify --app chrome, --app vscode, or --app codex.") }
            return adapter
        }
        let allowed: [String: Set<String>] = [
            "create": [], "list": ["--json"], "add": ["--env", "--app", "--path"],
            "run": ["--env", "--app", "--allow-version-change"], "stop": ["--app", "--force"],
            "rename": [], "duplicate": [], "export": [], "delete": ["--yes"], "path": []
        ]
        guard let supported = allowed[command] else { throw AppEnvError("Unknown command: \(command)") }
        guard Set(options.keys).union(flags).isSubset(of: supported) else { throw AppEnvError("This command does not support the supplied options.") }
        let store = try Store()
        switch command {
        case "create":
            try require(1); let result = try store.create(positional[0]); print("Created \(result.name) (\(result.id))")
        case "list":
            try require(0); let environments = try store.list()
            if flags.contains("--json") {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(environments), as: UTF8.self))
            } else {
                if environments.isEmpty { print("No environments. Use appenv create NAME.") }
                for env in environments {
                    print("\(env.name)\t\(env.isRunning ? "running" : "stopped")\t\(env.id)")
                    for app in env.apps { print("  \(app.adapter.name)\t\(app.instance.map { "PID \($0.pid)" } ?? "stopped")") }
                }
            }
        case "add":
            try require(0); try store.add(env(), adapter: adapter(), url: options["--path"].map { URL(fileURLWithPath: $0) }); print("Application added.")
        case "run":
            try require(0); let name = try env(), app = try adapter()
            if try !store.environment(name).apps.contains(where: { $0.adapter == app }) { try store.add(name, adapter: app) }
            let instance = try await store.launch(name, adapter: app, allowVersionChange: flags.contains("--allow-version-change"))
            print("\(app.name) · \(name) · PID \(instance.pid)")
        case "stop":
            try require(1)
            try await store.stop(positional[0], adapter: options["--app"] == nil ? nil : adapter(), force: flags.contains("--force")); print("Stopped.")
        case "rename": try require(2); try store.rename(positional[0], to: positional[1]); print("Renamed.")
        case "duplicate": try require(2); let env = try store.duplicate(positional[0], name: positional[1]); print("Created \(env.name).")
        case "export":
            try require(2); try store.export(positional[0], to: URL(fileURLWithPath: positional[1])); print("Exported to \(positional[1]).")
        case "delete":
            try require(1); guard flags.contains("--yes") else { throw AppEnvError("Deletion moves profile data to Trash. Pass --yes to confirm.") }
            try store.delete(positional[0]); print("Moved environment data to Trash.")
        case "path": try require(1); print(store.directory(try store.environment(positional[0]).id).path)
        default: break
        }
    }
}
