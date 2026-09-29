import Foundation
import CryptoKit
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

    func testNativeTanManifestIsScriptlessAndCannotBeImported() throws {
        let manifest = TanManifest(schemaVersion: 1,
                                   id: NokoNativeTanID.appleMusicPresence,
                                   name: "Fixture Native Tan",
                                   version: "1.0.0",
                                   description: "A native fixture.",
                                   authors: ["fixture-author"],
                                   target: .native,
                                   entry: nil,
                                   stylesheet: nil,
                                   capabilities: [],
                                   requiresReload: false,
                                   source: nil,
                                   license: nil)
        let package = TanPackage(manifest: manifest, javascript: nil, css: nil, origin: "Noko Original")
        XCTAssertNoThrow(try package.validate())

        let withScript = TanPackage(manifest: manifest, javascript: "globalThis.evil = true", css: nil, origin: "Noko Original")
        assertTanInvalid(try withScript.validate())

        let wrongID = TanManifest(schemaVersion: 1,
                                  id: "fixture.native-other",
                                  name: "Fixture Native Tan",
                                  version: "1.0.0",
                                  description: "A native fixture.",
                                  authors: ["fixture-author"],
                                  target: .native,
                                  entry: nil,
                                  stylesheet: nil,
                                  capabilities: [],
                                  requiresReload: false,
                                  source: nil,
                                  license: nil)
        assertTanInvalid(try wrongID.validate())
    }

    func testAppleMusicNativeIdentifierRejectsScriptClaimsAndForgedOriginals() throws {
        let claimedScriptManifest = TanManifest(
            id: NokoNativeTanID.appleMusicPresence,
            name: "Fake Apple Music Presence",
            version: "1.0.0",
            description: "A script claiming the reserved native ID.",
            authors: ["untrusted-author"],
            target: .isolated,
            entry: "main.js"
        )
        assertTanInvalid(try claimedScriptManifest.validate())

        let claimedScript = TanPackage(
            manifest: claimedScriptManifest,
            javascript: "globalThis.claimedNativeID = true;",
            css: nil,
            origin: "Local package"
        )
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TanManager(root: root)
        assertTanInvalid(try manager.importDecision(for: claimedScript))
        assertTanInvalid(try manager.install(claimedScript))

        let forgedNative = TanPackage(
            manifest: TanManifest(
                id: NokoNativeTanID.appleMusicPresence,
                name: "Forged Apple Music Presence",
                version: "9.9.9",
                description: "A forged native-package claim.",
                authors: ["untrusted-author"],
                target: .native
            ),
            javascript: nil,
            css: nil,
            origin: "Noko Original"
        )
        XCTAssertNoThrow(try forgedNative.validate(), "The persisted-package authenticity check must reject this hash, not just its manifest shape")
        assertTanInvalid(try manager.install(forgedNative))
    }

    func testBundledOriginalsPreserveSuppliedAssetsAndMorganaWakePatch() throws {
        let expected: [(String, String, TanTarget, String)] = [
            ("noko.chat", "1.6.5", .isolated, "11b2b65ad10453292c27626e4836ec0240dd098b47b2cb71f604298dcf06b0b8"),
            ("noko.link-fixer", "1.1.0", .isolated, "c698116aded693596d802257ca0f72a7a00620618f924930e96b693ffcf716f3"),
            ("noko.morgana", "1.1.1", .page, "6c3f2a2eda5c629230ee4a12df2290543f8e316316077590b276656485f97257")
        ]
        for (id, version, target, sourceHash) in expected {
            let package = try XCTUnwrap(TanPackage.originals.first { $0.id == id })
            XCTAssertEqual(package.manifest.version, version)
            XCTAssertEqual(package.manifest.target, target)
            XCTAssertEqual(package.origin, "Noko Original")
            let javascript = try XCTUnwrap(package.javascript)
            let hash = SHA256.hash(data: Data(javascript.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, sourceHash)
            XCTAssertNoThrow(try package.validate())
            if id == "noko.morgana" {
                let prefix = "const CUSTOM_SOUND_BASE64 = \""
                let suffix = "\";"
                let audio = try XCTUnwrap(javascript.components(separatedBy: prefix).dropFirst().first?.components(separatedBy: suffix).first)
                let audioData = try XCTUnwrap(Data(base64Encoded: audio))
                let audioHash = SHA256.hash(data: audioData).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(audioHash, "7679719d508c10d289a008b06602830a522deb437a000c5462c43abe17111f64")
            }
        }
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

    func testTanManagerNotifiesNativeServicesWhenEnablementOrSafeModeChanges() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TanManager(root: root, launchSafeMode: false)
        let package = TanPackage(manifest: isolatedManifest(id: "fixture.activity-hook"), javascript: "export default {}", css: nil, origin: "Local fixture")
        try manager.install(package)

        var notifications = 0
        let observer = manager.addChangeObserver { notifications += 1 }
        manager.setEnabled(package.id, true)
        manager.setSafeMode(true)
        manager.setEnabled(package.id, false)
        XCTAssertEqual(notifications, 3)
        manager.removeChangeObserver(observer)
        manager.setSafeMode(false)
        XCTAssertEqual(notifications, 3)
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

    func testReplacementRequiresMatchingIDAndPreservesCompatibleEnabledState() throws {
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

        assertTanInvalid(try manager.replaceInstalled(wrongID))
        try manager.replaceInstalled(replacement)

        XCTAssertEqual(manager.installed.count, 1)
        XCTAssertEqual(manager.installed[0].id, original.id)
        XCTAssertNotEqual(manager.installed[0].contentHash, originalHash)
        XCTAssertTrue(manager.enabledIDs.contains(original.id))
        assertTanInvalid(try manager.install(replacement))

        let restarted = TanManager(root: root)
        XCTAssertEqual(restarted.installed.count, 1)
        XCTAssertEqual(restarted.installed[0].contentHash, manager.installed[0].contentHash)
        XCTAssertTrue(restarted.enabledIDs.contains(original.id))
        assertTanInvalid(try restarted.install(replacement))
    }

    func testImportDecisionUsesPackageIDAndVersionBeforeCosmeticNameSimilarity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        func package(_ id: String, _ name: String, _ version: String) -> TanPackage {
            TanPackage(manifest: TanManifest(id: id, name: name, version: version,
                                             description: "Fixture", authors: ["fixture-author"],
                                             target: .css, stylesheet: "style.css"),
                       javascript: nil, css: ".fixture {}", origin: "Local package")
        }
        let manager = TanManager(root: root)
        try manager.install(package("fixture.chat", "Noko-Chat", "1.5.0"))
        if case .update = try manager.importDecision(for: package("fixture.chat", "Noko Chat", "1.6.0")) {} else { XCTFail("Expected update") }
        if case .reinstall = try manager.importDecision(for: package("fixture.chat", "Noko Chat", "1.5.0")) {} else { XCTFail("Expected reinstall") }
        if case .downgrade = try manager.importDecision(for: package("fixture.chat", "Noko Chat", "1.4.0")) {} else { XCTFail("Expected downgrade") }
        if case .similarName = try manager.importDecision(for: package("fixture.other", "noko_chat", "1.0.0")) {} else { XCTFail("Expected similar-name warning") }
        if case .install = try manager.importDecision(for: package("fixture.unrelated", "Different Tan", "1.0.0")) {} else { XCTFail("Expected normal install") }
    }

    func testReplacementValidationFailureKeepsInstalledPackageAndTrustChangeDisablesIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = TanPackage(manifest: cssManifest(id: "fixture.trust"), javascript: nil,
                                  css: ".original {}", origin: "Local package")
        let manager = TanManager(root: root)
        try manager.install(original)
        manager.setEnabled(original.id, true)
        let invalid = TanPackage(manifest: original.manifest, javascript: nil,
                                 css: String(repeating: "x", count: 512 * 1024 + 1), origin: "Local package")
        assertTanInvalid(try manager.replaceInstalled(invalid))
        XCTAssertEqual(manager.installed.first?.contentHash, original.contentHash)
        XCTAssertTrue(manager.enabledIDs.contains(original.id))

        let changed = TanPackage(manifest: TanManifest(id: original.id, name: original.manifest.name,
                                                      version: "1.1.0", description: "Fixture",
                                                      authors: ["another-author"], target: .css,
                                                      stylesheet: "style.css"),
                                 javascript: nil, css: ".replacement {}", origin: "Local package")
        try manager.replaceInstalled(changed)
        XCTAssertFalse(manager.enabledIDs.contains(original.id))
        let restarted = TanManager(root: root)
        XCTAssertEqual(restarted.installed.first?.contentHash, changed.contentHash)
        XCTAssertFalse(restarted.enabledIDs.contains(original.id))
    }

    func testReplacingTranslatedTanRemovesItsObsoleteSourceArchive() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = TanPackage(manifest: cssManifest(id: "fixture.translation"),
                                  javascript: nil, css: ".old {}", origin: "Translated Tan")
        let manager = TanManager(root: root)
        try manager.install(original)
        let archive = root.appendingPathComponent(original.id + ".source.json")
        try Data("fixture".utf8).write(to: archive)
        let replacement = TanPackage(manifest: original.manifest,
                                     javascript: nil, css: ".new {}", origin: "Local package")
        try manager.replaceInstalled(replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(manager.installed.first?.contentHash, replacement.contentHash)
    }

    func testOfficialBundledUpdatePreservesCompatibleEnabledStateAcrossRestart() throws {
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
        XCTAssertNotEqual(oldPackage.contentHash, original.contentHash)
        XCTAssertEqual(manager.availableOriginalUpdate(oldPackage)?.contentHash, original.contentHash)

        try manager.updateOriginal(oldPackage.id)
        XCTAssertEqual(manager.installed.first?.contentHash, original.contentHash)
        XCTAssertEqual(manager.installed.first?.origin, original.origin)
        XCTAssertEqual(manager.enabledIDs, Set([original.id]))

        let restarted = TanManager(root: root)
        XCTAssertEqual(restarted.installed.first?.contentHash, original.contentHash)
        XCTAssertEqual(restarted.enabledIDs, Set([original.id]))
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

    func testNewerBundledVersionCanReplaceLocalSameIDOnlyAfterExplicitUpdate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = try XCTUnwrap(TanPackage.originals.first(where: { $0.id == "noko.morgana" }))
        var previousManifest = bundled.manifest
        previousManifest = TanManifest(schemaVersion: previousManifest.schemaVersion,
                                       id: previousManifest.id, name: previousManifest.name,
                                       version: "1.1.0", description: previousManifest.description,
                                       authors: previousManifest.authors, target: previousManifest.target,
                                       entry: previousManifest.entry, stylesheet: previousManifest.stylesheet,
                                       capabilities: previousManifest.capabilities,
                                       requiresReload: previousManifest.requiresReload,
                                       source: previousManifest.source, license: previousManifest.license)
        let local = TanPackage(manifest: previousManifest, javascript: bundled.javascript,
                               css: bundled.css, origin: "Local package")
        let manager = TanManager(root: root)
        try manager.install(local)
        manager.setEnabled(local.id, true)
        XCTAssertEqual(manager.availableOriginalUpdate(local)?.manifest.version, "1.1.1")
        XCTAssertEqual(manager.installed.first?.contentHash, local.contentHash)
        try manager.updateOriginal(local.id)
        XCTAssertEqual(manager.installed.first?.contentHash, bundled.contentHash)
        XCTAssertFalse(manager.enabledIDs.contains(local.id))
        let restarted = TanManager(root: root)
        XCTAssertEqual(restarted.installed.first?.contentHash, bundled.contentHash)
        XCTAssertFalse(restarted.enabledIDs.contains(local.id))
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
}
