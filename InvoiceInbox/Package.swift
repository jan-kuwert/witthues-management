// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InvoiceInbox",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "InvoiceInbox", targets: ["InvoiceInbox"]),
        .executable(name: "invoice-cli", targets: ["InvoiceCLI"]),
    ],
    targets: [
        .target(name: "InvoiceCore"),
        .executableTarget(name: "InvoiceInbox", dependencies: ["InvoiceCore"]),
        .executableTarget(name: "InvoiceCLI", dependencies: ["InvoiceCore"]),
        .testTarget(name: "InvoiceCoreTests", dependencies: ["InvoiceCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
