// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Witthues",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Witthues", targets: ["Witthues"]),
        .executable(name: "witthues-cli", targets: ["WitthuesCLI"]),
    ],
    targets: [
        .target(name: "WitthuesCore"),
        .executableTarget(name: "Witthues", dependencies: ["WitthuesCore"]),
        .executableTarget(name: "WitthuesCLI", dependencies: ["WitthuesCore"]),
        .testTarget(name: "WitthuesCoreTests", dependencies: ["WitthuesCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
