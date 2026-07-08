// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BiSpell",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BiSpellCore", targets: ["BiSpellCore"]),
        .executable(name: "BiSpell", targets: ["BiSpellApp"]),
    ],
    targets: [
        .target(
            name: "BiSpellCore",
            resources: [
                .copy("Resources/Dictionaries")
            ]
        ),
        .executableTarget(
            name: "BiSpellApp",
            dependencies: ["BiSpellCore"]
        ),
        .testTarget(
            name: "BiSpellCoreTests",
            dependencies: ["BiSpellCore"]
        ),
    ]
)
