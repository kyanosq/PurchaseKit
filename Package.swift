// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PurchaseKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "PurchaseKit", targets: ["PurchaseKit"])
    ],
    targets: [
        .target(
            name: "PurchaseKit",
            path: "Sources/PurchaseKit",
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "PurchaseKitTests",
            dependencies: ["PurchaseKit"],
            path: "Tests/PurchaseKitTests",
            resources: [.copy("PurchaseKitTest.storekit")]
        )
    ]
)
