import XCTest
import StoreKit
@testable import PurchaseKit

/// `AppStore.sync()` 会弹 App Store 登录框，只应由用户显式动作触发。
///
/// 回到前台的处理器原本先 `sync()` 再刷新权益，而 `willEnterForeground` 在**冷启动**
/// 时也会发一次；它上面那道 6 小时节流读的是内存里的 `lastValidationTime`，冷启动时
/// 必然是 nil，于是节流形同虚设——有购买缓存的用户一打开 app 就被要求登录。
///
/// 这两条测试成对：一条钉住「前台刷新不 sync」，另一条钉住「恢复购买仍然 sync」。
/// 少了后者，把 `sync()` 从整个包里删光也能让前者变绿。
@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
final class ForegroundEntitlementRefreshTests: XCTestCase {

    /// 直接调处理器，不发通知：观察者的注册在 `#if canImport(UIKit)` 之下，包的测试
    /// 跑在 macOS 上，靠发通知会得到一条永远不执行的绿测试。
    func testEnteringForegroundNeverTriggersAnAppStoreSync() async throws {
        let cache = ForegroundDuePurchaseCache()
        let service = SyncCountingStoreKitService()

        let manager = await MainActor.run {
            StoreKitManager(catalog: .stub, config: .debug,
                            purchaseCache: cache, storeKitService: service)
        }

        await manager.handleAppWillEnterForeground()

        XCTAssertEqual(service.syncCallCount, 0,
                       "回前台刷新权益不该走 AppStore.sync()——那会弹登录框，冷启动时尤其明显")
    }

    /// 现状固化，不是本次修复的守卫：6 小时内验证过就整段跳过。sync() 拿掉之后，
    /// 这条节流是「回前台不做多余工作」剩下的唯一约束，值得钉住。
    func testRecentValidationSkipsTheForegroundRefresh() async throws {
        let cache = ForegroundDuePurchaseCache()
        cache.setLastValidationTime(Date())      // 刚刚验证过
        let service = SyncCountingStoreKitService()

        let manager = await MainActor.run {
            StoreKitManager(catalog: .stub, config: .debug,
                            purchaseCache: cache, storeKitService: service)
        }
        let before = cache.getLastForegroundCheckTime()

        await manager.handleAppWillEnterForeground()

        XCTAssertEqual(cache.getLastForegroundCheckTime(), before,
                       "6 小时内已验证过就该整段跳过")
    }

    /// 反向对照：显式「恢复购买」必须仍然 sync，否则上面那条测试毫无意义。
    func testRestorePurchasesStillSyncs() async throws {
        let cache = ForegroundDuePurchaseCache()
        let service = SyncCountingStoreKitService()

        let manager = await MainActor.run {
            StoreKitManager(catalog: .stub, config: .debug,
                            purchaseCache: cache, storeKitService: service)
        }

        try await manager.restorePurchases()

        XCTAssertEqual(service.syncCallCount, 1,
                       "恢复购买是用户显式动作，正是 AppStore.sync() 该出现的地方")
    }
}

/// 冷启动后「该检查了」的缓存：有购买记录、无冷却、从未验证过。
@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class ForegroundDuePurchaseCache: PurchaseCacheProtocol {
    private var purchases: Set<String> = ["com.js.dit.pro.yearly"]
    private var status: UserSubscriptionStatus? = .activeSubscriber
    private var validationTime: Date?          // 冷启动：从未验证
    private var loginRejectionTime: Date?
    private var foregroundCheckTime: Date?

    func getLastValidPurchases() -> Set<String> { purchases }
    func setLastValidPurchases(_ purchases: Set<String>) { self.purchases = purchases }
    func getLastValidationTime() -> Date? { validationTime }
    func setLastValidationTime(_ date: Date?) { validationTime = date }
    func getCachedUserStatus() -> UserSubscriptionStatus? { status }
    func setCachedUserStatus(_ status: UserSubscriptionStatus) { self.status = status }
    func getLastLoginRejectionTime() -> Date? { loginRejectionTime }
    func setLastLoginRejectionTime(_ date: Date?) { loginRejectionTime = date }
    func getLastForegroundCheckTime() -> Date? { foregroundCheckTime }
    func setLastForegroundCheckTime(_ date: Date?) { foregroundCheckTime = date }
    func clearAllCache() {
        purchases = []; status = nil; validationTime = nil
        loginRejectionTime = nil; foregroundCheckTime = nil
    }
    func getOfflineProtectionStatus(maxGracePeriod _: TimeInterval) -> (isProtected: Bool, remainingTime: TimeInterval?) {
        (true, nil)
    }
    func shouldValidateOnStartup() -> Bool { false }
    func shouldCheckOnForeground() -> Bool { true }
    func isInLoginCooldown() -> Bool { false }
    func inferUserStatusFromPurchases() -> UserSubscriptionStatus {
        purchases.isEmpty ? .newUser : .activeSubscriber
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class SyncCountingStoreKitService: StoreKitServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _syncCallCount = 0
    var syncCallCount: Int { lock.withLock { _syncCallCount } }

    func fetchProducts(for _: Set<String>) async throws -> [Product] { [] }

    func purchase(_: Product, options _: Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult {
        throw StoreError.unknown
    }

    func currentEntitlements() -> CurrentEntitlementsStream {
        AsyncStream { $0.finish() }
    }

    func transactionUpdates() -> TransactionUpdatesStream {
        AsyncStream { $0.finish() }
    }

    func sync() async throws {
        lock.withLock { _syncCallCount += 1 }
    }

    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified: throw StoreError.failedVerification
        }
    }
}
