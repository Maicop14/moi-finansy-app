// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Balance",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Balance", path: "App", resources: [.copy("ArchiveResources")]),
        .testTarget(name: "BalanceTests", dependencies: ["Balance"], path: "Tests", resources: [.copy("Fixtures")])
    ]
)
