// swift-tools-version:5.10
import PackageDescription

// s1print — developed by Marvin Quevedo (https://github.com/MarvinQuevedo/s1print)

let package = Package(
    name: "s1print",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "S1Kit", targets: ["S1Kit"]),
        .executable(name: "s1print", targets: ["s1print"]),
    ],
    targets: [
        // Platform-independent core: raster decoding, dithering, S1 command encoding.
        .target(name: "S1Kit"),
        // macOS executable: Bluetooth transport, CLI, menu-bar bridge.
        .executableTarget(name: "s1print", dependencies: ["S1Kit"]),
        .testTarget(name: "S1KitTests", dependencies: ["S1Kit"]),
    ]
)
