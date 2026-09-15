// swift-tools-version: 5.9
import PackageDescription

// Still no `platforms:` floor, and the reason is now more specific than it was.
//
// `NagiEngineCore` is the platform-neutral value layer it always was: no
// Apple-only framework, no deployment target. `NagiEngineCoreText` links
// CoreText, so it is Apple-only. Whether a given build covers every target
// therefore depends on which product or target was chosen and on conditional
// compilation — it is not a property of the package as a whole, and declaring a
// minimum OS here would state a deployment requirement nobody has decided yet.
let package = Package(
    name: "NagiEngineCore",
    products: [
        .library(name: "NagiEngineCore", targets: ["NagiEngineCore"]),
        .library(name: "NagiEngineCoreText", targets: ["NagiEngineCoreText"])
    ],
    targets: [
        .target(name: "NagiEngineCore"),
        .target(
            name: "NagiEngineCoreText",
            dependencies: ["NagiEngineCore"],
            linkerSettings: [.linkedFramework("CoreText")]
        ),
        .testTarget(name: "NagiEngineCoreTests", dependencies: ["NagiEngineCore"]),
        .testTarget(
            name: "NagiEngineCoreTextTests",
            dependencies: ["NagiEngineCoreText", "NagiEngineCore"]
        )
    ]
)
