import XCTest
@testable import PurchaseKit

private func makeIsolatedDefaults() -> UserDefaultsProtocol {
    // Use unique suite to isolate test state without custom in-memory impl
    let suiteName = "test." + UUID().uuidString
    return UserDefaults(suiteName: suiteName) ?? UserDefaults.standard
}

final class PurchaseCacheTests: XCTestCase {
    private func makeConfig() -> StoreKitConfiguration {
        StoreKitConfiguration(
            namespace: "test.cache." + UUID().uuidString,
            maxOfflineGracePeriod: 3600,
            loginCooldownPeriod: 600,
            foregroundCheckInterval: 1800,
            startupValidationInterval: 86400,
            refundCheckDelay: 60,
            foregroundRefundCheckInterval: 7200,
            proAccessCacheInterval: 30,
            storeKitInitDelay: 0.1
        )
    }
    
    func testStoresAndLoadsLastValidPurchases() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())
        cache.setLastValidPurchases(["product.a", "product.b"])
        XCTAssertEqual(cache.getLastValidPurchases(), ["product.a", "product.b"])
    }
    
    func testShouldValidateOnStartupWhenValidationIsStale() {
        let defaults = makeIsolatedDefaults()
        let config = makeConfig()
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        cache.setLastValidPurchases(["product.a"])
        let staleDate = Date(timeIntervalSinceNow: -config.startupValidationInterval - 10)
        cache.setLastValidationTime(staleDate)
        XCTAssertTrue(cache.shouldValidateOnStartup())
    }
    
    func testOfflineProtectionExpiresWhenGracePeriodPassed() {
        let defaults = makeIsolatedDefaults()
        let config = makeConfig()
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        cache.setLastValidationTime(Date(timeIntervalSinceNow: -config.maxOfflineGracePeriod - 5))
        let status = cache.getOfflineProtectionStatus(maxGracePeriod: config.maxOfflineGracePeriod)
        XCTAssertFalse(status.isProtected)
    }
    
    // MARK: - 新增测试
    
    func testSetLastValidationTimeWithNil() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())
        
        // 先设置一个日期
        cache.setLastValidationTime(Date())
        XCTAssertNotNil(cache.getLastValidationTime())
        
        // 然后设置为 nil 应该清除
        cache.setLastValidationTime(nil)
        XCTAssertNil(cache.getLastValidationTime())
    }
    
    func testGetCachedUserStatusAllCases() {
        let defaults = makeIsolatedDefaults()
        let config = makeConfig()
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        
        // 测试所有状态
        let allStatuses: [UserSubscriptionStatus] = [
            .newUser, .activeSubscriber, .expiredSubscriber, 
            .cancelledSubscriber, .trialUser
        ]
        
        for status in allStatuses {
            cache.setCachedUserStatus(status)
            let retrieved = cache.getCachedUserStatus()
            XCTAssertEqual(retrieved, status)
        }
    }
    
    func testGetCachedUserStatusWithInvalidString() {
        let defaults = makeIsolatedDefaults()
        let config = makeConfig()
        defaults.set("invalidStatus", forKey: config.cachedUserStatusKey)
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        
        XCTAssertNil(cache.getCachedUserStatus())
    }
    
    func testGetCachedUserStatusReturnsNilWhenNotSet() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())
        
        XCTAssertNil(cache.getCachedUserStatus())
    }
    
    func testLoginRejectionTimeOperations() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())
        
        // 初始应该为 nil
        XCTAssertNil(cache.getLastLoginRejectionTime())
        
        // 设置时间
        let testDate = Date()
        cache.setLastLoginRejectionTime(testDate)
        let retrieved = cache.getLastLoginRejectionTime()
        XCTAssertNotNil(retrieved)
        if let retrieved = retrieved {
            XCTAssertEqual(retrieved.timeIntervalSince1970, testDate.timeIntervalSince1970, accuracy: 0.01)
        }
        
        // 清除时间
        cache.setLastLoginRejectionTime(nil)
        XCTAssertNil(cache.getLastLoginRejectionTime())
    }
    
    func testIsInLoginCooldownWithNoRejection() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())
        
        // 没有拒绝记录时应该不在冷却期
        XCTAssertFalse(cache.isInLoginCooldown())
    }
    
    func testIsInLoginCooldownWithinPeriod() {
        let defaults = makeIsolatedDefaults()
        let config = makeConfig()
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        
        // 设置最近的拒绝时间（10秒前）
        cache.setLastLoginRejectionTime(Date(timeIntervalSinceNow: -10))
        
        // 应该还在冷却期内（配置是600秒）
        XCTAssertTrue(cache.isInLoginCooldown())
    }
    
    func testIsInLoginCooldownExpired() {
        let defaults = makeIsolatedDefaults()
        let config = makeConfig()
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        
        // 设置很久之前的拒绝时间（超过冷却期）
        cache.setLastLoginRejectionTime(Date(timeIntervalSinceNow: -config.loginCooldownPeriod - 10))
        
        // 应该已经过了冷却期
        XCTAssertFalse(cache.isInLoginCooldown())
    }
    
    func testForegroundCheckTimeOperations() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())
        
        // 初始应该为 nil
        XCTAssertNil(cache.getLastForegroundCheckTime())
        
        // 设置时间
        let testDate = Date()
        cache.setLastForegroundCheckTime(testDate)
        let retrieved = cache.getLastForegroundCheckTime()
        XCTAssertNotNil(retrieved)
        if let retrieved = retrieved {
            XCTAssertEqual(retrieved.timeIntervalSince1970, testDate.timeIntervalSince1970, accuracy: 0.01)
        }
        
        // 清除时间
        cache.setLastForegroundCheckTime(nil)
        XCTAssertNil(cache.getLastForegroundCheckTime())
    }
    
    func testClearAllCache() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())
        
        // 设置各种数据
        cache.setLastValidPurchases(["product.a", "product.b"])
        cache.setLastValidationTime(Date())
        cache.setCachedUserStatus(.activeSubscriber)
        cache.setLastLoginRejectionTime(Date())
        cache.setLastForegroundCheckTime(Date())
        
        // 验证数据已设置
        XCTAssertFalse(cache.getLastValidPurchases().isEmpty)
        XCTAssertNotNil(cache.getLastValidationTime())
        XCTAssertNotNil(cache.getCachedUserStatus())
        XCTAssertNotNil(cache.getLastLoginRejectionTime())
        XCTAssertNotNil(cache.getLastForegroundCheckTime())
        
        // 清除所有缓存
        cache.clearAllCache()
        
        // 验证所有数据已清除
        XCTAssertTrue(cache.getLastValidPurchases().isEmpty)
        XCTAssertNil(cache.getLastValidationTime())
        XCTAssertNil(cache.getCachedUserStatus())
        XCTAssertNil(cache.getLastLoginRejectionTime())
        XCTAssertNil(cache.getLastForegroundCheckTime())
    }
    
    func testInferUserStatusFromPurchasesEmpty() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())
        
        // 没有购买记录时应该返回 newUser
        XCTAssertEqual(cache.inferUserStatusFromPurchases(), .newUser)
    }
    
    func testInferUserStatusFromPurchasesWithPurchases() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())
        
        cache.setLastValidPurchases(["product.a"])
        
        // 有购买记录时应该返回 activeSubscriber
        XCTAssertEqual(cache.inferUserStatusFromPurchases(), .activeSubscriber)
    }
    
    func testShouldCheckOnForegroundNeverChecked() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())
        
        // 从未检查过时应该返回 true
        XCTAssertTrue(cache.shouldCheckOnForeground())
    }
    
    func testShouldCheckOnForegroundRecentlyChecked() {
        let defaults = makeIsolatedDefaults()
        let config = makeConfig()
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        
        // 刚检查过（10秒前）
        cache.setLastForegroundCheckTime(Date(timeIntervalSinceNow: -10))
        
        // 应该不需要再次检查
        XCTAssertFalse(cache.shouldCheckOnForeground())
    }
    
    func testShouldCheckOnForegroundExpired() {
        let defaults = makeIsolatedDefaults()
        let config = makeConfig()
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        
        // 很久之前检查过（超过检查间隔）
        cache.setLastForegroundCheckTime(Date(timeIntervalSinceNow: -config.foregroundCheckInterval - 10))
        
        // 应该需要重新检查
        XCTAssertTrue(cache.shouldCheckOnForeground())
    }
    
    func testShouldValidateOnStartupNoPurchases() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())
        
        // 没有购买记录时不需要验证
        XCTAssertFalse(cache.shouldValidateOnStartup())
    }
    
    func testShouldValidateOnStartupNeverValidated() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())
        
        cache.setLastValidPurchases(["product.a"])
        // 没有设置验证时间
        
        // 有购买但从未验证过，需要验证
        XCTAssertTrue(cache.shouldValidateOnStartup())
    }
    
    func testOfflineProtectionStatusNoValidation() {
        let defaults = makeIsolatedDefaults()
        let config = makeConfig()
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        
        // 没有验证记录时应该不受保护
        let status = cache.getOfflineProtectionStatus(maxGracePeriod: config.maxOfflineGracePeriod)
        XCTAssertFalse(status.isProtected)
        XCTAssertNil(status.remainingTime)
    }
    
    func testOfflineProtectionStatusWithinGracePeriod() {
        let defaults = makeIsolatedDefaults()
        let config = makeConfig()
        let cache = PurchaseCache(userDefaults: defaults, config: config)

        // 10秒前验证过
        cache.setLastValidationTime(Date(timeIntervalSinceNow: -10))

        // 应该在保护期内
        let status = cache.getOfflineProtectionStatus(maxGracePeriod: config.maxOfflineGracePeriod)
        XCTAssertTrue(status.isProtected)
        XCTAssertNotNil(status.remainingTime)
        XCTAssertGreaterThan(status.remainingTime!, 0)
    }

    // MARK: - 命名空间迁移（Task 3）

    func testMigratesLegacyValidationKeyToNamespacedDestination() {
        let defaults = makeIsolatedDefaults()
        let namespace = "com.example.reader.PurchaseKit"
        let config = StoreKitConfiguration(namespace: namespace)
        let legacyDate = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(legacyDate, forKey: "lastSuccessfulValidation")

        let cache = PurchaseCache(userDefaults: defaults, config: config)

        let migrated = cache.getLastValidationTime()
        XCTAssertNotNil(migrated, "旧 key 的值应迁移到命名空间目标 key")
        if let migrated {
            XCTAssertEqual(migrated.timeIntervalSince1970, legacyDate.timeIntervalSince1970, accuracy: 0.001)
        }
        XCTAssertNil(
            defaults.object(forKey: "lastSuccessfulValidation"),
            "迁移成功后应删除旧 key"
        )
        XCTAssertNotNil(
            defaults.object(forKey: config.lastValidationKey),
            "迁移后的值应位于命名空间目标 key"
        )
    }

    func testMigrationDoesNotOverwriteExistingNamespacedDestination() {
        let defaults = makeIsolatedDefaults()
        let namespace = "com.example.reader.PurchaseKit"
        let config = StoreKitConfiguration(namespace: namespace)
        let legacyDate = Date(timeIntervalSince1970: 1_700_000_000)
        let existingDate = Date(timeIntervalSince1970: 1_600_000_000)
        defaults.set(legacyDate, forKey: "lastSuccessfulValidation")
        defaults.set(existingDate, forKey: config.lastValidationKey)

        let cache = PurchaseCache(userDefaults: defaults, config: config)

        let read = cache.getLastValidationTime()
        XCTAssertNotNil(read)
        if let read {
            XCTAssertEqual(
                read.timeIntervalSince1970,
                existingDate.timeIntervalSince1970,
                accuracy: 0.001,
                "目标 key 已有值时迁移不得覆盖"
            )
        }
    }

    func testMigrationIsNoOpWhenNoLegacyKeysPresent() {
        let defaults = makeIsolatedDefaults()
        let namespace = "com.example.reader.PurchaseKit"
        let config = StoreKitConfiguration(namespace: namespace)

        _ = PurchaseCache(userDefaults: defaults, config: config)

        XCTAssertNil(defaults.object(forKey: config.lastValidationKey))
        XCTAssertNil(defaults.object(forKey: "lastSuccessfulValidation"))
    }

    // MARK: - Date / Double 时间表示兼容（Task 3）

    func testLastValidationTimeRoundTripsDateRepresentation() {
        let defaults = makeIsolatedDefaults()
        let config = makeConfig()
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        let now = Date()
        defaults.set(now, forKey: config.lastValidationKey)

        let read = cache.getLastValidationTime()
        XCTAssertNotNil(read)
        if let read {
            XCTAssertEqual(read.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    func testLastValidationTimeRoundTripsEpochDoubleRepresentation() {
        let defaults = makeIsolatedDefaults()
        let config = makeConfig()
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        let epoch = 1_700_000_000.0
        defaults.set(epoch, forKey: config.lastValidationKey)

        let read = cache.getLastValidationTime()
        XCTAssertNotNil(read)
        if let read {
            XCTAssertEqual(read.timeIntervalSince1970, epoch, accuracy: 0.001)
        }
    }

    // MARK: - 订阅历史与终身权益（与当前权益 ID 分离，Task 6）

    func testSubscriptionHistoryAccumulatesAcrossCalls() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())

        XCTAssertTrue(cache.getSubscriptionHistory().isEmpty)

        cache.recordSubscriptionHistory(["sub.month"])
        XCTAssertEqual(cache.getSubscriptionHistory(), ["sub.month"])

        // 历史只累加：再次记录不覆盖已有条目。
        cache.recordSubscriptionHistory(["sub.year"])
        XCTAssertEqual(cache.getSubscriptionHistory(), ["sub.month", "sub.year"])
    }

    func testSubscriptionHistorySurvivesCurrentPurchaseIDsBeingCleared() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())

        cache.recordSubscriptionHistory(["sub.month"])
        cache.setLastValidPurchases(["sub.month"])
        // 当前权益被清空（订阅过期），历史证据必须保留，否则过期用户会被误判为新用户。
        cache.setLastValidPurchases([])

        XCTAssertEqual(cache.getLastValidPurchases(), [])
        XCTAssertEqual(cache.getSubscriptionHistory(), ["sub.month"])
    }

    func testClearAllCacheClearsSubscriptionHistory() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())

        cache.recordSubscriptionHistory(["sub.month"])
        XCTAssertFalse(cache.getSubscriptionHistory().isEmpty)

        cache.clearAllCache()
        XCTAssertTrue(cache.getSubscriptionHistory().isEmpty)
    }

    func testLifetimeEntitlementPersistsAndClears() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())

        XCTAssertFalse(cache.hasLifetimeEntitlement())

        cache.setLifetimeEntitlement(true)
        XCTAssertTrue(cache.hasLifetimeEntitlement())

        cache.setLifetimeEntitlement(false)
        XCTAssertFalse(cache.hasLifetimeEntitlement())
    }

    func testClearAllCacheClearsLifetimeEntitlement() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())

        cache.setLifetimeEntitlement(true)
        cache.clearAllCache()
        XCTAssertFalse(cache.hasLifetimeEntitlement())
    }

    // MARK: - 过期离线宽限期的可挥发清理（保留历史/终身证据，Sprint 2 correction）

    /// `clearVolatileCache()` 在离线宽限期过期时清理可挥发的访问证据（当前权益 ID、验证时间、
    /// 缓存状态），但**必须保留**可持久的订阅历史与终身买断证据。否则一个曾经付费、只是离线
    /// 宽限到期的用户会被抹掉购买身份、误判为新用户。
    func testClearVolatileCachePreservesSubscriptionHistoryAndLifetime() {
        let defaults = makeIsolatedDefaults()
        let cache = PurchaseCache(userDefaults: defaults, config: makeConfig())

        cache.setLastValidPurchases(["sub.month"])
        cache.setLastValidationTime(Date())
        cache.setCachedUserStatus(.activeSubscriber)
        cache.recordSubscriptionHistory(["sub.month"])
        cache.setLifetimeEntitlement(true)

        cache.clearVolatileCache()

        // 可挥发访问证据被清空。
        XCTAssertTrue(cache.getLastValidPurchases().isEmpty)
        XCTAssertNil(cache.getLastValidationTime())
        XCTAssertNil(cache.getCachedUserStatus())
        // 可持久证据保留：历史与终身标记不被离线宽限过期抹除。
        XCTAssertEqual(cache.getSubscriptionHistory(), ["sub.month"])
        XCTAssertTrue(cache.hasLifetimeEntitlement())
    }
}
