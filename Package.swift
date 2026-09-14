// swift-tools-version: 5.9
import PackageDescription

// No `platforms:` on purpose. The first models here are pure values — an ID, a
// unit descriptor and a manifest that indexes them — and none of them depends
// on a deployment target. Declaring one now would be a claim about the whole
// package that only the first two files support.
let package = Package(
    name: "NagiEngineCore",
    products: [
        .library(name: "NagiEngineCore", targets: ["NagiEngineCore"])
    ],
    targets: [
        .target(name: "NagiEngineCore"),
        .testTarget(name: "NagiEngineCoreTests", dependencies: ["NagiEngineCore"])
    ]
)
