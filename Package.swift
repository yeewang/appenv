// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppEnv",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppEnvCore", targets: ["AppEnvCore"]),
        .executable(name: "AppEnvDesktop", targets: ["AppEnvDesktop"]),
        .executable(name: "appenv", targets: ["AppEnvCLI"])
    ],
    targets: [
        .target(name: "AppEnvCore"),
        .executableTarget(name: "AppEnvDesktop", dependencies: ["AppEnvCore"], path: "Sources/AppEnv"),
        .executableTarget(name: "AppEnvCLI", dependencies: ["AppEnvCore"]),
        .testTarget(name: "AppEnvCoreTests", dependencies: ["AppEnvCore"])
    ]
)
