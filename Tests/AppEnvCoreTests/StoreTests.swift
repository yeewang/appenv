import XCTest
import AppKit
import Darwin
@testable import AppEnvCore

final class StoreTests: XCTestCase {
    var root: URL!
    var store: Store!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppEnvTests-\(UUID())")
        store = try Store(root: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testNamesAndStablePaths() throws {
        let env = try store.create(" Work ")
        XCTAssertEqual(env.name, "Work")
        XCTAssertThrowsError(try store.create("work"))
        XCTAssertThrowsError(try store.create("\n"))
        let path = store.directory(env.id)
        try store.rename("Work", to: "Business")
        XCTAssertEqual(try store.environment("Business").id, env.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try Store(root: root).list().count, 1)
    }

    func testProfilePathsAreDistinctAndNotDefaultDirectories() throws {
        let a = try store.create("a"), b = try store.create("b")
        for adapter in Adapter.allCases {
            let first = adapter.arguments(data: store.appDirectory(a.id, adapter))
            let second = adapter.arguments(data: store.appDirectory(b.id, adapter))
            XCTAssertNotEqual(first, second)
            XCTAssertTrue(first.joined().contains(a.id.uuidString))
            XCTAssertFalse(first.joined().contains("Library/Application Support/Google/Chrome"))
        }
    }

    func testDuplicateHasIndependentData() throws {
        let source = try store.create("source")
        let file = store.directory(source.id).appendingPathComponent("settings")
        try Data("original".utf8).write(to: file)
        let copy = try store.duplicate("source", name: "copy")
        try Data("changed".utf8).write(to: store.directory(copy.id).appendingPathComponent("settings"))
        XCTAssertEqual(try String(contentsOf: file), "original")
        XCTAssertNotEqual(source.id, copy.id)
    }

    func testVersionBackupPersistsOldVersionAndIndependentProfile() throws {
        var binding = AppBinding(adapter: .codex, path: "/Applications/Codex.app")
        binding.lastVersion = "26.1013.40934"
        let source = Environment(name: "Work", apps: [binding])
        try FileManager.default.createDirectory(at: store.directory(source.id), withIntermediateDirectories: true)
        let file = store.directory(source.id).appendingPathComponent("settings")
        try Data("old-profile".utf8).write(to: file)
        var registry = Registry(environments: [source])
        let backup = try store.backupForVersionChange(source, registry: &registry)
        try Data("migrated-profile".utf8).write(to: file)
        XCTAssertEqual(try String(contentsOf: store.directory(backup.id).appendingPathComponent("settings")), "old-profile")
        XCTAssertEqual(backup.apps.first?.lastVersion, "26.1013.40934")
        XCTAssertEqual(try Store(root: root).list().count, 2)
        let second = try store.backupForVersionChange(source, registry: &registry)
        XCTAssertEqual(second.name, "Work Backup 2")
    }

    func testFailedVersionBackupDoesNotRegisterPartialCopy() throws {
        let source = Environment(name: "Missing")
        var registry = Registry(environments: [source])
        XCTAssertThrowsError(try store.backupForVersionChange(source, registry: &registry))
        XCTAssertEqual(registry.environments.count, 1)
        XCTAssertTrue(try store.list().isEmpty)
    }

    @MainActor func testVersionChangeRequiresApprovalForTheCurrentVersion() async throws {
        guard let url = Adapter.codex.installedURL else { throw XCTSkip("Codex is not installed") }
        let env = try store.create("Update Test")
        try store.add(env.id.uuidString, adapter: .codex, url: url)
        let registryURL = root.appendingPathComponent("registry.json")
        var registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: registryURL))
        registry.environments[0].apps[0].lastVersion = "old-test-version"
        try JSONEncoder().encode(registry).write(to: registryURL)
        for approved in [nil, "outdated-approval"] as [String?] {
            do {
                _ = try await store.launch(env.id.uuidString, adapter: .codex,
                                           backupBeforeVersionChange: approved != nil, approvedVersion: approved)
                XCTFail("Must reject unapproved version before launch")
            } catch let change as AppVersionChange {
                XCTAssertEqual(change.environmentID, env.id)
                XCTAssertEqual(change.previous, "old-test-version")
                XCTAssertNotEqual(change.current, "outdated-approval")
            }
        }
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertNil(try store.environment(env.id.uuidString).apps[0].instance)
    }

    func testDuplicateOmitsRuntimePipesAndPreservesRegularFiles() throws {
        let source = try store.create("runtime")
        let sourceDirectory = store.directory(source.id)
        let pipe = sourceDirectory.appendingPathComponent("runtime.pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        try Data("persistent".utf8).write(to: sourceDirectory.appendingPathComponent("settings"))
        let copy = try store.duplicate("runtime", name: "copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(copy.id).appendingPathComponent("runtime.pipe").path))
        XCTAssertEqual(try String(contentsOf: store.directory(copy.id).appendingPathComponent("settings")), "persistent")
    }

    func testCorruptRegistryIsNotOverwritten() throws {
        let file = root.appendingPathComponent("registry.json")
        let corrupted = Data("invalid registry".utf8)
        try corrupted.write(to: file)
        XCTAssertThrowsError(try store.create("new"))
        XCTAssertEqual(try Data(contentsOf: file), corrupted)
    }

    func testCrossClientLockRejectsMutation() throws {
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        defer { flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.create("locked"))
    }

    func testUnsupportedAppCannotBeAdded() throws {
        _ = try store.create("test")
        XCTAssertThrowsError(try store.add("test", adapter: .chrome, url: URL(fileURLWithPath: "/System/Applications/TextEdit.app")))
        XCTAssertTrue(try store.environment("test").apps.isEmpty)
    }

    func testApplicationFilesAddToOnlyTheTargetAndDeduplicate() throws {
        guard let chrome = Adapter.chrome.installedURL else { throw XCTSkip("Official Chrome is required for publisher validation.") }
        _ = try store.create("source")
        _ = try store.create("target")
        XCTAssertEqual(try store.addApplicationFiles("target", urls: [chrome, chrome]), 1)
        XCTAssertTrue(try store.environment("source").apps.isEmpty)
        let env = try store.environment("target")
        XCTAssertEqual(env.apps.count, 1)
        XCTAssertEqual(env.apps[0].adapter, .chrome)
        XCTAssertNil(env.apps[0].instance)
        XCTAssertEqual(try store.addApplicationFiles("target", urls: [chrome]), 0)
    }

    func testMixedApplicationDropDoesNotPartiallyAddApps() throws {
        guard let chrome = Adapter.chrome.installedURL else { throw XCTSkip("Official Chrome is required for publisher validation.") }
        _ = try store.create("target")
        XCTAssertThrowsError(try store.addApplicationFiles("target", urls: [chrome, root.appendingPathComponent("document.txt")]))
        XCTAssertTrue(try store.environment("target").apps.isEmpty)
    }

    func testApplicationDropRejectsWebURLsAndUnsupportedApps() throws {
        _ = try store.create("target")
        XCTAssertThrowsError(try store.addApplicationFiles("target", urls: [URL(string: "https://example.com/Chrome.app")!]))
        XCTAssertThrowsError(try store.addApplicationFiles("target", urls: [URL(fileURLWithPath: "/System/Applications/TextEdit.app")]))
        XCTAssertTrue(try store.environment("target").apps.isEmpty)
    }

    func testCodexRequiresBothProfileVariablesForOwnership() throws {
        let env = try store.create("codex")
        let data = store.appDirectory(env.id, .codex)
        let launchData = store.launchDirectory(.codex, data)
        let arguments = Adapter.codex.arguments(data: launchData)
        let environment = Adapter.codex.environment(data: launchData)
        XCTAssertTrue(store.matchesProfile(arguments: arguments, environment: environment, adapter: .codex, data: data))
        XCTAssertFalse(store.matchesProfile(arguments: arguments, environment: [:], adapter: .codex, data: data))
        var wrongHome = environment
        wrongHome["CODEX_HOME"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        XCTAssertFalse(store.matchesProfile(arguments: arguments, environment: wrongHome, adapter: .codex, data: data))
        XCTAssertFalse(store.matchesProfile(arguments: [], environment: environment, adapter: .codex, data: data))
    }

    func testCodexHomesAndDesktopDataAreDistinctAcrossEnvironments() throws {
        let a = try store.create("a"), b = try store.create("b")
        let first = store.launchDirectory(.codex, store.appDirectory(a.id, .codex))
        let second = store.launchDirectory(.codex, store.appDirectory(b.id, .codex))
        let one = Adapter.codex.environment(data: first), two = Adapter.codex.environment(data: second)
        XCTAssertNotEqual(one["CODEX_HOME"], two["CODEX_HOME"])
        XCTAssertNotEqual(one["CODEX_ELECTRON_USER_DATA_PATH"], two["CODEX_ELECTRON_USER_DATA_PATH"])
        XCTAssertNotEqual(one["CODEX_HOME"], one["CODEX_ELECTRON_USER_DATA_PATH"])
        XCTAssertTrue(Adapter.chrome.environment(data: first).isEmpty)
        XCTAssertTrue(Adapter.vscode.environment(data: first).isEmpty)
        XCTAssertEqual(Adapter.codex.readinessFiles(data: first).count, 2)
    }

    func testOfficialCodexCanBeAddedUnderItsInstalledName() throws {
        guard let codex = Adapter.codex.installedURL else { throw XCTSkip("Official Codex installation required.") }
        _ = try store.create("codex")
        XCTAssertEqual(try store.addApplicationFiles("codex", urls: [codex]), 1)
        XCTAssertEqual(try store.environment("codex").apps.first?.adapter, .codex)
        XCTAssertEqual(Adapter.resolve("codex"), .codex)
    }

    func testVSCodeSocketPathRemainsShortForDeepStorageRoots() throws {
        let env = try store.create("socket-test")
        let data = store.appDirectory(env.id, .vscode)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let alias = store.launchDirectory(.vscode, data)
        defer { try? FileManager.default.removeItem(at: alias) }
        try store.prepareLaunchAlias(data)
        let socket = alias.appendingPathComponent("user-data/1.99-main.sock")
        XCTAssertLessThan(socket.path.utf8.count, 103)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), data.path)
        XCTAssertEqual(store.launchDirectory(.vscode, data), alias)
        XCTAssertNotEqual(store.launchDirectory(.vscode, data.appendingPathComponent("other")), alias)
    }

    func testVSCodeAliasCannotBeRedirectedToAnotherProfile() throws {
        let env = try store.create("alias-test")
        let data = store.appDirectory(env.id, .vscode)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let alias = store.launchDirectory(.vscode, data)
        try store.prepareLaunchAlias(data)
        try FileManager.default.removeItem(at: alias)
        defer { try? FileManager.default.removeItem(at: alias) }
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: root.path)
        XCTAssertThrowsError(try store.prepareLaunchAlias(data))
    }

    func testStalePIDClearedWithoutSignalingAnything() throws {
        var env = Environment(name: "stale")
        var binding = AppBinding(adapter: .chrome, path: "/Applications/Google Chrome.app")
        binding.instance = Instance(pid: getpid(), launchedAt: .distantPast, executablePath: "/not-this-process")
        env.apps = [binding]
        var registry = Registry(); registry.environments = [env]
        try JSONEncoder().encode(registry).write(to: root.appendingPathComponent("registry.json"))
        XCTAssertNil(try store.environment("stale").apps[0].instance)
    }

    func testExportDoesNotOverwriteOrRecurseIntoStorage() throws {
        let env = try store.create("export")
        let nested = store.directory(env.id).appendingPathComponent("backup.zip")
        XCTAssertThrowsError(try store.export("export", to: nested))
        let output = root.deletingLastPathComponent().appendingPathComponent("AppEnvExport-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: output) }
        try store.export("export", to: output)
        XCTAssertGreaterThan(try Data(contentsOf: output).count, 0)
        XCTAssertThrowsError(try store.export("export", to: output))
    }
}
