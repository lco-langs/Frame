// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Frame",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Frame", targets: ["Frame"]),
        .library(name: "Roots", targets: ["Roots"]),
        .executable(name: "frame_generate", targets: ["FrameGenerate"]),
        .executable(name: "frame", targets: ["FrameCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-lco/Errors.git", branch: "master"),
        .package(url: "https://github.com/swift-langs/Grammar.git", branch: "master"),
        .package(url: "https://github.com/swift-lco/IO.git", branch: "master"),
        .package(url: "https://github.com/swift-langs/Parsing.git", branch: "master"),
        .package(url: "https://github.com/swift-lco/Position.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "Frame",
            dependencies: [
                .product(name: "Errors", package: "Errors"),
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "GrammarParsing", package: "Parsing"),
                .product(name: "IO", package: "IO"),
                .product(name: "Parsing", package: "Parsing"),
                .product(name: "Position", package: "Position"),
            ]),
        // private and shared roots: directories laid out like a home (.config/<app>/, .agentic/)
        .target(
            name: "Roots",
            dependencies: [
                "Frame",
                .product(name: "IO", package: "IO"),
            ]),
        .executableTarget(name: "FrameCLI", dependencies: ["Frame"]),
        .executableTarget(
            name: "FrameGenerate",
            dependencies: [
                "Frame", .product(name: "GrammarTreeSitter", package: "Grammar"),
            ]),
    ]
)
