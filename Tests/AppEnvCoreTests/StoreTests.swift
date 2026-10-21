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
