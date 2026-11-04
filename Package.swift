// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TurnSTYLE",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TurnSTYLE", targets: ["TurnSTYLE"]),
        .executable(name: "turnstyle-hook", targets: ["TurnSTYLEHook"]),
        .executable(name: "TurnStyleChecks", targets: ["TurnStyleChecks"]),
    ],
    targets: [
        .target(name: "TurnStyleCore"),
        .executableTarget(name: "TurnSTYLE", dependencies: ["TurnStyleCore"]),
        .executableTarget(name: "TurnSTYLEHook", dependencies: ["TurnStyleCore"]),
        .executableTarget(name: "TurnStyleChecks", dependencies: ["TurnStyleCore"], path: "Tests/TurnStyleCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
