// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FridayApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FridayCore", targets: ["FridayCore"]),
        .executable(name: "Friday", targets: ["FridayApp"]),
        .executable(name: "TestRunner", targets: ["TestRunner"])
    ],
    targets: [
        .target(
            name: "FridayCore",
            dependencies: [],
            path: "Sources/FridayCore"
        ),
        .executableTarget(
            name: "FridayApp",
            dependencies: ["FridayCore"],
            path: "Sources/FridayApp"
        ),
        .executableTarget(
            name: "TestRunner",
            dependencies: ["FridayCore"],
            path: "Sources/TestRunner"
        )
    ]
)
