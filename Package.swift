// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let editionConfig = packageRoot.appendingPathComponent("Config/Edition.xcconfig")

func canonicalMetadataValue(_ key: String) -> String {
    guard let contents = try? String(contentsOf: editionConfig, encoding: .utf8) else {
        fatalError("Unable to read canonical metadata at Config/Edition.xcconfig")
    }

    for rawLine in contents.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("//"), let separator = line.firstIndex(of: "=") else {
            continue
        }
        let name = line[..<separator].trimmingCharacters(in: .whitespaces)
        guard name == key else { continue }
        let value = line[line.index(after: separator)...]
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
    }

    fatalError("Missing canonical metadata key \(key) in Config/Edition.xcconfig")
}

let package = Package(
    name: "NokoCordCore",
    platforms: [.macOS(canonicalMetadataValue("NOKO_DEPLOYMENT_TARGET"))],
    products: [.library(name: "NokoCordCore", targets: ["NokoCordCore"])],
    targets: [
        .target(name: "NokoCordCore", path: "NokoCord", exclude: ["NokoCordApp.swift", "ContentView.swift", "Assets.xcassets", "Views", "Media"], sources: ["Models", "Discord", "Persistence", "Store", "Services"], resources: [.copy("Resources")]),
        .testTarget(name: "NokoCordCoreTests", dependencies: ["NokoCordCore"], path: "Tests", resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
