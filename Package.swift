// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChargeCap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "smc-rw", targets: ["smc-rw"]),
        .executable(name: "chargecapd", targets: ["chargecapd"]),
        .executable(name: "chargecap", targets: ["chargecap"]),
        .library(name: "ChargeCapCore", targets: ["ChargeCapCore"]),
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
        // Pure logic: limit config, the order of SMC writes, the engine. No IOKit, so tests use a fake SMC.
        .target(name: "ChargeCapCore"),
        // Everything that touches the machine: the SMC client, battery reading, power events, the log file.
        .target(
            name: "ChargeCapKit",
            dependencies: ["ChargeCapCore", "CSMC"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Root daemon: keeps the firmware limit in place (start, wake, power changes, every minute).
        .executableTarget(
            name: "chargecapd",
            dependencies: ["ChargeCapCore", "ChargeCapKit"]
        ),
        // Command line: status, limit, off, apply, logs.
        .executableTarget(
            name: "chargecap",
            dependencies: ["ChargeCapCore", "ChargeCapKit"]
        ),
        .testTarget(
            name: "ChargeCapCoreTests",
            dependencies: ["ChargeCapCore"]
        ),
    ]
)
