// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NokoCordCore",
    platforms: [.macOS("26.6")],
    products: [.library(name: "NokoCordCore", targets: ["NokoCordCore"])],
    targets: [
        .target(name: "NokoCordCore", path: "NokoCord", exclude: ["NokoCordApp.swift", "ContentView.swift", "Assets.xcassets", "Views", "Media"], sources: ["Models", "Discord", "Persistence", "Store", "Services"], resources: [.process("Resources")]),
        .testTarget(name: "NokoCordCoreTests", dependencies: ["NokoCordCore"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
