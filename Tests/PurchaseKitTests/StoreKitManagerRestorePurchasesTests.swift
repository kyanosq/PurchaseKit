import XCTest
import StoreKit
@testable import PurchaseKit

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
final class StoreKitManagerRestorePurchasesTests: XCTestCase {

    func testRestorePurchases_PropagatesUpdateUserPurchasesError() async throws {
        let cache = AlwaysCooldownPurchaseCache()
        let service = EmptyEntitlementsStoreKitService()

        let manager = await MainActor.run {
            StoreKitManager(
                catalog: .stub,
                config: .debug,
                purchaseCache: cache,
                storeKitService: service
            )
        }

        do {
            try await manager.restorePurchases()
            XCTFail("Expected restorePurchases() to throw when updateUserPurchases fails")
        } catch let error as StoreError {
            switch error {
            case .userCancelled:
                break
            default:
                XCTFail("Expected userCancelled, got \(error)")
            }
        } catch {
            XCTFail("Expected StoreError.userCancelled, got \(error)")
        }
    }

    func testRestorePurchases_MapsSyncNetworkFailureToStoreErrorNetworkError() async throws {
        let cache = NonBlockingPurchaseCache()
        let service = FailingSyncStoreKitService(error: URLError(.notConnectedToInternet))

        let manager = await MainActor.run {
            StoreKitManager(
                catalog: .stub,
                config: .debug,
                purchaseCache: cache,
                storeKitService: service
            )
        }

        do {
            try await manager.restorePurchases()
            XCTFail("Expected restorePurchases() to throw on sync failure")
        } catch let error as StoreError {
            switch error {
            case .networkError:
                break
            default:
                XCTFail("Expected networkError, got \(error)")
            }
        } catch {
            XCTFail("Expected StoreError.networkError, got \(error)")
        }
    }

    func testRestorePurchases_AvoidsDuplicateEntitlementRefreshDuringStatusUpdate() async throws {
        let cache = StickyHistoryPurchaseCache()
        let service = CountingEntitlementsStoreKitService()
        let config = StoreKitConfiguration(
            namespace: "test.restore_calls." + UUID().uuidString,
            maxOfflineGracePeriod: 3600,
            loginCooldownPeriod: 60,
            foregroundCheckInterval: 3600,
            startupValidationInterval: 3600,
            refundCheckDelay: 3600,
            foregroundRefundCheckInterval: 3600,
            proAccessCacheInterval: 60,
            storeKitInitDelay: 3600
        )

        let manager = await MainActor.run {
            StoreKitManager(
                catalog: .stub,
                config: config,
                purchaseCache: cache,
                storeKitService: service
            )
        }

        try await manager.restorePurchases()

        let calls = await service.entitlementCallCount()
        XCTAssertEqual(calls, 2, "restorePurchases 应只进行一次刷新 + 一次状态计算，避免重复刷新")
    }

    func testForceRefreshPurchases_KeepsExpiredStatusAfterOfflineFallback() async throws {
        let cache = ExpiredHistoryWithoutProtectionCache(isInLoginCooldown: true)
        let service = EmptyEntitlementsStoreKitService()
        let config = StoreKitConfiguration(
            namespace: "test.force_refresh_test." + UUID().uuidString,
            maxOfflineGracePeriod: 3600,
            loginCooldownPeriod: 60,
            foregroundCheckInterval: 3600,
            startupValidationInterval: 3600,
            refundCheckDelay: 3600,
            foregroundRefundCheckInterval: 3600,
            proAccessCacheInterval: 60,
            storeKitInitDelay: 3600
        )

        let manager = await MainActor.run {
            StoreKitManager(
                catalog: .stub,
                config: config,
                purchaseCache: cache,
                storeKitService: service
            )
        }

        await manager.forceRefreshPurchases()

        let status = await manager.userStatus
        XCTAssertEqual(
            status,
            .expiredSubscriber,
            "离线回退后，历史付费用户不应被覆盖为 newUser"
        )
    }

    func testForceRefreshPurchases_AvoidsDuplicateEntitlementRefreshDuringStatusUpdate() async throws {
        let cache = StickyHistoryPurchaseCache()
        let service = CountingEntitlementsStoreKitService()
        let config = StoreKitConfiguration(
            namespace: "test.force_refresh_calls." + UUID().uuidString,
            maxOfflineGracePeriod: 3600,
            loginCooldownPeriod: 60,
            foregroundCheckInterval: 3600,
            startupValidationInterval: 3600,
            refundCheckDelay: 3600,
            foregroundRefundCheckInterval: 3600,
            proAccessCacheInterval: 60,
            storeKitInitDelay: 3600
        )

        let manager = await MainActor.run {
            StoreKitManager(
                catalog: .stub,
                config: config,
                purchaseCache: cache,
                storeKitService: service
            )
        }

        await manager.forceRefreshPurchases()

        let calls = await service.entitlementCallCount()
        XCTAssertEqual(calls, 2, "forceRefreshPurchases 应只进行一次刷新 + 一次状态计算，避免重复刷新")
    }

    func testReloadProducts_ForceRefreshesCatalogEvenWhenCalledRepeatedly() async throws {
        let cache = NonBlockingPurchaseCache()
        let service = ProductFetchCountingStoreKitService()
        let config = StoreKitConfiguration(
            namespace: "test.reload_products." + UUID().uuidString,
            maxOfflineGracePeriod: 3600,
            loginCooldownPeriod: 60,
            foregroundCheckInterval: 3600,
            startupValidationInterval: 3600,
            refundCheckDelay: 3600,
            foregroundRefundCheckInterval: 3600,
            proAccessCacheInterval: 60,
            storeKitInitDelay: 3600
        )

        let manager = await MainActor.run {
            StoreKitManager(
                catalog: .stub,
                config: config,
                purchaseCache: cache,
                storeKitService: service
            )
        }

        try await manager.reloadProducts()
        try await manager.reloadProducts()

        let calls = await service.productFetchCount()
        XCTAssertEqual(calls, 2, "reloadProducts 应显式重新拉取商品，而不是沿用旧结果")
    }

    func testStartPeriodicRefundCheck_DeduplicatesPendingTask() async throws {
        let cache = AlwaysCheckForegroundPurchaseCache()
        let service = SyncCountingStoreKitService()
        let config = StoreKitConfiguration(
            namespace: "test.periodic_refund." + UUID().uuidString,
            maxOfflineGracePeriod: 3600,
            loginCooldownPeriod: 60,
            foregroundCheckInterval: 3600,
            startupValidationInterval: 3600,
            refundCheckDelay: 0.2,
            foregroundRefundCheckInterval: 3600,
            proAccessCacheInterval: 60,
            storeKitInitDelay: 3600
        )

        let manager = await MainActor.run {
            StoreKitManager(
                catalog: .stub,
                config: config,
                purchaseCache: cache,
                storeKitService: service
            )
        }

        await MainActor.run {
            manager.startPeriodicRefundCheck()
            manager.startPeriodicRefundCheck()
        }

        try await Task.sleep(nanoseconds: 400_000_000)

        let syncCount = await service.currentSyncCount()
        XCTAssertEqual(
            syncCount,
            1,
            "重复触发 startPeriodicRefundCheck 不应创建多个并发退款检查任务"
        )
    }

    @MainActor
    func testTransactionListener_DoesNotRetainManagerAfterRelease() async throws {
        let cache = NonBlockingPurchaseCache()
        let service = NeverEndingTransactionUpdatesStoreKitService()
        let config = StoreKitConfiguration(
            namespace: "test.listener_retention." + UUID().uuidString,
            maxOfflineGracePeriod: 3600,
            loginCooldownPeriod: 60,
            foregroundCheckInterval: 3600,
            startupValidationInterval: 3600,
            refundCheckDelay: 3600,
            foregroundRefundCheckInterval: 3600,
            proAccessCacheInterval: 60,
            storeKitInitDelay: 0
        )

        weak var weakManager: StoreKitManager?
        var manager: StoreKitManager? = StoreKitManager(
            catalog: .stub,
            config: config,
            purchaseCache: cache,
            storeKitService: service
        )
        weakManager = manager
        manager = nil

        for _ in 0..<20 {
            if weakManager == nil {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNil(
            weakManager,
            "释放外部引用后，StoreKitManager 不应被事务监听任务强持有"
        )

        await service.finishUpdates()
    }

    func testForceRefreshPurchases_PreservesLifetimeAccessAfterOfflineFallback() async throws {
        let cache = LifetimeHistoryWithoutProtectionCache(isInLoginCooldown: true)
        let service = EmptyEntitlementsStoreKitService()
        let config = StoreKitConfiguration(
            namespace: "test.lifetime_offline." + UUID().uuidString,
            maxOfflineGracePeriod: 3600,
            loginCooldownPeriod: 60,
            foregroundCheckInterval: 3600,
            startupValidationInterval: 3600,
            refundCheckDelay: 3600,
            foregroundRefundCheckInterval: 3600,
            proAccessCacheInterval: 60,
            storeKitInitDelay: 3600
        )

        let manager = await MainActor.run {
            StoreKitManager(
                catalog: .stub,
                config: config,
                purchaseCache: cache,
                storeKitService: service
            )
        }

        await manager.forceRefreshPurchases()

        let hasAccess = await manager.canAccessProFeatures()
        let status = await manager.userStatus
        XCTAssertTrue(hasAccess, "离线回退不应让终身买断用户失去 Pro 访问权限")
        XCTAssertEqual(status, .activeSubscriber, "终身买断用户在离线回退后应保持激活状态")
    }

    func testLapsedSubscriberWithHistoryIsNotReclassifiedAsNewUser() async throws {
        // 当前权益为空，但有经过验证写入的订阅历史：恢复购买后必须是过期订阅者，不能回退成新用户。
        let cache = SubscriptionHistoryOnlyCache()
        let service = EmptyEntitlementsStoreKitService()
        let config = StoreKitConfiguration(
            namespace: "test.lapsed_history." + UUID().uuidString,
            maxOfflineGracePeriod: 3600,
            loginCooldownPeriod: 60,
            foregroundCheckInterval: 3600,
            startupValidationInterval: 3600,
            refundCheckDelay: 3600,
            foregroundRefundCheckInterval: 3600,
            proAccessCacheInterval: 60,
            storeKitInitDelay: 3600
        )

        let manager = await MainActor.run {
            StoreKitManager(
                catalog: .stub,
                config: config,
                purchaseCache: cache,
                storeKitService: service
            )
        }

        try await manager.restorePurchases()

        let status = await manager.userStatus
        XCTAssertEqual(
            status,
            .expiredSubscriber,
            "当前权益为空但有订阅历史的用户必须是过期订阅者，不能因当前权益为空就被判为新用户"
        )
    }

    @MainActor
    func testClearOfflineCacheSynchronouslyResetsPersistedAndInMemoryState() async throws {
        let suite = "test.clearcache." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults.standard
        let config = StoreKitConfiguration(
            namespace: suite,
            maxOfflineGracePeriod: 3600,
            loginCooldownPeriod: 60,
            foregroundCheckInterval: 3600,
            startupValidationInterval: 3600,
            refundCheckDelay: 3600,
            foregroundRefundCheckInterval: 3600,
            proAccessCacheInterval: 60,
            storeKitInitDelay: 3600
        )
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        cache.setLastValidPurchases(["stub.month"])
        cache.setLastValidationTime(Date())
        cache.setCachedUserStatus(.activeSubscriber)
        cache.recordSubscriptionHistory(["stub.month"])

        let service = EmptyEntitlementsStoreKitService()
        let manager = StoreKitManager(
            catalog: .stub,
            config: config,
            purchaseCache: cache,
            storeKitService: service
        )
        // restoreStateFromCache 在 init 中已据缓存恢复内存状态。
        XCTAssertFalse(manager.purchasedProductIDs.isEmpty, "前置：缓存恢复后应存在购买 ID")

        // clearOfflineCache 必须同步清空持久化与全部内存权益状态。
        manager.clearOfflineCache()

        XCTAssertTrue(manager.purchasedProductIDs.isEmpty)
        XCTAssertEqual(manager.userStatus, .newUser)
        XCTAssertNil(manager.activeTransaction)
        XCTAssertEqual(manager.proAccessState(), .none)
        if case .none = manager.currentOffer {
            // expected
        } else {
            XCTFail("Expected currentOffer to be cleared to .none")
        }
        // 持久化层也同步清空（purchase IDs、验证时间、订阅历史）。
        XCTAssertTrue(cache.getLastValidPurchases().isEmpty)
        XCTAssertNil(cache.getLastValidationTime())
        XCTAssertTrue(cache.getSubscriptionHistory().isEmpty)
    }

    // MARK: - 真实启动恢复：可持久历史/终身证据穿越过期宽限期（Sprint 2 correction）

    /// 旧版本只把已验证订阅写进 `lastValidPurchases`（即旧的 `lastValidPurchases` 表示），
    /// 没有独立的订阅历史。当离线宽限期过期、启动恢复清理可挥发访问证据时，必须先把这份
    /// 旧表示**迁移/播种**进可持久的订阅历史，再用真实 `PurchaseCache` 验证：客户曾经付费
    /// 这一事实不会被一次过期的离线宽限期抹除。
    @MainActor
    func testRestoreSeedsDurableSubscriptionHistoryFromLegacyCacheWhenProtectionExpired() async throws {
        let suite = "test.legacy_history_expired." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults.standard
        let config = StoreKitConfiguration(
            namespace: suite,
            maxOfflineGracePeriod: 3600,
            loginCooldownPeriod: 60,
            foregroundCheckInterval: 3600,
            startupValidationInterval: 3600,
            refundCheckDelay: 3600,
            foregroundRefundCheckInterval: 3600,
            proAccessCacheInterval: 60,
            storeKitInitDelay: 3600 // 抑制后台 StoreKit 初始化任务，仅考察同步启动恢复
        )
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        // 旧表示：仅有 lastValidPurchases，尚无独立的订阅历史。
        cache.setLastValidPurchases(["stub.month"])
        cache.setLastValidationTime(Date(timeIntervalSinceNow: -config.maxOfflineGracePeriod - 60))
        // 前置：宽限期已过期，且此时还没有独立历史。
        XCTAssertFalse(cache.getOfflineProtectionStatus(maxGracePeriod: config.maxOfflineGracePeriod).isProtected)
        XCTAssertTrue(cache.getSubscriptionHistory().isEmpty)

        let service = EmptyEntitlementsStoreKitService()
        let manager = StoreKitManager(
            catalog: .stub,
            config: config,
            purchaseCache: cache,
            storeKitService: service
        )

        // 旧当前 ID 被迁移进可持久的订阅历史：过期宽限期不得抹除购买身份。
        XCTAssertTrue(
            cache.getSubscriptionHistory().contains("stub.month"),
            "过期宽限期的清理必须把旧的 lastValidPurchases 播种进可持久订阅历史"
        )
        // 可挥发访问证据被清空：不授予离线访问。
        XCTAssertTrue(cache.getLastValidPurchases().isEmpty)
        XCTAssertNil(cache.getLastValidationTime())
        XCTAssertTrue(manager.purchasedProductIDs.isEmpty)
        // 有订阅历史的用户不得被回退成 newUser；访问未授予（离线宽限已过期，待重新验证）。
        XCTAssertEqual(manager.userStatus, .expiredSubscriber)
        XCTAssertEqual(manager.proAccessState(), .none)
    }

    /// 仅凭可持久的终身买断标记（无任何当前缓存 ID）启动恢复时，必须还原一致的终身访问与
    /// 激活用户状态——终身证据不应因没有当前订阅 ID而被降级。
    @MainActor
    func testRestoreRestoresLifetimeAccessFromFlagOnlyEvidence() async throws {
        let suite = "test.lifetime_flag_only." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults.standard
        let config = StoreKitConfiguration(
            namespace: suite,
            maxOfflineGracePeriod: 3600,
            loginCooldownPeriod: 60,
            foregroundCheckInterval: 3600,
            startupValidationInterval: 3600,
            refundCheckDelay: 3600,
            foregroundRefundCheckInterval: 3600,
            proAccessCacheInterval: 60,
            storeKitInitDelay: 3600 // 抑制后台 StoreKit 初始化任务，仅考察同步启动恢复
        )
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        // 仅有可持久终身标记，无任何当前缓存 ID / 验证时间。
        cache.setLifetimeEntitlement(true)
        XCTAssertTrue(cache.hasLifetimeEntitlement())
        XCTAssertTrue(cache.getLastValidPurchases().isEmpty)

        let service = EmptyEntitlementsStoreKitService()
        let manager = StoreKitManager(
            catalog: .stub,
            config: config,
            purchaseCache: cache,
            storeKitService: service
        )

        XCTAssertEqual(manager.userStatus, .activeSubscriber, "终身标记必须还原激活用户状态")
        XCTAssertEqual(manager.proAccessState(), .lifetime, "终身标记必须还原终身访问")
        XCTAssertTrue(manager.canAccessProFeatures(), "终身买断用户在启动恢复后应能访问 Pro 功能")
        XCTAssertTrue(cache.hasLifetimeEntitlement(), "可持久终身标记不得被启动恢复清除")
    }

    @MainActor
    func testRefundCheckTask_DoesNotRetainManagerAfterRelease() async throws {
        let cache = AlwaysCheckForegroundPurchaseCache()
        let service = SyncCountingStoreKitService()
        let config = StoreKitConfiguration(
            namespace: "test.refund_retention." + UUID().uuidString,
            maxOfflineGracePeriod: 3600,
            loginCooldownPeriod: 60,
            foregroundCheckInterval: 3600,
            startupValidationInterval: 3600,
            refundCheckDelay: 3600,
            foregroundRefundCheckInterval: 3600,
            proAccessCacheInterval: 60,
            storeKitInitDelay: 0
        )

        weak var weakManager: StoreKitManager?
        var manager: StoreKitManager? = StoreKitManager(
            catalog: .stub,
            config: config,
            purchaseCache: cache,
            storeKitService: service
        )
        weakManager = manager
        manager?.startPeriodicRefundCheck()
        manager = nil

        for _ in 0..<20 {
            if weakManager == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNil(
            weakManager,
            "释放外部引用后，StoreKitManager 不应被退款检查任务强持有"
        )
    }

    @MainActor
    func testHasLocalRestorableEntitlementEvidenceTracksRestorableEvidence() async throws {
        let cache = RestorableEvidenceProbeCache()
        let manager = StoreKitManager(
            catalog: .stub,
            config: .debug,
            purchaseCache: cache,
            storeKitService: EmptyEntitlementsStoreKitService()
        )

        // 无任何本地证据：不应声称可恢复权益。
        XCTAssertFalse(manager.hasLocalRestorableEntitlementEvidence)

        // 仅有过期 / 取消的订阅历史（无当前权益、无终身证据）：仍不可恢复，
        // 避免宿主对已流失用户误称「上线后权益会回来」。
        cache.cachedStatus = .expiredSubscriber
        XCTAssertFalse(manager.hasLocalRestorableEntitlementEvidence)

        // 本地仍有当前已验证购买 ID：可恢复。
        cache.purchases = ["stub.month"]
        XCTAssertTrue(manager.hasLocalRestorableEntitlementEvidence)
        cache.purchases = []

        // 持久终身买断标记：即便当前权益 ID 为空也可恢复。
        cache.lifetimeEntitlement = true
        XCTAssertTrue(manager.hasLocalRestorableEntitlementEvidence)
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class RestorableEvidenceProbeCache: PurchaseCacheProtocol {
    var purchases: Set<String> = []
    var lifetimeEntitlement: Bool = false
    var cachedStatus: UserSubscriptionStatus?
    private var validationTime: Date?
    private var loginRejectionTime: Date?
    private var foregroundCheckTime: Date?

    func getLastValidPurchases() -> Set<String> { purchases }
    func setLastValidPurchases(_ purchases: Set<String>) { self.purchases = purchases }
    func getLastValidationTime() -> Date? { validationTime }
    func setLastValidationTime(_ date: Date?) { validationTime = date }
    func getCachedUserStatus() -> UserSubscriptionStatus? { cachedStatus }
    func setCachedUserStatus(_ status: UserSubscriptionStatus) { cachedStatus = status }
    func getLastLoginRejectionTime() -> Date? { loginRejectionTime }
    func setLastLoginRejectionTime(_ date: Date?) { loginRejectionTime = date }
    func getLastForegroundCheckTime() -> Date? { foregroundCheckTime }
    func setLastForegroundCheckTime(_ date: Date?) { foregroundCheckTime = date }
    // 探针状态由测试显式写入；清空操作设为 no-op，确保 init 的 restoreStateFromCache
    // 不会抹掉测试在构造之后注入的证据。
    func clearAllCache() {}
    func clearVolatileCache() {}
    func getOfflineProtectionStatus(maxGracePeriod _: TimeInterval) -> (isProtected: Bool, remainingTime: TimeInterval?) {
        (false, nil)
    }
    func shouldValidateOnStartup() -> Bool { false }
    func shouldCheckOnForeground() -> Bool { false }
    func isInLoginCooldown() -> Bool { false }
    func inferUserStatusFromPurchases() -> UserSubscriptionStatus {
        purchases.isEmpty ? .newUser : .activeSubscriber
    }
    func hasLifetimeEntitlement() -> Bool { lifetimeEntitlement }
    func setLifetimeEntitlement(_ entitlement: Bool) { lifetimeEntitlement = entitlement }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class AlwaysCooldownPurchaseCache: PurchaseCacheProtocol {
    private var purchases: Set<String> = []
    private var status: UserSubscriptionStatus?
    private var validationTime: Date?
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
        purchases = []
        status = nil
        validationTime = nil
        loginRejectionTime = nil
        foregroundCheckTime = nil
    }
    func getOfflineProtectionStatus(maxGracePeriod _: TimeInterval) -> (isProtected: Bool, remainingTime: TimeInterval?) {
        (false, nil)
    }
    func shouldValidateOnStartup() -> Bool { false }
    func shouldCheckOnForeground() -> Bool { false }
    func isInLoginCooldown() -> Bool { true }
    func inferUserStatusFromPurchases() -> UserSubscriptionStatus {
        purchases.isEmpty ? .newUser : .activeSubscriber
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class NonBlockingPurchaseCache: PurchaseCacheProtocol {
    private var purchases: Set<String> = []
    private var status: UserSubscriptionStatus?
    private var validationTime: Date?
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
        purchases = []
        status = nil
        validationTime = nil
        loginRejectionTime = nil
        foregroundCheckTime = nil
    }
    func getOfflineProtectionStatus(maxGracePeriod _: TimeInterval) -> (isProtected: Bool, remainingTime: TimeInterval?) {
        (false, nil)
    }
    func shouldValidateOnStartup() -> Bool { false }
    func shouldCheckOnForeground() -> Bool { false }
    func isInLoginCooldown() -> Bool { false }
    func inferUserStatusFromPurchases() -> UserSubscriptionStatus {
        purchases.isEmpty ? .newUser : .activeSubscriber
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class ExpiredHistoryWithoutProtectionCache: PurchaseCacheProtocol {
    private var purchases: Set<String> = []
    private var status: UserSubscriptionStatus? = .expiredSubscriber
    private var validationTime: Date?
    private var loginRejectionTime: Date?
    private var foregroundCheckTime: Date?
    private let loginCooldown: Bool

    init(isInLoginCooldown: Bool = false) {
        self.loginCooldown = isInLoginCooldown
    }

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
        purchases = []
        status = nil
        validationTime = nil
        loginRejectionTime = nil
        foregroundCheckTime = nil
    }
    func getOfflineProtectionStatus(maxGracePeriod _: TimeInterval) -> (isProtected: Bool, remainingTime: TimeInterval?) {
        (false, nil)
    }
    func shouldValidateOnStartup() -> Bool { false }
    func shouldCheckOnForeground() -> Bool { false }
    func isInLoginCooldown() -> Bool { loginCooldown }
    func inferUserStatusFromPurchases() -> UserSubscriptionStatus {
        purchases.isEmpty ? .newUser : .activeSubscriber
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class LifetimeHistoryWithoutProtectionCache: PurchaseCacheProtocol {
    private var purchases: Set<String> = ["stub.lifetime"]
    private var status: UserSubscriptionStatus? = .activeSubscriber
    private var validationTime: Date?
    private var loginRejectionTime: Date?
    private var foregroundCheckTime: Date?
    private let loginCooldown: Bool

    init(isInLoginCooldown: Bool = false) {
        self.loginCooldown = isInLoginCooldown
    }

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
        purchases = []
        status = nil
        validationTime = nil
        loginRejectionTime = nil
        foregroundCheckTime = nil
    }
    func getOfflineProtectionStatus(maxGracePeriod _: TimeInterval) -> (isProtected: Bool, remainingTime: TimeInterval?) {
        (false, nil)
    }
    func shouldValidateOnStartup() -> Bool { false }
    func shouldCheckOnForeground() -> Bool { false }
    func isInLoginCooldown() -> Bool { loginCooldown }
    func inferUserStatusFromPurchases() -> UserSubscriptionStatus {
        purchases.isEmpty ? .newUser : .activeSubscriber
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class SubscriptionHistoryOnlyCache: PurchaseCacheProtocol {
    private var purchases: Set<String> = []
    private var status: UserSubscriptionStatus?
    private var validationTime: Date?
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
        purchases = []
        status = nil
        validationTime = nil
        loginRejectionTime = nil
        foregroundCheckTime = nil
    }
    func getOfflineProtectionStatus(maxGracePeriod _: TimeInterval) -> (isProtected: Bool, remainingTime: TimeInterval?) {
        (false, nil)
    }
    func shouldValidateOnStartup() -> Bool { false }
    func shouldCheckOnForeground() -> Bool { false }
    func isInLoginCooldown() -> Bool { false }
    func inferUserStatusFromPurchases() -> UserSubscriptionStatus {
        purchases.isEmpty ? .newUser : .activeSubscriber
    }

    // 有订阅历史、但当前权益为空：用于验证过期订阅者不会被回退成新用户。
    func getSubscriptionHistory() -> Set<String> { ["stub.month"] }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class StickyHistoryPurchaseCache: PurchaseCacheProtocol {
    private var purchases: Set<String> = ["stub.month"]
    private var status: UserSubscriptionStatus? = .activeSubscriber
    private var validationTime: Date?
    private var loginRejectionTime: Date?
    private var foregroundCheckTime: Date?

    func getLastValidPurchases() -> Set<String> { purchases }
    func setLastValidPurchases(_ purchases: Set<String>) {
        if !purchases.isEmpty {
            self.purchases = purchases
        }
    }
    func getLastValidationTime() -> Date? { validationTime }
    func setLastValidationTime(_ date: Date?) { validationTime = date }
    func getCachedUserStatus() -> UserSubscriptionStatus? { status }
    func setCachedUserStatus(_ status: UserSubscriptionStatus) { self.status = status }
    func getLastLoginRejectionTime() -> Date? { loginRejectionTime }
    func setLastLoginRejectionTime(_ date: Date?) { loginRejectionTime = date }
    func getLastForegroundCheckTime() -> Date? { foregroundCheckTime }
    func setLastForegroundCheckTime(_ date: Date?) { foregroundCheckTime = date }
    func clearAllCache() {
        purchases = []
        status = nil
        validationTime = nil
        loginRejectionTime = nil
        foregroundCheckTime = nil
    }
    func getOfflineProtectionStatus(maxGracePeriod _: TimeInterval) -> (isProtected: Bool, remainingTime: TimeInterval?) {
        (true, 60)
    }
    func shouldValidateOnStartup() -> Bool { false }
    func shouldCheckOnForeground() -> Bool { false }
    func isInLoginCooldown() -> Bool { false }
    func inferUserStatusFromPurchases() -> UserSubscriptionStatus {
        purchases.isEmpty ? .newUser : .activeSubscriber
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class AlwaysCheckForegroundPurchaseCache: PurchaseCacheProtocol {
    private var purchases: Set<String> = ["sub.monthly"]
    private var status: UserSubscriptionStatus? = .activeSubscriber
    private var validationTime: Date?
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
        purchases = []
        status = nil
        validationTime = nil
        loginRejectionTime = nil
        foregroundCheckTime = nil
    }
    func getOfflineProtectionStatus(maxGracePeriod _: TimeInterval) -> (isProtected: Bool, remainingTime: TimeInterval?) {
        (true, 60)
    }
    func shouldValidateOnStartup() -> Bool { false }
    func shouldCheckOnForeground() -> Bool { true }
    func isInLoginCooldown() -> Bool { false }
    func inferUserStatusFromPurchases() -> UserSubscriptionStatus {
        purchases.isEmpty ? .newUser : .activeSubscriber
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class EmptyEntitlementsStoreKitService: StoreKitServiceProtocol, @unchecked Sendable {
    func fetchProducts(for _: Set<String>) async throws -> [Product] { [] }

    func purchase(_: Product, options _: Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult {
        throw StoreError.unknown
    }

    func currentEntitlements() -> CurrentEntitlementsStream {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func transactionUpdates() -> TransactionUpdatesStream {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func sync() async throws {}

    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw StoreError.failedVerification
        }
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class FailingSyncStoreKitService: StoreKitServiceProtocol, @unchecked Sendable {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func fetchProducts(for _: Set<String>) async throws -> [Product] { [] }

    func purchase(_: Product, options _: Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult {
        throw StoreError.unknown
    }

    func currentEntitlements() -> CurrentEntitlementsStream {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func transactionUpdates() -> TransactionUpdatesStream {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func sync() async throws {
        throw error
    }

    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw StoreError.failedVerification
        }
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class SyncCountingStoreKitService: StoreKitServiceProtocol, @unchecked Sendable {
    private let counter = SyncCounter()

    func fetchProducts(for _: Set<String>) async throws -> [Product] { [] }

    func purchase(_: Product, options _: Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult {
        throw StoreError.unknown
    }

    func currentEntitlements() -> CurrentEntitlementsStream {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func transactionUpdates() -> TransactionUpdatesStream {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func sync() async throws {
        await counter.increment()
    }

    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw StoreError.failedVerification
        }
    }

    func currentSyncCount() async -> Int {
        await counter.value()
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class CountingEntitlementsStoreKitService: StoreKitServiceProtocol, @unchecked Sendable {
    private let counter = SyncCounter()

    func fetchProducts(for _: Set<String>) async throws -> [Product] { [] }

    func purchase(_: Product, options _: Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult {
        throw StoreError.unknown
    }

    func currentEntitlements() -> CurrentEntitlementsStream {
        AsyncStream { continuation in
            Task {
                await counter.increment()
                continuation.finish()
            }
        }
    }

    func transactionUpdates() -> TransactionUpdatesStream {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func sync() async throws {}

    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw StoreError.failedVerification
        }
    }

    func entitlementCallCount() async -> Int {
        await counter.value()
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class ProductFetchCountingStoreKitService: StoreKitServiceProtocol, @unchecked Sendable {
    private let counter = SyncCounter()

    func fetchProducts(for _: Set<String>) async throws -> [Product] {
        await counter.increment()
        return []
    }

    func purchase(_: Product, options _: Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult {
        throw StoreError.unknown
    }

    func currentEntitlements() -> CurrentEntitlementsStream {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func transactionUpdates() -> TransactionUpdatesStream {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func sync() async throws {}

    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw StoreError.failedVerification
        }
    }

    func productFetchCount() async -> Int {
        await counter.value()
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private final class NeverEndingTransactionUpdatesStoreKitService: StoreKitServiceProtocol, @unchecked Sendable {
    private let holder = TransactionContinuationHolder()

    func fetchProducts(for _: Set<String>) async throws -> [Product] { [] }

    func purchase(_: Product, options _: Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult {
        throw StoreError.unknown
    }

    func currentEntitlements() -> CurrentEntitlementsStream {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func transactionUpdates() -> TransactionUpdatesStream {
        AsyncStream { continuation in
            Task {
                await holder.set(continuation)
            }
        }
    }

    func sync() async throws {}

    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw StoreError.failedVerification
        }
    }

    func finishUpdates() async {
        await holder.finish()
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private actor SyncCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private actor TransactionContinuationHolder {
    private var continuation: AsyncStream<VerificationResult<Transaction>>.Continuation?

    func set(_ continuation: AsyncStream<VerificationResult<Transaction>>.Continuation) {
        self.continuation = continuation
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}
