import Foundation

// MARK: - StoreKit Configuration

public struct StoreKitConfiguration {
    // MARK: - Offline Protection Settings

    /// 离线宽限期（7天）
    public let maxOfflineGracePeriod: TimeInterval

    /// 上次成功验证的缓存键
    public let lastValidationKey: String

    /// 上次有效购买的缓存键
    public let lastValidPurchasesKey: String

    /// 离线宽限期的缓存键
    public let offlineGracePeriodKey: String

    /// 缓存用户状态的键
    public let cachedUserStatusKey: String

    /// 订阅历史证据键（与“当前权益 ID”分离，仅累加、不在权益过期时抹除）
    public let subscriptionHistoryKey: String

    /// 终身买断权益键（非过期权益的持久标记）
    public let lifetimeEntitlementKey: String

    // MARK: - Login Protection Settings

    /// 登录冷却期（30分钟）- 用户拒绝登录后的等待时间
    public let loginCooldownPeriod: TimeInterval

    /// 上次拒绝登录的缓存键
    public let lastLoginRejectionKey: String

    // MARK: - Foreground Check Settings

    /// 前台检查间隔（3小时）- 应用进入前台时检查订阅状态的频率
    public let foregroundCheckInterval: TimeInterval

    /// 上次前台检查的缓存键
    public let lastForegroundCheckKey: String

    // MARK: - Validation Settings

    /// 启动时验证间隔（7天）- 应用启动时进行订阅验证的频率
    public let startupValidationInterval: TimeInterval

    /// 退款检查延迟时间（10分钟）- 应用启动后延迟检查退款的时间
    public let refundCheckDelay: TimeInterval

    /// 前台退款检查间隔（6小时）- 前台检查退款的最小间隔
    public let foregroundRefundCheckInterval: TimeInterval

    // MARK: - Cache Settings

    /// Pro访问状态缓存间隔（30秒）
    public let proAccessCacheInterval: TimeInterval

    /// StoreKit初始化延迟（2秒）- 避免启动时立即弹出登录框
    public let storeKitInitDelay: TimeInterval

    // MARK: - Public Initializer

    /// 以宿主命名空间构造配置；所有持久化键由该命名空间派生。
    ///
    /// - Parameters:
    ///   - namespace: 非空命名空间，例如 `<bundleIdentifier>.PurchaseKit`。
    ///     持久化键形如 `<namespace>.lastSuccessfulValidation`。
    ///   - 其余参数为时间策略，缺省值与生产配置一致。
    public init(
        namespace: String,
        maxOfflineGracePeriod: TimeInterval = 7 * 24 * 60 * 60,
        loginCooldownPeriod: TimeInterval = 30 * 60,
        foregroundCheckInterval: TimeInterval = 3 * 60 * 60,
        startupValidationInterval: TimeInterval = 7 * 24 * 60 * 60,
        refundCheckDelay: TimeInterval = 10 * 60,
        foregroundRefundCheckInterval: TimeInterval = 6 * 60 * 60,
        proAccessCacheInterval: TimeInterval = 30,
        storeKitInitDelay: TimeInterval = 2
    ) {
        let namespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!namespace.isEmpty, "StoreKitConfiguration namespace must not be empty")
        self.maxOfflineGracePeriod = maxOfflineGracePeriod
        self.lastValidationKey = namespace + ".lastSuccessfulValidation"
        self.lastValidPurchasesKey = namespace + ".lastValidPurchases"
        self.offlineGracePeriodKey = namespace + ".offlineGracePeriod"
        self.cachedUserStatusKey = namespace + ".cachedUserStatus"
        self.subscriptionHistoryKey = namespace + ".subscriptionHistory"
        self.lifetimeEntitlementKey = namespace + ".lifetimeEntitlement"
        self.loginCooldownPeriod = loginCooldownPeriod
        self.lastLoginRejectionKey = namespace + ".lastLoginRejection"
        self.foregroundCheckInterval = foregroundCheckInterval
        self.lastForegroundCheckKey = namespace + ".lastForegroundCheck"
        self.startupValidationInterval = startupValidationInterval
        self.refundCheckDelay = refundCheckDelay
        self.foregroundRefundCheckInterval = foregroundRefundCheckInterval
        self.proAccessCacheInterval = proAccessCacheInterval
        self.storeKitInitDelay = storeKitInitDelay
    }

    // MARK: - Namespace Resolution

    /// 宿主 bundle identifier；缺失时退回到包名 `PurchaseKit`。
    private static var hostBundleNamespace: String {
        Bundle.main.bundleIdentifier ?? "PurchaseKit"
    }

    // MARK: - Default Configuration

    /// 生产配置：使用宿主 bundle identifier 加 `.PurchaseKit` 作为命名空间。
    public static let `default` = StoreKitConfiguration(
        namespace: hostBundleNamespace + ".PurchaseKit"
    )

    // MARK: - Debug Configuration

    public static let debug = StoreKitConfiguration(
        namespace: hostBundleNamespace + ".PurchaseKit.debug",
        maxOfflineGracePeriod: 1 * 60 * 60, // 1小时（便于测试）
        loginCooldownPeriod: 5 * 60, // 5分钟（便于测试）
        foregroundCheckInterval: 30 * 60, // 30分钟（更频繁的检查）
        startupValidationInterval: 1 * 60 * 60, // 1小时
        refundCheckDelay: 30, // 30秒
        foregroundRefundCheckInterval: 1 * 60 * 60, // 1小时
        proAccessCacheInterval: 5, // 5秒
        storeKitInitDelay: 0.5 // 0.5秒
    )

    // MARK: - Staging Configuration

    public static let staging = StoreKitConfiguration(
        namespace: hostBundleNamespace + ".PurchaseKit.staging",
        maxOfflineGracePeriod: 3 * 24 * 60 * 60, // 3天
        loginCooldownPeriod: 15 * 60, // 15分钟
        foregroundCheckInterval: 2 * 60 * 60, // 2小时
        startupValidationInterval: 3 * 24 * 60 * 60, // 3天
        refundCheckDelay: 5 * 60, // 5分钟
        foregroundRefundCheckInterval: 3 * 60 * 60, // 3小时
        proAccessCacheInterval: 15, // 15秒
        storeKitInitDelay: 1.0 // 1秒
    )

    // MARK: - Environment Detection

    public static var current: StoreKitConfiguration {
        #if DEBUG
        return .debug
        #elseif STAGING
        return .staging
        #else
        return .default
        #endif
    }
}

// MARK: - Configuration Extensions

public extension StoreKitConfiguration {
    /// 检查配置是否为调试模式
    var isDebugMode: Bool {
        return storeKitInitDelay < 1.0
    }

    /// 获取配置环境名称
    var environmentName: String {
        if isDebugMode {
            return "Debug"
        } else if maxOfflineGracePeriod < 7 * 24 * 60 * 60 {
            return "Staging"
        } else {
            return "Production"
        }
    }
}
