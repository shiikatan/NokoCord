import Foundation
import XCTest
@testable import NokoCordCore

@MainActor
final class TanTranslationTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NokoCord-TanTranslationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func assertInvalidSource(_ expression: @autoclosure () throws -> Any,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let translationError = error as? TanTranslationError else {
                return XCTFail("Expected TanTranslationError, got \(error)", file: file, line: line)
            }
            guard case .invalidSource = translationError else {
                return XCTFail("Expected invalidSource, got \(translationError)", file: file, line: line)
            }
        }
    }

    func testReadSourceAcceptsSupportedEntryNames() throws {
        for entry in ["index.ts", "index.tsx", "index.js", "index.jsx"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try write("export default {};", to: root.appendingPathComponent(entry))
            try write("MIT fixture license", to: root.appendingPathComponent("LICENSE"))
            let files = try TanTranslationService.readSource(root)
            XCTAssertEqual(files[entry], "export default {};", entry)
            XCTAssertEqual(files["LICENSE"], "MIT fixture license", entry)
        }
    }

    func testReadSourceRetainsLicenseAndNestedRegularFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("export default {};", to: root.appendingPathComponent("index.ts"))
        try write("Copyright fixture", to: root.appendingPathComponent("LICENSE.txt"))
        try write("export const helper = true;", to: nested.appendingPathComponent("helper.ts"))

        let files = try TanTranslationService.readSource(root)
        XCTAssertEqual(Set(files.keys), Set(["index.ts", "LICENSE.txt", "fixtures/helper.ts"]))
        XCTAssertEqual(files["LICENSE.txt"], "Copyright fixture")
        XCTAssertEqual(files["fixtures/helper.ts"], "export const helper = true;")
    }

    func testReadSourceRejectsBinaryFilesSymlinksPrivateEnvAndOversizeFolders() throws {
        let binaryRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: binaryRoot) }
        try Data([0x00, 0xFF, 0x10]).write(to: binaryRoot.appendingPathComponent("index.ts"))
        assertInvalidSource(try TanTranslationService.readSource(binaryRoot))

        let symlinkRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: symlinkRoot) }
        let outside = symlinkRoot.deletingLastPathComponent().appendingPathComponent("tan-source-outside.ts")
        defer { try? FileManager.default.removeItem(at: outside) }
        try write("export default {};", to: outside)
        try FileManager.default.createSymbolicLink(at: symlinkRoot.appendingPathComponent("index.ts"), withDestinationURL: outside)
        assertInvalidSource(try TanTranslationService.readSource(symlinkRoot))

        let envRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: envRoot) }
        try write("export default {};", to: envRoot.appendingPathComponent("index.ts"))
        try write("TOKEN=fixture", to: envRoot.appendingPathComponent(".env"))
        assertInvalidSource(try TanTranslationService.readSource(envRoot))

        let oversizedRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: oversizedRoot) }
        try Data(repeating: 0x78, count: 2 * 1024 * 1024 + 1).write(to: oversizedRoot.appendingPathComponent("index.ts"))
        assertInvalidSource(try TanTranslationService.readSource(oversizedRoot))
    }

    func testReadSourceRejectsMissingEntryFolderAndSymlinkRoot() throws {
        let missing = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: missing) }
        try write("MIT fixture license", to: missing.appendingPathComponent("LICENSE"))
        assertInvalidSource(try TanTranslationService.readSource(missing))

        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let actual = parent.appendingPathComponent("actual", isDirectory: true)
        let link = parent.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try write("export default {};", to: actual.appendingPathComponent("index.ts"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        assertInvalidSource(try TanTranslationService.readSource(link))
    }

    func testTranslationResultDecodesAndBuildsInstallablePackage() throws {
        let manifest = #"""
        {"schemaVersion":1,"id":"fixture.translated","name":"Translated Fixture","description":"A translated fixture.","authors":["fixture-author"],"version":"0.1.0","target":"isolated","entry":"main.js","stylesheet":"style.css","capabilities":[],"requiresReload":false}
        """#
        let payloadObject: [String: Any] = [
            "report": ["classification": "Automatic", "installable": true, "source": "Local source",
                        "schemaVersion": 1, "translatorVersion": "fixture-version",
                        "compiler": "fixture-compiler", "entry": "index.ts",
                        "limitations": ["Fixture compatibility limitation"],
                        "files": [["path": "index.ts", "sha256": "fixture-hash"]],
                        "licenses": ["LICENSE"], "findings": []],
            "outputs": ["manifest.json": manifest, "main.js": "NokoTan.register({start() {}, stop() {}});",
                         "style.css": ".fixture {}", "LICENSE": "MIT fixture license"]
        ]
        let payload = try JSONSerialization.data(withJSONObject: payloadObject)
        let result = try JSONDecoder().decode(TanTranslationResult.self, from: payload)
        let package = try result.package()
        XCTAssertTrue(result.report.installable)
        XCTAssertEqual(result.report.licenses, ["LICENSE"])
        XCTAssertEqual(package.id, "fixture.translated")
        XCTAssertEqual(package.origin, "Translated Tan")
        XCTAssertEqual(package.css, ".fixture {}")
        XCTAssertNoThrow(try package.validate())
    }

    func testNonInstallableTranslationResultCannotBuildPackage() throws {
        let payload = #"""
        {"report":{"classification":"Unsupported","installable":false,"source":"Local source","files":[],"licenses":[],"findings":[{"code":"dynamic-code","category":"Unsupported"}]},"outputs":{}}
        """#
        let result = try JSONDecoder().decode(TanTranslationResult.self, from: Data(payload.utf8))
        XCTAssertThrowsError(try result.package()) { error in
            guard let translationError = error as? TanTranslationError else {
                return XCTFail("Expected TanTranslationError, got \(error)")
            }
            guard case .unsupported = translationError else {
                return XCTFail("Expected unsupported, got \(translationError)")
            }
        }
    }

    func testInconsistentTranslationReportCannotBuildPackage() throws {
        let manifest = #"{"schemaVersion":1,"id":"fixture.translated","name":"Translated Fixture","description":"Fixture","authors":["author"],"version":"0.1.0","target":"isolated","entry":"main.js","capabilities":[],"requiresReload":false}"#
        let reports: [(String, [[String: String]], [String])] = [
            ("Unsupported", [], []),
            ("Requires Native Adapter", [], []),
            ("Automatic", [["code": "dynamic-code", "category": "Unsupported"]], []),
            ("Assisted", [["code": "unmapped-import", "category": "Assisted"]], ["Unrelated adaptation"]),
            ("Assisted", [["code": "lifecycle-timing-adapted", "category": "Assisted"]], [])
        ]
        for (classification, findings, adaptations) in reports {
            let payload: [String: Any] = [
                "report": ["classification": classification, "installable": true, "source": "Fixture",
                           "files": [], "licenses": [], "findings": findings, "adaptations": adaptations],
                "outputs": ["manifest.json": manifest, "main.js": "NokoTan.register({start() {}, stop() {}});"]
            ]
            let result = try JSONDecoder().decode(TanTranslationResult.self,
                                                  from: JSONSerialization.data(withJSONObject: payload))
            XCTAssertThrowsError(try result.package(), classification)
        }
    }

    func testExplicitRepositorySourceIncludesOnlySelectedPluginAndSharedMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = root.appendingPathComponent("src/plugins/example")
        let utils = root.appendingPathComponent("src/utils")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: utils, withIntermediateDirectories: true)
        try "export default {};".write(to: plugin.appendingPathComponent("index.ts"), atomically: true, encoding: .utf8)
        try "Fixture license".write(to: root.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
        try "export const Devs = {};".write(to: utils.appendingPathComponent("constants.ts"), atomically: true, encoding: .utf8)
        try "Must not be read".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let files = try TanTranslationService.readRepositorySource(root, plugin: "example")
        XCTAssertEqual(Set(files.keys), ["index.ts", "_repository/LICENSE", "_repository/constants.ts"])
        assertInvalidSource(try TanTranslationService.readRepositorySource(root, plugin: "../example"))
        try FileManager.default.removeItem(at: utils.appendingPathComponent("constants.ts"))
        try FileManager.default.createSymbolicLink(at: utils.appendingPathComponent("constants.ts"), withDestinationURL: root.appendingPathComponent(".env"))
        assertInvalidSource(try TanTranslationService.readRepositorySource(root, plugin: "example"))
    }

    func testRepositoryPluginsReturnsSortedDirectoryNamesAndIgnoresRegularFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appendingPathComponent("src/plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        for name in ["zeta", "alpha", "middle.plugin", "under_score"] {
            try FileManager.default.createDirectory(at: plugins.appendingPathComponent(name), withIntermediateDirectories: false)
            try write("export default {};", to: plugins.appendingPathComponent(name).appendingPathComponent("index.ts"))
        }
        try FileManager.default.createDirectory(at: plugins.appendingPathComponent("_support"), withIntermediateDirectories: false)
        let linked = plugins.appendingPathComponent("linked-entry")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("index.ts"), withDestinationURL: plugins.appendingPathComponent("alpha/index.ts"))
        try write("fixture README", to: plugins.appendingPathComponent("README.md"))
        try write("fixture metadata", to: plugins.appendingPathComponent("package.json"))

        XCTAssertEqual(try TanTranslationService.repositoryPlugins(root),
                       ["alpha", "middle.plugin", "under_score", "zeta"])
    }

    func testRepositoryPluginsRejectsSymlinkedPluginsDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src", isDirectory: true)
        let actual = root.appendingPathComponent("actual-plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actual.appendingPathComponent("fixture"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: src.appendingPathComponent("plugins"), withDestinationURL: actual)

        assertInvalidSource(try TanTranslationService.repositoryPlugins(root))
    }

    func testRepositoryPluginsRejectsMoreThan512Entries() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appendingPathComponent("src/plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        for index in 0...512 {
            try FileManager.default.createDirectory(at: plugins.appendingPathComponent(String(format: "plugin-%03d", index)),
                                                    withIntermediateDirectories: false)
        }

        assertInvalidSource(try TanTranslationService.repositoryPlugins(root))
    }

    func testManagerPersistsTranslationSourceArchiveStartsDisabledAndUninstallsArchive() async throws {
        let manifest = #"""
        {"schemaVersion":1,"id":"fixture.manager-import","name":"Manager Import Fixture","description":"A translated manager fixture.","authors":["fixture-author"],"version":"0.1.0","target":"isolated","entry":"main.js","capabilities":[],"requiresReload":false}
        """#
        let payloadObject: [String: Any] = [
            "report": ["classification": "Assisted", "installable": true, "source": "Local source",
                        "schemaVersion": 1, "translatorVersion": "fixture-version",
                        "compiler": "fixture-compiler", "entry": "index.ts",
                        "limitations": ["Fixture compatibility limitation"],
                        "adaptations": ["Fixture explicit startup adaptation"],
                        "files": [["path": "index.ts", "sha256": "fixture-hash"]],
                        "licenses": ["LICENSE"],
                        "findings": [["code": "lifecycle-timing-adapted", "category": "Assisted"]]],
            "outputs": ["manifest.json": manifest, "main.js": "NokoTan.register({start() {}, stop() {}});",
                         "LICENSE": "MIT fixture license"]
        ]
        let result = try JSONDecoder().decode(TanTranslationResult.self,
                                              from: JSONSerialization.data(withJSONObject: payloadObject))
        let source = ["index.ts": "export default {};", "LICENSE": "MIT fixture license", "fixtures/helper.ts": "export const fixture = true;"]
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TanManager(root: root)

        try manager.installTranslation(result, source: source)
        XCTAssertEqual(manager.installed.map(\.id), ["fixture.manager-import"])
        XCTAssertTrue(manager.enabledIDs.isEmpty, "Imported Tans must start disabled")
        let packageURL = root.appendingPathComponent("fixture.manager-import.tan.json")
        let archiveURL = root.appendingPathComponent("fixture.manager-import.source.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))

        let archive = try JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any]
        let archivedFiles = archive?["files"] as? [String: String]
        let archivedReport = archive?["report"] as? [String: Any]
        XCTAssertEqual(archivedReport?["schemaVersion"] as? Int, 1)
        XCTAssertEqual(archivedReport?["translatorVersion"] as? String, "fixture-version")
        XCTAssertEqual(archivedReport?["compiler"] as? String, "fixture-compiler")
        XCTAssertEqual(archivedReport?["entry"] as? String, "index.ts")
        XCTAssertEqual(archivedReport?["limitations"] as? [String], ["Fixture compatibility limitation"])
        XCTAssertEqual(archivedReport?["adaptations"] as? [String], ["Fixture explicit startup adaptation"])
        XCTAssertEqual(archivedFiles?["LICENSE"], source["LICENSE"])
        XCTAssertEqual(archivedFiles?["fixtures/helper.ts"], source["fixtures/helper.ts"])

        let restoredReport = try await manager.translationReport(for: "fixture.manager-import")
        XCTAssertEqual(restoredReport?.adaptations, ["Fixture explicit startup adaptation"])
        XCTAssertEqual(restoredReport?.licenses, ["LICENSE"])

        let restarted = TanManager(root: root)
        XCTAssertEqual(restarted.installed.map(\.id), ["fixture.manager-import"])
        XCTAssertTrue(restarted.enabledIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))

        try restarted.uninstall("fixture.manager-import")
        XCTAssertTrue(restarted.installed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        let afterUninstall = TanManager(root: root)
        XCTAssertTrue(afterUninstall.installed.isEmpty)
    }
}
