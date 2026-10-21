import AppKit
import Darwin
import Security
import CryptoKit

// Each mutation holds a nonblocking filesystem lock shared by GUI and CLI.
// Never overwrite an unreadable registry or silently discard its state.
public final class Store {
    public let root: URL
    private let fm = FileManager.default
    private var registryURL: URL { root.appendingPathComponent("registry.json") }

    public init(root: URL? = nil) throws {
        self.root = root ?? ProcessInfo.processInfo.environment["APPENV_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AppEnv")
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: self.root.appendingPathComponent("environments"), withIntermediateDirectories: true)
    }

    private func lock() throws -> Int32 {
        let fd = Darwin.open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AppEnvError("Cannot open the environment lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw AppEnvError("Another AppEnv operation is in progress. Try again shortly.")
        }
        return fd
    }
    private func unlock(_ fd: Int32) { flock(fd, LOCK_UN); close(fd) }
    private func read() throws -> Registry {
        guard fm.fileExists(atPath: registryURL.path) else { return Registry() }
        let registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: registryURL))
        guard registry.schemaVersion == 1 else { throw AppEnvError("This registry needs a newer version of AppEnv.") }
        return registry
    }
    private func save(_ registry: Registry) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: registryURL, options: .atomic)
    }
    private func transaction<T>(_ action: (inout Registry) throws -> T) throws -> T {
        let fd = try lock(); defer { unlock(fd) }
        var registry = try read()
        reconcile(&registry)
        let result = try action(&registry)
        try save(registry)
        return result
    }
    public func directory(_ id: UUID) -> URL { root.appendingPathComponent("environments/\(id.uuidString)") }
    public func appDirectory(_ id: UUID, _ adapter: Adapter) -> URL {
        directory(id).appendingPathComponent("apps/\(adapter.bundleID)")
    }
    private func index(_ registry: Registry, _ selector: String) throws -> Int {
        guard let i = registry.environments.firstIndex(where: {
            $0.id.uuidString.caseInsensitiveCompare(selector) == .orderedSame || $0.name.caseInsensitiveCompare(selector) == .orderedSame
        }) else { throw AppEnvError("Environment ‘\(selector)’ does not exist.") }
        return i
    }
    private func validateName(_ name: String, _ registry: Registry, excluding: UUID? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AppEnvError("Use a name between 1 and 80 characters without control characters.")
        }
        guard !registry.environments.contains(where: { $0.id != excluding && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw AppEnvError("An environment named ‘\(name)’ already exists.")
        }
        return name
    }
    public func list() throws -> [Environment] { try transaction { $0.environments } }
    public func environment(_ selector: String) throws -> Environment {
        try transaction { $0.environments[try index($0, selector)] }
    }
    @discardableResult public func create(_ name: String) throws -> Environment {
        try transaction { registry in
            let env = Environment(name: try validateName(name, registry))
            try fm.createDirectory(at: directory(env.id), withIntermediateDirectories: true)
            registry.environments.append(env)
            return env
        }
    }
    public func rename(_ selector: String, to name: String) throws {
        try transaction { registry in
            let i = try index(registry, selector)
            registry.environments[i].name = try validateName(name, registry, excluding: registry.environments[i].id)
        }
    }
    public func add(_ selector: String, adapter: Adapter, url: URL? = nil) throws {
        let path = url ?? adapter.installedURL ?? adapter.defaultURL
        _ = try validateApplication(adapter, path)
        try transaction { registry in
            let i = try index(registry, selector)
            if let j = registry.environments[i].apps.firstIndex(where: { $0.adapter == adapter }) {
                guard registry.environments[i].apps[j].instance == nil else { throw AppEnvError("Stop this app before changing its location.") }
                registry.environments[i].apps[j].path = path.path
            } else {
                registry.environments[i].apps.append(AppBinding(adapter: adapter, path: path.path))
            }
        }
    }
    @discardableResult public func duplicate(_ selector: String, name: String) throws -> Environment {
        try transaction { registry in
            let source = registry.environments[try index(registry, selector)]
            guard !source.isRunning else { throw AppEnvError("Stop all apps before duplicating this environment.") }
            let copy = Environment(name: try validateName(name, registry), apps: source.apps)
            try fm.copyItem(at: directory(source.id), to: directory(copy.id))
            registry.environments.append(copy)
            return copy
        }
    }
    public func delete(_ selector: String) throws {
        try transaction { registry in
            let i = try index(registry, selector)
            guard !registry.environments[i].isRunning else { throw AppEnvError("Stop all apps before deleting this environment.") }
            // A recoverable trash move, never recursive deletion of a user-supplied path.
            try fm.trashItem(at: directory(registry.environments[i].id), resultingItemURL: nil)
            registry.environments.remove(at: i)
        }
    }
    public func export(_ selector: String, to destination: URL) throws {
        let fd = try lock(); defer { unlock(fd) }
        var registry = try read(); reconcile(&registry)
        let env = registry.environments[try index(registry, selector)]
        guard !env.isRunning else { throw AppEnvError("Stop all apps before exporting this environment.") }
        guard !fm.fileExists(atPath: destination.path) else { throw AppEnvError("The export destination already exists.") }
        guard !destination.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw AppEnvError("Export to a folder outside AppEnv storage.")
        }
        let staging = fm.temporaryDirectory.appendingPathComponent("AppEnv-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: directory(env.id), to: staging.appendingPathComponent("data"))
        try JSONEncoder().encode(env).write(to: staging.appendingPathComponent("environment.json"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, destination.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppEnvError("Export failed (ditto \(process.terminationStatus)).") }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func running(_ instance: Instance) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: instance.pid), !app.isTerminated,
              let date = app.launchDate, abs(date.timeIntervalSince(instance.launchedAt)) < 0.01,
              app.executableURL?.path == instance.executablePath else { return nil }
        return app
    }
    private func reconcile(_ registry: inout Registry) {
        let applications = NSWorkspace.shared.runningApplications
        for i in registry.environments.indices {
            for j in registry.environments[i].apps.indices {
                if let instance = registry.environments[i].apps[j].instance, running(instance) == nil {
                    registry.environments[i].apps[j].instance = nil
                }
                // Recover ownership after a launcher crash, including the interval between
                // spawning an application and saving its receipt. Match exact argv entries.
                let binding = registry.environments[i].apps[j]
                if binding.instance == nil {
                    let data = appDirectory(registry.environments[i].id, binding.adapter)
                    if let app = applications.first(where: {
                        $0.bundleIdentifier == binding.adapter.bundleID && matchesProfile($0.processIdentifier, binding.adapter, data)
                    }), let date = app.launchDate, let path = app.executableURL?.path {
                        registry.environments[i].apps[j].instance = Instance(pid: app.processIdentifier, launchedAt: date, executablePath: path)
                    }
                }
            }
        }
    }
    private func matchesProfile(_ pid: Int32, _ adapter: Adapter, _ data: URL) -> Bool {
        let args = processArguments(pid)
        let expected = adapter.arguments(data: launchDirectory(adapter, data))
        if adapter == .chrome { return args.contains(expected[0]) }
        guard let i = args.firstIndex(of: "--user-data-dir"), i + 1 < args.count else { return false }
        return args[i + 1] == expected[1]
    }
    private var aliasRoot: URL { URL(fileURLWithPath: "/tmp/appenv-\(getuid())") }
    func launchDirectory(_ adapter: Adapter, _ data: URL) -> URL {
        guard adapter == .vscode else { return data }
        let digest = SHA256.hash(data: Data(data.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return aliasRoot.appendingPathComponent(digest)
    }
    func prepareLaunchAlias(_ data: URL) throws {
        // VS Code puts its main IPC socket under user-data; macOS limits socket
        // paths to 103 bytes. A private short alias keeps persistent data in AppEnv.
        if !fm.fileExists(atPath: aliasRoot.path) {
            try fm.createDirectory(at: aliasRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try fm.attributesOfItem(atPath: aliasRoot.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw AppEnvError("The AppEnv runtime directory must be a private directory owned by you: \(aliasRoot.path)")
        }
        let link = launchDirectory(.vscode, data)
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            guard target == data.path else { throw AppEnvError("The VS Code runtime alias points to an unexpected location.") }
        } else {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: data.path)
        }
    }
    private func processArguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 100_000 else { return [] }
        var offset = 4
        while offset < size && bytes[offset] != 0 { offset += 1 }
        while offset < size && bytes[offset] == 0 { offset += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            let start = offset
            while offset < size && bytes[offset] != 0 { offset += 1 }
            guard offset < size else { return [] }
            result.append(String(decoding: bytes[start..<offset], as: UTF8.self)); offset += 1
        }
        return result
    }
    private func validateApplication(_ adapter: Adapter, _ url: URL) throws -> String {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == adapter.bundleID else {
            throw AppEnvError("Select the official \(adapter.name).app application.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw AppEnvError("Cannot read the application's code signature.")
        }
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"\(adapter.bundleID)\" and certificate leaf[subject.OU] = \"\(adapter.teamID)\""
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw AppEnvError("The application's signature does not match the expected publisher.")
        }
        if adapter == .vscode, fm.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("code-portable-data").path) {
            throw AppEnvError("This VS Code installation uses portable mode, which overrides profile paths. Select a standard installation.")
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    @MainActor @discardableResult public func launch(_ selector: String, adapter: Adapter, allowVersionChange: Bool = false) async throws -> Instance {
        let fd = try lock(); defer { unlock(fd) }
        var registry = try read(); reconcile(&registry)
        let i = try index(registry, selector)
        guard let j = registry.environments[i].apps.firstIndex(where: { $0.adapter == adapter }) else {
            throw AppEnvError("Add \(adapter.name) to this environment first.")
        }
        let binding = registry.environments[i].apps[j]
        if let instance = binding.instance, let app = running(instance) {
            app.activate(options: []); return instance
        }
        let url = URL(fileURLWithPath: binding.path)
        let version = try validateApplication(adapter, url)
        if let previous = binding.lastVersion, previous != version, !allowVersionChange {
            throw AppEnvError("\(adapter.name) changed from \(previous) to \(version). Duplicate the stopped environment as a backup, then allow the version change to launch.")
        }
        let data = appDirectory(registry.environments[i].id, adapter)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        if adapter == .vscode { try prepareLaunchAlias(data) }
        configuration.arguments = adapter.arguments(data: launchDirectory(adapter, data))
        // NSWorkspace treats this as the launch environment, not just an overlay.
        // Supply essential user variables without forwarding editor IPC hooks or tool secrets.
        configuration.environment = [
            "HOME": fm.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(), "LOGNAME": NSUserName(),
            "SHELL": ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "APPENV_ID": registry.environments[i].id.uuidString,
            "APPENV_NAME": registry.environments[i].name
        ]
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        guard let launchedAt = app.launchDate, let executable = app.executableURL else {
            throw AppEnvError("The application did not provide a trackable instance.")
        }
        let instance = Instance(pid: app.processIdentifier, launchedAt: launchedAt, executablePath: executable.path)
        // Persist immediately so closing AppEnv during readiness checks does not lose ownership.
        registry.environments[i].apps[j].instance = instance
        registry.environments[i].apps[j].lastVersion = version
        try save(registry)
        let expected = data.appendingPathComponent(adapter == .chrome ? "profile" : "user-data")
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            guard !app.isTerminated else { throw AppEnvError("The app exited during launch. Its profile may be locked by another process.") }
            let marker = expected.appendingPathComponent(adapter == .chrome ? "Local State" : "User")
            if app.isFinishedLaunching && matchesProfile(app.processIdentifier, adapter, data) && fm.fileExists(atPath: marker.path) { return instance }
        }
        throw AppEnvError("The app is still tracked, but profile readiness was not confirmed within 10 seconds. Check its window before retrying.")
    }

    @MainActor public func stop(_ selector: String, adapter: Adapter? = nil, force: Bool = false) async throws {
        let fd = try lock(); defer { unlock(fd) }
        var registry = try read(); reconcile(&registry)
        let i = try index(registry, selector)
        let targets = registry.environments[i].apps.filter { adapter == nil || $0.adapter == adapter }
        for binding in targets {
            if let instance = binding.instance, let app = running(instance) {
                if force { _ = app.forceTerminate() } else { _ = app.terminate() }
            }
        }
        for _ in 0..<40 {
            reconcile(&registry)
            if !registry.environments[i].apps.contains(where: { (adapter == nil || $0.adapter == adapter) && $0.instance != nil }) {
                try save(registry); return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        try save(registry)
        throw AppEnvError("The app has not quit. Save any open work and try again, or explicitly force stop it.")
    }
}
