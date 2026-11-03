// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChargeCap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "smc-rw", targets: ["smc-rw"]),
    ],
    targets: [
        // Thin C wrapper around the AppleSMC IOKit user client.
        .target(
            name: "CSMC",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Phase 0 tool: read any SMC key, write only allow-listed charging keys.
        .executableTarget(
            name: "smc-rw",
            dependencies: ["CSMC"]
        ),
    ]
)
