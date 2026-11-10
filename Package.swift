// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tunnels",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tunnels", targets: ["Tunnels"])
    ],
    targets: [
        .target(name: "TunnelsCore"),
        .executableTarget(name: "Tunnels", dependencies: ["TunnelsCore"]),
        .testTarget(name: "TunnelsCoreTests", dependencies: ["TunnelsCore"])
    ]
)
