// swift-tools-version: 5.9
import PackageDescription

// The client in Sources/APIClient/Generated is generated from spec/openapi.yaml by scripts/generate-api-client.sh.
let package = Package(
    name: "APIClient",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "APIClient", targets: ["APIClient"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-http-types", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "APIClient",
            dependencies: [
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ]
        )
    ]
)
