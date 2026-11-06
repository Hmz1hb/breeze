// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Breeze",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Breeze", targets: ["FanApp"]),
        .executable(name: "BreezeHelper", targets: ["FanHelper"]),
        .executable(name: "BreezeMCP", targets: ["BreezeMCP"])
    ],
    targets: [
        .target(name: "CHardware", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Security"), .linkedFramework("CoreFoundation")]),
        .target(name: "FanCore", dependencies: ["CHardware"]),
        .target(name: "StorageCore", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit"), .linkedFramework("CoreServices")]),
        .target(name: "CleanupAssistant", dependencies: ["StorageCore"]),
        .target(name: "NetworkCore", linkerSettings: [.linkedFramework("CoreWLAN"), .linkedFramework("SystemConfiguration")]),
        .executableTarget(name: "FanApp", dependencies: ["FanCore", "CHardware", "StorageCore", "NetworkCore", "CleanupAssistant"]),
        .executableTarget(name: "FanHelper", dependencies: ["FanCore", "CHardware"]),
        .executableTarget(name: "BreezeMCP", dependencies: ["CleanupAssistant", "StorageCore"]),
        .testTarget(name: "FanCoreTests", dependencies: ["FanCore"]),
        .testTarget(name: "StorageCoreTests", dependencies: ["StorageCore"]),
        .testTarget(name: "NetworkCoreTests", dependencies: ["NetworkCore"]),
        .testTarget(name: "FanAppTests", dependencies: ["FanApp", "StorageCore"])
    ]
)
