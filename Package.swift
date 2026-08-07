// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PurchaseKit",
    // 源码里的 `@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)` 是这个包对外的承诺，
    // 清单必须与之一致。只声明 .iOS 时，其余平台回落到 SwiftPM 的远古默认部署目标（macOS 10.13），
    // `os.Logger`（macOS 11+）无法编译——后果不是「macOS 上不可用」，而是命令行 `swift build` /
    // `swift test` 根本跑不起来，整套单元测试因此从未进过任何门禁。
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
        .tvOS(.v17)
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
