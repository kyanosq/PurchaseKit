import XCTest
@testable import PurchaseKit

final class StoreKitConfigurationTests: XCTestCase {

    /// 与生产端 `StoreKitConfiguration.hostBundleNamespace` 同样的解析方式，
    /// 便于在测试中推导由 bundle identifier 派生的命名空间键。
    private func expectedNamespace(_ suffix: String) -> String {
        (Bundle.main.bundleIdentifier ?? "PurchaseKit") + ".PurchaseKit" + suffix
    }
    
    // MARK: - Static Configuration Tests
    
    func testDefaultConfiguration() {
        let config = StoreKitConfiguration.default
        
        // 验证默认配置的关键值
        XCTAssertEqual(config.maxOfflineGracePeriod, 7 * 24 * 60 * 60) // 7天
        XCTAssertEqual(config.loginCooldownPeriod, 30 * 60) // 30分钟
        XCTAssertEqual(config.foregroundCheckInterval, 3 * 60 * 60) // 3小时
        XCTAssertEqual(config.startupValidationInterval, 7 * 24 * 60 * 60) // 7天
        XCTAssertEqual(config.refundCheckDelay, 10 * 60) // 10分钟
        XCTAssertEqual(config.foregroundRefundCheckInterval, 6 * 60 * 60) // 6小时
        XCTAssertEqual(config.proAccessCacheInterval, 30) // 30秒
        XCTAssertEqual(config.storeKitInitDelay, 2.0) // 2秒
        
        // 验证key名称：由宿主 bundle identifier 命名空间派生
        let namespace = expectedNamespace("")
        XCTAssertEqual(config.lastValidationKey, namespace + ".lastSuccessfulValidation")
        XCTAssertEqual(config.lastValidPurchasesKey, namespace + ".lastValidPurchases")
        XCTAssertEqual(config.offlineGracePeriodKey, namespace + ".offlineGracePeriod")
        XCTAssertEqual(config.cachedUserStatusKey, namespace + ".cachedUserStatus")
        XCTAssertEqual(config.lastLoginRejectionKey, namespace + ".lastLoginRejection")
        XCTAssertEqual(config.lastForegroundCheckKey, namespace + ".lastForegroundCheck")
    }
    
    func testDebugConfiguration() {
        let config = StoreKitConfiguration.debug
        
        // 调试配置应该有更短的时间间隔便于测试
        XCTAssertEqual(config.maxOfflineGracePeriod, 1 * 60 * 60) // 1小时
        XCTAssertEqual(config.loginCooldownPeriod, 5 * 60) // 5分钟
        XCTAssertEqual(config.foregroundCheckInterval, 30 * 60) // 30分钟
        XCTAssertEqual(config.startupValidationInterval, 1 * 60 * 60) // 1小时
        XCTAssertEqual(config.refundCheckDelay, 30) // 30秒
        XCTAssertEqual(config.foregroundRefundCheckInterval, 1 * 60 * 60) // 1小时
        XCTAssertEqual(config.proAccessCacheInterval, 5) // 5秒
        XCTAssertEqual(config.storeKitInitDelay, 0.5) // 0.5秒
        
        // 验证 debug 环境后缀的命名空间键
        let debugNamespace = expectedNamespace(".debug")
        XCTAssertEqual(config.lastValidationKey, debugNamespace + ".lastSuccessfulValidation")
        XCTAssertEqual(config.lastValidPurchasesKey, debugNamespace + ".lastValidPurchases")
        XCTAssertEqual(config.offlineGracePeriodKey, debugNamespace + ".offlineGracePeriod")
        XCTAssertEqual(config.cachedUserStatusKey, debugNamespace + ".cachedUserStatus")
        XCTAssertEqual(config.lastLoginRejectionKey, debugNamespace + ".lastLoginRejection")
        XCTAssertEqual(config.lastForegroundCheckKey, debugNamespace + ".lastForegroundCheck")
    }
    
    func testStagingConfiguration() {
        let config = StoreKitConfiguration.staging
        
        // 预发布配置应该介于默认和调试之间
        XCTAssertEqual(config.maxOfflineGracePeriod, 3 * 24 * 60 * 60) // 3天
        XCTAssertEqual(config.loginCooldownPeriod, 15 * 60) // 15分钟
        XCTAssertEqual(config.foregroundCheckInterval, 2 * 60 * 60) // 2小时
        XCTAssertEqual(config.startupValidationInterval, 3 * 24 * 60 * 60) // 3天
        XCTAssertEqual(config.refundCheckDelay, 5 * 60) // 5分钟
        XCTAssertEqual(config.foregroundRefundCheckInterval, 3 * 60 * 60) // 3小时
        XCTAssertEqual(config.proAccessCacheInterval, 15) // 15秒
        XCTAssertEqual(config.storeKitInitDelay, 1.0) // 1秒
        
        // 验证 staging 环境后缀的命名空间键
        let stagingNamespace = expectedNamespace(".staging")
        XCTAssertEqual(config.lastValidationKey, stagingNamespace + ".lastSuccessfulValidation")
        XCTAssertEqual(config.lastValidPurchasesKey, stagingNamespace + ".lastValidPurchases")
    }
    
    func testCurrentConfiguration() {
        let config = StoreKitConfiguration.current
        
        // 在DEBUG模式下应该返回debug配置
        #if DEBUG
        XCTAssertEqual(config.storeKitInitDelay, 0.5)
        XCTAssertEqual(config.lastValidationKey, expectedNamespace(".debug") + ".lastSuccessfulValidation")
        #else
        // 在Release模式下应该返回default配置
        XCTAssertEqual(config.storeKitInitDelay, 2.0)
        XCTAssertEqual(config.lastValidationKey, expectedNamespace("") + ".lastSuccessfulValidation")
        #endif
    }
    
    // MARK: - Debug / Environment Semantics Tests

    func testIsDebugMode() {
        let debugConfig = StoreKitConfiguration.debug
        XCTAssertTrue(debugConfig.isDebugMode)
        
        let defaultConfig = StoreKitConfiguration.default
        XCTAssertFalse(defaultConfig.isDebugMode)
        
        let stagingConfig = StoreKitConfiguration.staging
        XCTAssertFalse(stagingConfig.isDebugMode)
    }
    
    func testEnvironmentNameDebug() {
        let config = StoreKitConfiguration.debug
        XCTAssertEqual(config.environmentName, "Debug")
    }
    
    func testEnvironmentNameStaging() {
        let config = StoreKitConfiguration.staging
        XCTAssertEqual(config.environmentName, "Staging")
    }
    
    func testEnvironmentNameProduction() {
        let config = StoreKitConfiguration.default
        XCTAssertEqual(config.environmentName, "Production")
    }
    
    // MARK: - Configuration Consistency Tests
    
    func testAllConfigurationsHaveRequiredKeys() {
        let configs = [
            StoreKitConfiguration.default,
            StoreKitConfiguration.debug,
            StoreKitConfiguration.staging
        ]
        
        for config in configs {
            // 确保所有配置都有非空的key
            XCTAssertFalse(config.lastValidationKey.isEmpty)
            XCTAssertFalse(config.lastValidPurchasesKey.isEmpty)
            XCTAssertFalse(config.offlineGracePeriodKey.isEmpty)
            XCTAssertFalse(config.cachedUserStatusKey.isEmpty)
            XCTAssertFalse(config.lastLoginRejectionKey.isEmpty)
            XCTAssertFalse(config.lastForegroundCheckKey.isEmpty)
            
            // 确保所有时间间隔都是正数
            XCTAssertGreaterThan(config.maxOfflineGracePeriod, 0)
            XCTAssertGreaterThan(config.loginCooldownPeriod, 0)
            XCTAssertGreaterThan(config.foregroundCheckInterval, 0)
            XCTAssertGreaterThan(config.startupValidationInterval, 0)
            XCTAssertGreaterThan(config.refundCheckDelay, 0)
            XCTAssertGreaterThan(config.foregroundRefundCheckInterval, 0)
            XCTAssertGreaterThan(config.proAccessCacheInterval, 0)
            XCTAssertGreaterThanOrEqual(config.storeKitInitDelay, 0)
        }
    }
    
    func testDebugConfigurationHasFasterIntervals() {
        let debug = StoreKitConfiguration.debug
        let production = StoreKitConfiguration.default
        
        // Debug配置的所有时间间隔都应该比生产环境短
        XCTAssertLessThan(debug.maxOfflineGracePeriod, production.maxOfflineGracePeriod)
        XCTAssertLessThan(debug.loginCooldownPeriod, production.loginCooldownPeriod)
        XCTAssertLessThan(debug.foregroundCheckInterval, production.foregroundCheckInterval)
        XCTAssertLessThan(debug.startupValidationInterval, production.startupValidationInterval)
        XCTAssertLessThan(debug.refundCheckDelay, production.refundCheckDelay)
        XCTAssertLessThan(debug.foregroundRefundCheckInterval, production.foregroundRefundCheckInterval)
        XCTAssertLessThan(debug.proAccessCacheInterval, production.proAccessCacheInterval)
        XCTAssertLessThan(debug.storeKitInitDelay, production.storeKitInitDelay)
    }
    
    func testStagingConfigurationHasModerateIntervals() {
        let staging = StoreKitConfiguration.staging
        let debug = StoreKitConfiguration.debug
        let production = StoreKitConfiguration.default
        
        // Staging配置应该介于debug和production之间
        XCTAssertGreaterThan(staging.maxOfflineGracePeriod, debug.maxOfflineGracePeriod)
        XCTAssertLessThan(staging.maxOfflineGracePeriod, production.maxOfflineGracePeriod)
        
        XCTAssertGreaterThan(staging.loginCooldownPeriod, debug.loginCooldownPeriod)
        XCTAssertLessThan(staging.loginCooldownPeriod, production.loginCooldownPeriod)
    }
}
