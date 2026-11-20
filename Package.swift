// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Size",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SizeCore", targets: ["SizeCore"]),
        .library(name: "SizeAX", targets: ["SizeAX"]),
        .library(name: "SizeSpaces", targets: ["SizeSpaces"]),
        .executable(name: "size-cli", targets: ["size-cli"]),
        .executable(name: "Size", targets: ["SizeApp"]),
        .executable(name: "size-testhost", targets: ["SizeTestHost"])
    ],
    targets: [
        .target(name: "SizeCore"),
        .target(name: "SizeAX", dependencies: ["SizeCore"]),
        .target(name: "SizeSpaces", dependencies: ["SizeCore", "SizeAX"]),
        .executableTarget(
            name: "SizeApp",
            dependencies: ["SizeCore", "SizeAX", "SizeSpaces"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(name: "size-cli", dependencies: ["SizeCore", "SizeAX", "SizeSpaces"]),
        // A plain window used by the automated self-test, so verification never
        // touches the user's own windows.
        .executableTarget(name: "SizeTestHost", dependencies: ["SizeCore"]),
        .testTarget(name: "SizeCoreTests", dependencies: ["SizeCore"])
    ]
)
