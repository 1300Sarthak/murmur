// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CParakeet", path: "Sources/CParakeet"),
        .executableTarget(
            name: "Murmur",
            dependencies: ["CParakeet"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])],
            linkerSettings: [.unsafeFlags(["-L/opt/homebrew/lib", "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib"])]
        ),
    ]
)
