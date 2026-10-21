// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "TDSCarKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "TDSCarKitCore", targets: ["TDSCarKitCore"])],
    targets: [
        .target(name: "CTDSCarKitCrypto"),
        .target(name: "TDSCarKitCore", dependencies: ["CTDSCarKitCrypto"]),
        .testTarget(name: "TDSCarKitCoreTests", dependencies: ["TDSCarKitCore"])
    ]
)
