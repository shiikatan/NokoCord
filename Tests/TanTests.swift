import Foundation
import XCTest
@testable import NokoCordCore

@MainActor
final class TanTests: XCTestCase {
    private func cssManifest(id: String = "fixture.clear-focus", stylesheet: String = "style.css") -> TanManifest {
        TanManifest(schemaVersion: 1,
                    id: id,
                    name: "Fixture Clear Focus",
                    version: "1.0.0",
                    description: "A local test Tan.",
                    authors: ["fixture-author"],
                    target: .css,
                    entry: nil,
                    stylesheet: stylesheet,
                    capabilities: [],
                    requiresReload: false,
                    source: nil,
                    license: "MIT")
    }

    private func isolatedManifest(id: String = "fixture.scroll-tools",
                                  capabilities: [TanCapability] = []) -> TanManifest {
        TanManifest(schemaVersion: 1,
                    id: id,
                    name: "Fixture Scroll Tools",
                    version: "1.0.0",
                    description: "A local test Tan.",
                    authors: ["fixture-author"],
                    target: .isolated,
                    entry: "main.js",
                    stylesheet: nil,
                    capabilities: capabilities,
                    requiresReload: false,
                    source: nil,
                    license: "MIT")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NokoCord-TanTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func assertTanInvalid<T>(_ expression: @autoclosure () throws -> T,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertTrue(error is TanError, "Expected TanError, got \(error)", file: file, line: line)
        }
    }

    func testMinimalManifestAndPackageRoundTrip() throws {
        let manifest = cssManifest()
        let package = TanPackage(manifest: manifest, javascript: nil, css: ".fixture { outline: 1px solid red; }", origin: "Local fixture")

        XCTAssertNoThrow(try manifest.validate())
        XCTAssertNoThrow(try package.validate())

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(TanManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(package.id, "fixture.clear-focus")
        XCTAssertEqual(package.origin, "Local fixture")
    }

    func testManifestRejectsTraversalUnsupportedSchemaPageCapabilityAndOversizeContent() throws {
        var traversal = isolatedManifest()
        traversal.entry = "../main.js"
        assertTanInvalid(try traversal.validate())

        var unsupported = cssManifest()
        unsupported.schemaVersion = 2
        assertTanInvalid(try unsupported.validate())

        let pageWithNativeCapability = TanManifest(schemaVersion: 1,
                                                   id: "fixture.page-capability",
                                                   name: "Fixture Page Capability",
                                                   version: "1.0.0",
                                                   description: "A local test Tan.",
                                                   authors: ["fixture-author"],
                                                   target: .page,
                                                   entry: "main.js",
                                                   stylesheet: nil,
                                                   capabilities: [.appearanceRead],
                                                   requiresReload: false,
                                                   source: nil,
                                                   license: "MIT")
        assertTanInvalid(try pageWithNativeCapability.validate())

        let oversized = TanPackage(manifest: isolatedManifest(),
                                   javascript: String(repeating: "x", count: 512 * 1024 + 1),
                                   css: nil,
                                   origin: "Local fixture")
        assertTanInvalid(try oversized.validate())
    }

    func testManifestRejectsBlankOrControlCharacterDisplayMetadata() throws {
        func manifest(name: String = "Fixture", description: String = "Description", authors: [String] = ["Author"]) -> TanManifest {
            TanManifest(id: "fixture.metadata", name: name, version: "1.0.0",
                        description: description, authors: authors, target: .css,
                        entry: nil, stylesheet: "style.css")
        }
        assertTanInvalid(try manifest(name: " \n ").validate())
        assertTanInvalid(try manifest(authors: [" \t "]).validate())
        assertTanInvalid(try manifest(name: "Visible\u{0000}Hidden").validate())
        XCTAssertNoThrow(try manifest(description: "A useful\nmultiline description").validate())
        XCTAssertNoThrow(try manifest(description: "").validate())
    }

    func testLocalPackageRejectsSymlinkEntry() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let outside = folder.deletingLastPathComponent().appendingPathComponent("outside.css")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data(".outside {}".utf8).write(to: outside)
        try JSONEncoder().encode(cssManifest()).write(to: folder.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("style.css"), withDestinationURL: outside)

        assertTanInvalid(try TanPackage.load(folder: folder))
    }

    func testMalformedLocalPackageMatrixRejectsInputs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = root.appendingPathComponent("packages", isDirectory: true)
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)

        let validManifest = try JSONEncoder().encode(isolatedManifest())
        var invalidCases: [(String, (URL) throws -> Void)] = [
            ("missing manifest", { _ in }),
            ("invalid JSON", { folder in
                try Data("{not-json".utf8).write(to: folder.appendingPathComponent("manifest.json"))
            }),
            ("wrong field types", { folder in
                try Data(#"{"schemaVersion":"one","id":17}"#.utf8)
                    .write(to: folder.appendingPathComponent("manifest.json"))
            }),
            ("missing entry", { folder in
                try validManifest.write(to: folder.appendingPathComponent("manifest.json"))
            }),
            ("traversal filename", { folder in
                var manifest = self.isolatedManifest()
                manifest.entry = "../main.js"
                try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
            }),
            ("unsupported capability", { folder in
                // Encode a well-formed manifest object with a capability unknown to this build.
                let object = try JSONSerialization.jsonObject(with: validManifest) as! [String: Any]
                var unsupported = object
                unsupported["capabilities"] = ["appearance.write"]
                try JSONSerialization.data(withJSONObject: unsupported)
                    .write(to: folder.appendingPathComponent("manifest.json"))
            })
        ]

        // Start from a valid encoded manifest so each case isolates one malformed
        // schema or contract field instead of relying on a partial JSON object.
        let validObject = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifest) as? [String: Any])
        let malformedObjects: [(String, (inout [String: Any]) -> Void)] = [
            ("boolean schema version", { $0["schemaVersion"] = true }),
            ("unknown target", { $0["target"] = "webview" }),
            ("authors wrong type", { $0["authors"] = "fixture-author" }),
            ("capabilities wrong type", { $0["capabilities"] = "appearance.read" }),
            ("duplicate capability", { $0["capabilities"] = ["appearance.read", "appearance.read"] }),
            ("capability on CSS target", { $0["target"] = "css"; $0["entry"] = NSNull(); $0["stylesheet"] = "style.css"; $0["capabilities"] = ["appearance.read"] }),
            ("stylesheet traversal", { $0["stylesheet"] = "../style.css" }),
            ("stylesheet wrong extension", { $0["stylesheet"] = "style.js" }),
            ("credentialed source URL", { $0["source"] = "https://user:secret@example.invalid/tan" }),
            ("source URL with query", { $0["source"] = "https://example.invalid/tan?token=fixture" })
        ]
        for (name, mutate) in malformedObjects {
            var object = validObject
            mutate(&object)
            invalidCases.append((name, { folder in
                try JSONSerialization.data(withJSONObject: object)
                    .write(to: folder.appendingPathComponent("manifest.json"))
            }))
        }
        invalidCases.append(("missing declared stylesheet", { folder in
            let manifest = self.cssManifest()
            // The manifest is valid, but its declared content file is absent.
            try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        }))

        for (name, populate) in invalidCases {
            let folder = packages.appendingPathComponent(name.replacingOccurrences(of: " ", with: "-"), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try populate(folder)

            XCTAssertThrowsError(try TanPackage.load(folder: folder), "Expected malformed package to fail: \(name)")
        }
    }

    func testTanManagerInstallEnableSafeModePersistsAndUninstallRemovesPackage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = TanPackage(manifest: isolatedManifest(), javascript: "export default {};", css: nil, origin: "Local fixture")

        let manager = TanManager(root: root, launchSafeMode: false)
        XCTAssertTrue(manager.installed.isEmpty)
        XCTAssertTrue(manager.enabledIDs.isEmpty)
        try manager.install(package)
        XCTAssertEqual(manager.installed.map(\.id), [package.id])
        XCTAssertTrue(manager.enabledIDs.isEmpty, "New packages must start disabled")
        manager.setEnabled(package.id, true)
        manager.setSafeMode(true)
        XCTAssertEqual(manager.enabledIDs, Set([package.id]))
        XCTAssertTrue(manager.active.isEmpty, "Safe Mode must suppress enabled Tans")

        let persisted = try Data(contentsOf: root.appendingPathComponent("\(package.id).tan.json"))
        let persistedHash = package.contentHash
        assertTanInvalid(try manager.install(package))
        XCTAssertEqual(manager.installed.count, 1)
        XCTAssertEqual(manager.installed[0].contentHash, persistedHash)
        XCTAssertFalse(persisted.isEmpty)

        let restarted = TanManager(root: root)
        XCTAssertTrue(restarted.safeMode)
        XCTAssertEqual(restarted.enabledIDs, Set([package.id]))
        XCTAssertTrue(restarted.active.isEmpty)

        let launchSafeMode = TanManager(root: root, launchSafeMode: true)
        XCTAssertTrue(launchSafeMode.safeMode)
        XCTAssertEqual(launchSafeMode.enabledIDs, Set([package.id]))
        try launchSafeMode.uninstall(package.id)
        XCTAssertTrue(launchSafeMode.installed.isEmpty)
        XCTAssertFalse(launchSafeMode.enabledIDs.contains(package.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(package.id).tan.json").path))
    }

    func testLaunchSafeModeDoesNotErasePersistedEnabledSet() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = TanPackage(manifest: cssManifest(id: "fixture.focus-mode"), javascript: nil, css: ".fixture {}", origin: "Local fixture")
        let manager = TanManager(root: root)
        try manager.install(package)
        manager.setEnabled(package.id, true)

        let safe = TanManager(root: root, launchSafeMode: true)
        XCTAssertTrue(safe.safeMode)
        XCTAssertEqual(safe.enabledIDs, Set([package.id]))
        XCTAssertTrue(safe.active.isEmpty)

        let normal = TanManager(root: root)
        XCTAssertFalse(normal.safeMode)
        XCTAssertEqual(normal.enabledIDs, Set([package.id]))
        XCTAssertEqual(normal.active.map(\.id), [package.id])
    }

    func testDeveloperReplacementRequiresModeAndMatchingIDAndPersistsDisabledState() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = TanPackage(manifest: cssManifest(id: "fixture.replaceable"),
                                  javascript: nil,
                                  css: ".original { outline: 1px solid red; }",
                                  origin: "Local fixture")
        let replacement = TanPackage(manifest: cssManifest(id: original.id),
                                     javascript: nil,
                                     css: ".replacement { outline: 2px solid blue; }",
                                     origin: "Local fixture")
        let wrongID = TanPackage(manifest: cssManifest(id: "fixture.other"),
                                 javascript: nil,
                                 css: ".other {}",
                                 origin: "Local fixture")
        let manager = TanManager(root: root)
        try manager.install(original)
        manager.setEnabled(original.id, true)
        let originalHash = try XCTUnwrap(manager.installed.first?.contentHash)

        assertTanInvalid(try manager.replaceFromLocalFolder(replacement))
        manager.setDeveloperMode(true)
        assertTanInvalid(try manager.replaceFromLocalFolder(wrongID))
        try manager.replaceFromLocalFolder(replacement)

        XCTAssertEqual(manager.installed.count, 1)
        XCTAssertEqual(manager.installed[0].id, original.id)
        XCTAssertNotEqual(manager.installed[0].contentHash, originalHash)
        XCTAssertFalse(manager.enabledIDs.contains(original.id), "Replacement must require a fresh enable decision")
        assertTanInvalid(try manager.install(replacement))

        let restarted = TanManager(root: root)
        XCTAssertTrue(restarted.developerMode)
        XCTAssertEqual(restarted.installed.count, 1)
        XCTAssertEqual(restarted.installed[0].contentHash, manager.installed[0].contentHash)
        XCTAssertFalse(restarted.enabledIDs.contains(original.id))
        assertTanInvalid(try restarted.install(replacement))
    }

    func testOfficialBundledUpdateReplacesOldVersionDisabledAcrossRestartWithoutDeveloperMode() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try XCTUnwrap(TanPackage.originals.first(where: { $0.id == "noko.clear-focus" }))
        let oldManifest = TanManifest(schemaVersion: original.manifest.schemaVersion,
                                      id: original.id,
                                      name: original.manifest.name,
                                      version: "0.9.0",
                                      description: original.manifest.description,
                                      authors: original.manifest.authors,
                                      target: original.manifest.target,
                                      entry: original.manifest.entry,
                                      stylesheet: original.manifest.stylesheet,
                                      capabilities: original.manifest.capabilities,
                                      requiresReload: original.manifest.requiresReload,
                                      source: original.manifest.source,
                                      license: original.manifest.license)
        let oldPackage = TanPackage(manifest: oldManifest,
                                    javascript: original.javascript,
                                    css: original.css,
                                    origin: "Noko-Tan")
        let manager = TanManager(root: root)
        try manager.install(oldPackage)
        manager.setEnabled(oldPackage.id, true)
        XCTAssertFalse(manager.developerMode)
        XCTAssertNotEqual(oldPackage.contentHash, original.contentHash)
        XCTAssertEqual(manager.availableOriginalUpdate(oldPackage)?.contentHash, original.contentHash)

        try manager.updateOriginal(oldPackage.id)
        XCTAssertEqual(manager.installed.first?.contentHash, original.contentHash)
        XCTAssertEqual(manager.installed.first?.origin, original.origin)
        XCTAssertTrue(manager.enabledIDs.isEmpty, "Official updates require a fresh enable decision")

        let restarted = TanManager(root: root)
        XCTAssertEqual(restarted.installed.first?.contentHash, original.contentHash)
        XCTAssertTrue(restarted.enabledIDs.isEmpty)
        XCTAssertFalse(restarted.developerMode)
    }

    func testLocalSameIDPackageIsNotOfferedBundledUpdate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try XCTUnwrap(TanPackage.originals.first(where: { $0.id == "noko.clear-focus" }))
        let local = TanPackage(manifest: original.manifest,
                               javascript: original.javascript,
                               css: original.css,
                               origin: "Local package")
        let manager = TanManager(root: root)
        try manager.install(local)
        let beforeHash = try XCTUnwrap(manager.installed.first?.contentHash)
        XCTAssertNil(manager.availableOriginalUpdate(local))
        try manager.updateOriginal(local.id)
        XCTAssertEqual(manager.installed.first?.contentHash, beforeHash)
        XCTAssertEqual(manager.installed.first?.origin, "Local package")
    }

    func testTanBridgePermitsOnlyDeclaredAppearanceReadOnIsolatedTarget() throws {
        let isolated = isolatedManifest(capabilities: [.appearanceRead])
        let css = cssManifest()
        let isolatedWithoutCapability = isolatedManifest(id: "fixture.no-capability")
        let valid = try XCTUnwrap(TanBridgeRequest.parse(["type": "capability", "capability": "appearance.read"]))

        XCTAssertTrue(valid.permits(isolated))
        XCTAssertFalse(valid.permits(css))
        XCTAssertFalse(valid.permits(isolatedWithoutCapability))
        XCTAssertFalse(TanBridgeRequest(type: "state", capability: "appearance.read", state: nil).permits(isolated))
        XCTAssertFalse(TanBridgeRequest(type: "capability", capability: "appearance.write", state: nil).permits(isolated))
    }

    func testTanBridgeParserRejectsMalformedExtraAndIncorrectFields() {
        XCTAssertNotNil(TanBridgeRequest.parse(["type": "status", "state": "started"]))
        XCTAssertNotNil(TanBridgeRequest.parse(["type": "capability", "capability": "appearance.read"]))
        XCTAssertNil(TanBridgeRequest.parse(["type": "status", "state": "started", "extra": "fixture"]))
        XCTAssertNil(TanBridgeRequest.parse(["type": "status", "state": 1]))
        XCTAssertNil(TanBridgeRequest.parse(["type": "status", "capability": "appearance.read"]))
        XCTAssertNil(TanBridgeRequest.parse(["type": "capability", "capability": "appearance.read", "state": "started"]))
        XCTAssertNil(TanBridgeRequest.parse(["type": "capability", "capability": "appearance.write"]))
        XCTAssertNil(TanBridgeRequest.parse(["type": 1, "state": "started"]))
        XCTAssertNil(TanBridgeRequest.parse(["state": "started"]))
    }

    func testOfficialBundledOriginalsIncludeAllOfficialTans() throws {
        let expectedIDs = ["noko.clear-focus", "noko.scroll-tools", "noko.chat", "noko.morgana"]
        let originalIDs = TanPackage.originals.map(\.id)
        for expected in expectedIDs {
            XCTAssertTrue(originalIDs.contains(expected), "Missing official Tan: \(expected)")
        }
        XCTAssertEqual(Set(originalIDs).count, originalIDs.count, "Official Tans must have unique IDs")

        let nokoChat = try XCTUnwrap(TanPackage.originals.first(where: { $0.id == "noko.chat" }))
        XCTAssertEqual(nokoChat.manifest.name, "Noko-Chat")
        XCTAssertEqual(nokoChat.manifest.version, "1.6.5")
        XCTAssertEqual(nokoChat.manifest.target, .isolated)
        XCTAssertFalse(nokoChat.manifest.requiresReload)
        XCTAssertNotNil(nokoChat.javascript)
        XCTAssertNil(nokoChat.css)
        XCTAssertNoThrow(try nokoChat.validate())

        let morgana = try XCTUnwrap(TanPackage.originals.first(where: { $0.id == "noko.morgana" }))
        XCTAssertEqual(morgana.manifest.name, "Morgana")
        XCTAssertEqual(morgana.manifest.version, "1.1.0")
        XCTAssertEqual(morgana.manifest.target, .page)
        XCTAssertTrue(morgana.manifest.requiresReload)
        XCTAssertNotNil(morgana.javascript)
        XCTAssertNil(morgana.css)
        XCTAssertNoThrow(try morgana.validate())
    }
}
