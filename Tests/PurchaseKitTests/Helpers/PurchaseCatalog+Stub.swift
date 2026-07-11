import PurchaseKit

/// 测试/预览占位目录。仅存在于测试目标，绝不作为生产默认 catalog。
extension PurchaseCatalog {
    static var stub: PurchaseCatalog {
        PurchaseCatalog(
            subscriptionIDs: [.monthly: "stub.month", .yearly: "stub.year"],
            lifetimeIDs: [.lifetime: "stub.lifetime"]
        )
    }
}
