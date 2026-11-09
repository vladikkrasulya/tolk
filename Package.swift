// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tolk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tolk", targets: ["Tolk"]),
        .executable(name: "tolk-cli", targets: ["tolk-cli"]),
    ],
    targets: [
        // Translation engine: no AppKit, testable from the CLI.
        .target(name: "TolkCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Menu-bar app: input (double Cmd+C) + UI. Wiring lives in AppDelegate.swift.
        .executableTarget(name: "Tolk", dependencies: ["TolkCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Dev tool: `swift run tolk-cli "text"` streams a translation to stdout.
        .executableTarget(name: "tolk-cli", dependencies: ["TolkCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
