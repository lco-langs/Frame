// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FrameTests",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "t_frame", targets: ["FrameTestFlows"]),
        .executable(name: "t_roots", targets: ["RootsTests"])
    ],
    dependencies: [
        .package(url: "https://github.com/leviouwendijk/Errors.git", branch: "master"),
        .package(url: "https://github.com/swift-langs/Grammar.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/IO.git", branch: "master"),
        .package(url: "https://github.com/swift-langs/Parsing.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Position.git", branch: "master"),
        .package(url: "https://github.com/swift-tooling/Testing.git", branch: "master"),
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(name: "FrameTestFlows", dependencies: [
            .product(name: "Errors", package: "Errors"),
            .product(name: "Frame", package: "Frame"),
            .product(name: "Grammar", package: "Grammar"),
            .product(name: "GrammarParsing", package: "Parsing"),
            .product(name: "GrammarTreeSitter", package: "Grammar"),
            .product(name: "Testing", package: "Testing"),
            .product(name: "Position", package: "Position")
        ]),
        .executableTarget(name: "RootsTests", dependencies: [
            .product(name: "Frame", package: "Frame"),
            .product(name: "Roots", package: "Frame"),
            .product(name: "IO", package: "IO"),
            .product(name: "Testing", package: "Testing")
        ])
    ]
)
