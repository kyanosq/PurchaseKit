import Foundation

// MARK: - Purchase Cache Service

public protocol PurchaseCacheProtocol {
    func getLastValidPurchases() -> Set<String>
    func setLastValidPurchases(_ purchases: Set<String>)
    func getLastValidationTime() -> Date?
    func setLastValidationTime(_ date: Date?)
    func getCachedUserStatus() -> UserSubscriptionStatus?
    func setCachedUserStatus(_ status: UserSubscriptionStatus)
    func getLastLoginRejectionTime() -> Date?
    func setLastLoginRejectionTime(_ date: Date?)
    func getLastForegroundCheckTime() -> Date?
    func setLastForegroundCheckTime(_ date: Date?)
    func clearAllCache()
    /// 清理可挥发的访问证据，但保留可持久的订阅历史与终身证据。
    /// 仅在离线宽限期过期时使用；完整重置仍用 `clearAllCache()`。
    func clearVolatileCache()
    func getOfflineProtectionStatus(maxGracePeriod: TimeInterval) -> (isProtected: Bool, remainingTime: TimeInterval?)
    func shouldValidateOnStartup() -> Bool
    func shouldCheckOnForeground() -> Bool
    func isInLoginCooldown() -> Bool
    func inferUserStatusFromPurchases() -> UserSubscriptionStatus

    /// 经过验证后写入的订阅历史证据（与当前权益 ID 分离）。仅累加，不在权益过期时抹除。
    func getSubscriptionHistory() -> Set<String>
    func recordSubscriptionHistory(_ productIDs: Set<String>)
    func clearSubscriptionHistory()

    /// 终身买断的非过期权益标记。
    func hasLifetimeEntitlement() -> Bool
    func setLifetimeEntitlement(_ entitlement: Bool)
}

/// 默认实现：测试替身若不关心历史/终身证据，可得到安全的“空”语义。
public extension PurchaseCacheProtocol {
    func getSubscriptionHistory() -> Set<String> { [] }
    func recordSubscriptionHistory(_ productIDs: Set<String>) {}
    func clearSubscriptionHistory() {}
    func hasLifetimeEntitlement() -> Bool { false }
    func setLifetimeEntitlement(_ entitlement: Bool) {}
    /// 默认退回到全量清理：不区分可挥发/可持久的替身仍按旧行为整体清空，
    /// 绝不静默少清。真实 `PurchaseCache` 覆盖该方法以保留历史与终身证据。
    func clearVolatileCache() { clearAllCache() }
}

public final class PurchaseCache: PurchaseCacheProtocol {
    private let userDefaults: UserDefaultsProtocol
    private let config: StoreKitConfiguration

    public init(userDefaults: UserDefaultsProtocol = UserDefaults.standard, config: StoreKitConfiguration = .current) {
        self.userDefaults = userDefaults
        self.config = config
        Self.migrateLegacyKeys(into: userDefaults, config: config)
    }

    // MARK: - Legacy key migration

    /// 把上线版本使用的无命名空间旧 key 一次性迁移到当前配置的命名空间目标 key。
    /// 仅当目标 key 尚无值时复制；复制成功并回读后删除旧 key，避免重复迁移。
    private static let legacyKeyPaths: [(legacy: String, destination: KeyPath<StoreKitConfiguration, String>)] = [
        ("lastSuccessfulValidation", \.lastValidationKey),
        ("lastValidPurchases", \.lastValidPurchasesKey),
        ("offlineGracePeriod", \.offlineGracePeriodKey),
        ("cachedUserStatus", \.cachedUserStatusKey),
        ("lastLoginRejection", \.lastLoginRejectionKey),
        ("lastForegroundCheck", \.lastForegroundCheckKey)
    ]

    private static func migrateLegacyKeys(into userDefaults: UserDefaultsProtocol, config: StoreKitConfiguration) {
        for (legacyKey, destinationKeyPath) in legacyKeyPaths {
            let destinationKey = config[keyPath: destinationKeyPath]
            guard userDefaults.object(forKey: destinationKey) == nil else { continue }
            guard let legacyValue = userDefaults.object(forKey: legacyKey) else { continue }
            userDefaults.set(legacyValue, forKey: destinationKey)
            // 仅在复制值可回读时删除旧 key，保证迁移可重入且不丢数据。
            if userDefaults.object(forKey: destinationKey) != nil {
                userDefaults.removeObject(forKey: legacyKey)
            }
        }
    }

    /// 兼容历史上以 `Date` 或正数 epoch `Double`/`NSNumber` 写入的缓存时间。
    private static func storedDate(_ raw: Any?) -> Date? {
        if let date = raw as? Date { return date }
        guard let number = raw as? NSNumber, number.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    // MARK: - Purchase History
    
    public func getLastValidPurchases() -> Set<String> {
        let array = userDefaults.stringArray(forKey: config.lastValidPurchasesKey) ?? []
        return Set(array)
    }
    
    public func setLastValidPurchases(_ purchases: Set<String>) {
        userDefaults.set(Array(purchases), forKey: config.lastValidPurchasesKey)
        logCacheOperation("Set last valid purchases: \(purchases)")
    }
    
    // MARK: - Validation Time
    
    public func getLastValidationTime() -> Date? {
        Self.storedDate(userDefaults.object(forKey: config.lastValidationKey))
    }
    
    public func setLastValidationTime(_ date: Date?) {
        if let date = date {
            userDefaults.set(date.timeIntervalSince1970, forKey: config.lastValidationKey)
            logCacheOperation("Set last validation time: \(date)")
        } else {
            userDefaults.removeObject(forKey: config.lastValidationKey)
            logCacheOperation("Cleared last validation time")
        }
    }
    
    // MARK: - User Status Cache
    
    public func getCachedUserStatus() -> UserSubscriptionStatus? {
        guard let statusString = userDefaults.string(forKey: config.cachedUserStatusKey) else {
            return nil
        }
        
        switch statusString {
        case "newUser": return .newUser
        case "activeSubscriber": return .activeSubscriber
        case "expiredSubscriber": return .expiredSubscriber
        case "cancelledSubscriber": return .cancelledSubscriber
        case "trialUser": return .trialUser
        default:
            logCacheOperation("Unknown cached status: \(statusString), returning nil")
            return nil
        }
    }
    
    public func setCachedUserStatus(_ status: UserSubscriptionStatus) {
        let statusString: String
        switch status {
        case .newUser: statusString = "newUser"
        case .activeSubscriber: statusString = "activeSubscriber"
        case .expiredSubscriber: statusString = "expiredSubscriber"
        case .cancelledSubscriber: statusString = "cancelledSubscriber"
        case .trialUser: statusString = "trialUser"
        }
        userDefaults.set(statusString, forKey: config.cachedUserStatusKey)
        logCacheOperation("Set cached user status: \(statusString)")
    }
    
    // MARK: - Login Protection
    
    public func getLastLoginRejectionTime() -> Date? {
        Self.storedDate(userDefaults.object(forKey: config.lastLoginRejectionKey))
    }
    
    public func setLastLoginRejectionTime(_ date: Date?) {
        if let date = date {
            userDefaults.set(date.timeIntervalSince1970, forKey: config.lastLoginRejectionKey)
            logCacheOperation("Set last login rejection time: \(date)")
        } else {
            userDefaults.removeObject(forKey: config.lastLoginRejectionKey)
            logCacheOperation("Cleared last login rejection time")
        }
    }
    
    public func isInLoginCooldown() -> Bool {
        guard let lastRejection = getLastLoginRejectionTime() else { return false }
        let elapsed = Date().timeIntervalSince(lastRejection)
        return elapsed < config.loginCooldownPeriod
    }
    
    // MARK: - Foreground Check
    
    public func getLastForegroundCheckTime() -> Date? {
        Self.storedDate(userDefaults.object(forKey: config.lastForegroundCheckKey))
    }
    
    public func setLastForegroundCheckTime(_ date: Date?) {
        if let date = date {
            userDefaults.set(date.timeIntervalSince1970, forKey: config.lastForegroundCheckKey)
            logCacheOperation("Set last foreground check time: \(date)")
        } else {
            userDefaults.removeObject(forKey: config.lastForegroundCheckKey)
            logCacheOperation("Cleared last foreground check time")
        }
    }
    
    // MARK: - Subscription History (separate from current entitlement IDs)

    public func getSubscriptionHistory() -> Set<String> {
        let array = userDefaults.stringArray(forKey: config.subscriptionHistoryKey) ?? []
        return Set(array)
    }

    /// 仅累加订阅历史：已记录的不会被移除，确保过期/取消用户的购买身份不被抹除。
    public func recordSubscriptionHistory(_ productIDs: Set<String>) {
        guard !productIDs.isEmpty else { return }
        let merged = getSubscriptionHistory().union(productIDs)
        userDefaults.set(Array(merged), forKey: config.subscriptionHistoryKey)
        logCacheOperation("Recorded subscription history: \(merged)")
    }

    public func clearSubscriptionHistory() {
        userDefaults.removeObject(forKey: config.subscriptionHistoryKey)
    }

    // MARK: - Lifetime Entitlement (durable, non-expiring)

    public func hasLifetimeEntitlement() -> Bool {
        userDefaults.bool(forKey: config.lifetimeEntitlementKey)
    }

    public func setLifetimeEntitlement(_ entitlement: Bool) {
        if entitlement {
            userDefaults.set(true, forKey: config.lifetimeEntitlementKey)
        } else {
            userDefaults.removeObject(forKey: config.lifetimeEntitlementKey)
        }
        logCacheOperation("Set lifetime entitlement: \(entitlement)")
    }

    // MARK: - Cache Management

    public func clearAllCache() {
        let keys = [
            config.lastValidPurchasesKey,
            config.lastValidationKey,
            config.cachedUserStatusKey,
            config.lastLoginRejectionKey,
            config.lastForegroundCheckKey,
            config.offlineGracePeriodKey,
            config.subscriptionHistoryKey,
            config.lifetimeEntitlementKey
        ]

        for key in keys {
            userDefaults.removeObject(forKey: key)
        }

        logCacheOperation("Cleared all cache")
    }

    /// 清理可挥发的访问证据（当前权益 ID、验证时间、缓存状态、登录/前台检查时间），
    /// 但**保留**可持久的订阅历史与终身买断证据。用于离线宽限期过期：客户的购买身份
    /// 是可持久的，不能因为一次过期的离线宽限而被抹除。完整的全量重置仍由 `clearAllCache()`
    /// （以及 `StoreKitManager.clearOfflineCache()`）负责。
    public func clearVolatileCache() {
        let keys = [
            config.lastValidPurchasesKey,
            config.lastValidationKey,
            config.cachedUserStatusKey,
            config.lastLoginRejectionKey,
            config.lastForegroundCheckKey,
            config.offlineGracePeriodKey
        ]

        for key in keys {
            userDefaults.removeObject(forKey: key)
        }

        logCacheOperation("Cleared volatile cache (preserved subscription history and lifetime)")
    }
    
    // MARK: - Offline Protection
    
    public func getOfflineProtectionStatus(maxGracePeriod: TimeInterval) -> (isProtected: Bool, remainingTime: TimeInterval?) {
        guard let lastValidation = getLastValidationTime() else {
            return (false, nil)
        }
        
        let timeSinceLastValidation = Date().timeIntervalSince(lastValidation)
        let remainingTime = maxGracePeriod - timeSinceLastValidation
        
        return (remainingTime > 0, remainingTime > 0 ? remainingTime : nil)
    }
    
    // MARK: - Status Inference (catalog-agnostic)
    
    public func inferUserStatusFromPurchases() -> UserSubscriptionStatus {
        let purchases = getLastValidPurchases()
        return purchases.isEmpty ? .newUser : .activeSubscriber
    }
    
    // MARK: - Validation Helpers
    
    public func shouldValidateOnStartup() -> Bool {
        // 检查是否有购买记录需要验证
        let purchases = getLastValidPurchases()
        guard !purchases.isEmpty else { return false }
        
        guard let lastValidation = getLastValidationTime() else {
            return true // 有购买但从未验证过，需要验证
        }
        
        let daysSinceLastValidation = Date().timeIntervalSince(lastValidation) / (24 * 60 * 60)
        return daysSinceLastValidation > (config.startupValidationInterval / (24 * 60 * 60))
    }
    
    public func shouldCheckOnForeground() -> Bool {
        guard let lastCheck = getLastForegroundCheckTime() else {
            return true // 从未检查过
        }
        let hours = Date().timeIntervalSince(lastCheck) / 3600
        return hours >= (config.foregroundCheckInterval / 3600)
    }
    
    // MARK: - Logging helper
    private func logCacheOperation(_ message: String) {
        #if DEBUG
        print("[PurchaseCache] \(message)")
        #endif
    }
}
