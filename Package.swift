// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Explicit development mode for testing file operations without the macOS 27 SDK.
let withoutCoreAI = ProcessInfo.processInfo.environment["SEIRI_WITHOUT_COREAI"] == "1"
let package = Package(
    name: "seiri",
    platforms: [.macOS(withoutCoreAI ? "13.0" : "27.0")],
    products: [.executable(name: "seiri", targets: ["seiri"])],
    dependencies: withoutCoreAI ? [] : [
        .package(url: "https://github.com/apple/coreai-models.git",
                 revision: "e7b24da85ea64a77d26324d7ce9607de9b955f57")
    ],
    targets: [
        .target(name: "SeiriCore"),
        .executableTarget(name: "seiri", dependencies: [.target(name: "SeiriCore")] +
            (withoutCoreAI ? [] : [.product(name: "CoreAILM", package: "coreai-models")]),
            swiftSettings: withoutCoreAI ? [.define("WITHOUT_COREAI")] : [])
    ] + (withoutCoreAI ? [
        .executableTarget(name: "SeiriChecks", dependencies: ["SeiriCore"], path: "Tests/SeiriCoreTests")
    ] : [])
)
