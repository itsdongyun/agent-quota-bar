// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "agent-quota-bar",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "AgentQuotaCore",
            targets: ["AgentQuotaCore"]
        ),
        .executable(
            name: "AgentQuotaBar",
            targets: ["AgentQuotaBar"]
        ),
    ],
    targets: [
        .target(
            name: "AgentQuotaCore",
            path: "Sources/AgentQuotaCore"
        ),
        .executableTarget(
            name: "AgentQuotaBar",
            dependencies: ["AgentQuotaCore"],
            path: "Sources/AgentQuotaBar",
            exclude: ["Resources/Info.plist"],
            resources: [
                .process("Resources/en.lproj"),
                .process("Resources/ko.lproj"),
            ]
        ),
        .testTarget(
            name: "AgentQuotaCoreTests",
            dependencies: ["AgentQuotaCore"],
            path: "Tests/AgentQuotaCoreTests"
        ),
    ]
)
