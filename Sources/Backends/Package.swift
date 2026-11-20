// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FGBackends",
    platforms: [.macOS("26.0")],
    products: [.library(name: "FGBackends", type: .dynamic, targets: ["FGBackends"])],
    dependencies: [.package(path: "../RifeRuntime")],
    targets: [
        .target(name: "FGBackends", dependencies: [.product(name: "RifeMetal", package: "RifeRuntime")]),
    ]
)
