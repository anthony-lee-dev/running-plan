// swift-tools-version: 5.9
import PackageDescription

// Only here to run Apple's swift-openapi-generator from scripts/generate-api-client.sh. The app does not depend on
// it: generated code is committed, so building needs no build-tool plugin (Xcode asks a human to trust those).
let package = Package(
    name: "APIClientGenerator",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.10.0")],
    targets: [.target(name: "Placeholder")]
)
