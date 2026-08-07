import XCTest
import StoreKit
import StoreKitTest
@testable import PurchaseKit

/// StoreKitManager 集成测试
/// 使用 StoreKit Testing 框架进行真实的购买流程测试
@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
final class StoreKitManagerIntegrationTests: XCTestCase {
    
    var manager: StoreKitManager!
    var testHelper: StoreKitTestHelper!
    
    // MARK: - Setup & Teardown
    
    override func setUp() async throws {
        try await super.setUp()
        
        // 初始化测试辅助类
        testHelper = StoreKitTestHelper.shared
        // fail fast：会话创建失败时直接让 setUp 失败，而不是静默继续后误导后续断言。
        try testHelper.enableStoreKitTestSession()
        
        // 创建测试用的 manager
        let catalog = StoreKitTestHelper.createTestCatalog()
        let config = StoreKitTestHelper.createTestConfig()
        
        await MainActor.run {
            manager = StoreKitManager(
                catalog: catalog,
                config: config
            )
        }
        
        // 等待初始化完成
        try await StoreKitTestHelper.wait(200)

        // FB22237318 守卫（Sprint 3 精确化）：仅当运行在受影响的 iOS 26.5 模拟器运行时上、
        // 且构建工具链早于 26.6（修复版本）、且原始 StoreKit 探针确实返回空时，才跳过整个集成层。
        // 在其它任何组合上，空探针必须判为失败——否则资源路径/schema/product ID/StoreKit 设置
        // 的真实回归会被静默吞掉、CI 仍绿。Apple DTS 已确认该问题在 Xcode 26.6 中修复；因此即便
        // 在 iOS 26.5 模拟器运行时上，只要构建工具链已升级到 26.6，空探针也判为失败而非跳过。
        // 探针拿到商品时（.run），所有集成断言照常执行。
        let environmentProbe = try await Product.products(for: [
            StoreKitTestHelper.TestProductID.monthlySubscription,
            StoreKitTestHelper.TestProductID.yearlySubscription
        ])
        switch StoreKitTestingPlatform.outcome(
            probeIsEmpty: environmentProbe.isEmpty,
            runtimeVersion: StoreKitTestingPlatform.currentRuntimeVersion,
            simulator: StoreKitTestingPlatform.currentIsSimulator,
            toolchainVersion: StoreKitTestingPlatform.currentToolchainVersion,
            hosted: StoreKitTestingPlatform.currentIsAppHosted
        ) {
        case .run:
            break
        case .skipUnhosted:
            throw XCTSkip("""
                当前测试进程没有宿主 App（`swift test` / xctest CLI）：storekitd 不向无宿主进程下发 \
                .storekit 配置，SKTestSession 创建成功但 Product.products 必然为空。这是构建方式的 \
                结构性限制，不是回归——同一批断言在 Xcode / 模拟器的 app-hosted 运行下照常执行。 \
                命令行 `swift test` 覆盖的是本包的纯逻辑层。
                """)
        case .skipAffected:
            throw XCTSkip("""
                StoreKit 测试配置未被 storekitd 应用：Product.products 在 SKTestSession 已创建后仍返回空。 \
                当前为 iOS 26.5 模拟器运行时且构建工具链早于 26.6，受 FB22237318 影响 \
                （xcodebuild test CLI 不下发 .storekit 配置）。Apple DTS 已确认该问题在 Xcode 26.6 中修复； \
                升级到 Xcode 26.6+ 后，同一 iOS 26.5 运行时上的空探针将被判为失败而非跳过。 \
                集成测试断言保持完整；在非受影响运行时（如 iOS 18/26.1，或 Xcode 26.6+）上运行可获得完整集成覆盖。
                """)
        case .failRegression:
            XCTFail("""
                Product.products 在当前运行时/工具链组合上仍返回空——这不是平台缺陷，而是资源路径、schema、 \
                product ID 或 StoreKit 测试设置的真实回归。请修复集成配置，而不是跳过。
                """)
        }
    }
    
    override func tearDown() async throws {
        // 清除交易记录
        testHelper.clearTransactions()
        
        await MainActor.run {
            manager = nil
        }
        
        try await super.tearDown()
    }
    
    // MARK: - Product Loading Tests

    func testLoadProducts_Success() async throws {
        // When: Products 应该已经在初始化时加载
        try await StoreKitTestHelper.wait(300)
        
        // Then: 验证产品已加载
        let products = await manager.products
        XCTAssertFalse(products.isEmpty, "应该加载到产品")
        XCTAssertTrue(products.count >= 2, "应该至少有2个产品")
        
        // 验证产品 ID
        let productIDs = Set(products.map { $0.id })
        XCTAssertTrue(
            productIDs.contains(StoreKitTestHelper.TestProductID.monthlySubscription),
            "应该包含月付订阅"
        )
        XCTAssertTrue(
            productIDs.contains(StoreKitTestHelper.TestProductID.yearlySubscription),
            "应该包含年付订阅"
        )
    }
    
    func testLoadProducts_ProductDetails() async throws {
        // When: 获取产品详情
        try await StoreKitTestHelper.wait(300)
        
        let products = await manager.products
        guard let monthlyProduct = products.first(where: {
            $0.id == StoreKitTestHelper.TestProductID.monthlySubscription
        }) else {
            XCTFail("未找到月付产品")
            return
        }
        
        // Then: 验证产品详情
        XCTAssertEqual(monthlyProduct.displayName, "Monthly Subscription")
        XCTAssertEqual(monthlyProduct.description, "Monthly subscription with 1 week free trial")
        XCTAssertNotNil(monthlyProduct.displayPrice)
        
        // 验证订阅信息
        XCTAssertNotNil(monthlyProduct.subscription, "应该有订阅信息")
        if let subscription = monthlyProduct.subscription {
            XCTAssertNotNil(subscription.introductoryOffer, "应该有介绍性优惠")
            XCTAssertEqual(subscription.subscriptionPeriod.unit, .month)
            XCTAssertEqual(subscription.subscriptionPeriod.value, 1)
        }
    }
    
    // MARK: - Purchase Flow Tests
    
    func testPurchaseSubscription_Success() async throws {
        // Given: 等待产品加载
        try await StoreKitTestHelper.wait(300)
        
        // When: 购买月付订阅
        try await manager.purchaseSubscription(.monthly)
        
        // Then: 验证购买成功
        try await StoreKitTestHelper.wait(200)
        
        let purchasedIDs = await manager.purchasedProductIDs
        XCTAssertTrue(
            purchasedIDs.contains(StoreKitTestHelper.TestProductID.monthlySubscription),
            "购买后应该包含该产品 ID"
        )
        
        let userStatus = await manager.userStatus
        XCTAssertTrue(
            userStatus == .activeSubscriber || userStatus == .trialUser,
            "用户状态应该是活跃订阅或试用"
        )
    }

    func testPurchaseSubscription_RefreshesIntroOfferEligibility() async throws {
        try await StoreKitTestHelper.wait(300)

        let monthlyID = StoreKitTestHelper.TestProductID.monthlySubscription
        let eligibleBeforePurchase = await manager.eligibleIntroductoryOfferProductIDs
        XCTAssertTrue(
            eligibleBeforePurchase.contains(monthlyID),
            "购买前，月付产品应保留介绍性优惠资格"
        )

        try await manager.purchaseSubscription(.monthly)
        try await StoreKitTestHelper.wait(200)

        let eligibleAfterPurchase = await manager.eligibleIntroductoryOfferProductIDs
        XCTAssertFalse(
            eligibleAfterPurchase.contains(monthlyID),
            "购买后，应清除同订阅组的介绍性优惠资格，避免继续显示试用文案"
        )
    }
    
    func testPurchaseLifetime_Success() async throws {
        // Given: 等待产品加载
        try await StoreKitTestHelper.wait(300)
        
        // When: 购买终身版
        try await manager.purchaseLifetime(.lifetime)
        
        // Then: 验证购买成功
        try await StoreKitTestHelper.wait(200)
        
        let purchasedIDs = await manager.purchasedProductIDs
        XCTAssertTrue(
            purchasedIDs.contains(StoreKitTestHelper.TestProductID.lifetime),
            "购买后应该包含终身版产品 ID"
        )
        
        let canAccess = await manager.canAccessProFeatures()
        XCTAssertTrue(canAccess, "购买终身版后应该能访问 Pro 功能")
    }
    
    // MARK: - Entitlement Verification Tests
    
    func testRestoreEntitlements_WithActivePurchase() async throws {
        // Given: 先购买一个订阅
        try await StoreKitTestHelper.wait(300)
        try await manager.purchaseSubscription(.monthly)
        try await StoreKitTestHelper.wait(200)
        
        // 清除本地状态（模拟重装应用）
        testHelper.clearTransactions()
        
        // 重新创建 manager
        let catalog = StoreKitTestHelper.createTestCatalog()
        let config = StoreKitTestHelper.createTestConfig()
        
        await MainActor.run {
            manager = StoreKitManager(catalog: catalog, config: config)
        }
        
        // When: 恢复购买
        try await manager.restorePurchases()
        try await StoreKitTestHelper.wait(300)
        
        // Then: 应该恢复购买记录
        let purchasedIDs = await manager.purchasedProductIDs
        XCTAssertFalse(purchasedIDs.isEmpty, "恢复后应该有购买记录")
        
        let userStatus = await manager.userStatus
        XCTAssertNotEqual(userStatus, .newUser, "恢复后用户状态不应该是新用户")
    }
    
    func testRestoreEntitlements_NoPurchase() async throws {
        // Given: 没有任何购买记录
        try await StoreKitTestHelper.wait(300)
        
        // When: 恢复购买
        try await manager.restorePurchases()
        try await StoreKitTestHelper.wait(200)
        
        // Then: 应该没有购买记录
        let purchasedIDs = await manager.purchasedProductIDs
        XCTAssertTrue(purchasedIDs.isEmpty, "没有购买时应该是空的")
        
        let userStatus = await manager.userStatus
        XCTAssertEqual(userStatus, .newUser, "没有购买时应该是新用户")
    }

    func testRestoreEntitlementsSilently_ClearsStaleActiveTransactionWhenSubscriptionDisappears() async throws {
        try await StoreKitTestHelper.wait(300)
        try await manager.purchaseSubscription(.monthly)
        try await StoreKitTestHelper.wait(200)

        let activeTransactionAfterPurchase = await manager.activeTransaction
        XCTAssertNotNil(activeTransactionAfterPurchase, "购买订阅后应记录活跃交易")

        testHelper.clearTransactions()
        await manager.restoreEntitlementsSilently()
        try await StoreKitTestHelper.wait(200)

        let activeTransactionAfterSilentRestore = await manager.activeTransaction
        XCTAssertNil(
            activeTransactionAfterSilentRestore,
            "静默恢复后若已无自动续订权益，不应保留旧的 activeTransaction"
        )
    }
    
    // MARK: - User Status Tests
    
    func testUserStatus_NewUser() async throws {
        // Given: 新用户（没有购买）
        try await StoreKitTestHelper.wait(300)
        
        // Then: 验证用户状态
        let userStatus = await manager.userStatus
        XCTAssertEqual(userStatus, .newUser, "初始状态应该是新用户")
        
        let hasValidSub = await manager.hasValidSubscription()
        XCTAssertFalse(hasValidSub, "新用户没有有效订阅")
        
        let canAccess = await manager.canAccessProFeatures()
        XCTAssertFalse(canAccess, "新用户无法访问 Pro 功能")
    }
    
    func testUserStatus_AfterPurchase() async throws {
        // Given: 购买订阅
        try await StoreKitTestHelper.wait(300)
        try await manager.purchaseSubscription(.monthly)
        try await StoreKitTestHelper.wait(200)
        
        // Then: 验证用户状态
        let userStatus = await manager.userStatus
        XCTAssertTrue(
            userStatus == .activeSubscriber || userStatus == .trialUser,
            "购买后应该是活跃用户或试用用户"
        )
        
        let hasValidSub = await manager.hasValidSubscription()
        XCTAssertTrue(hasValidSub, "购买后应该有有效订阅")
        
        let canAccess = await manager.canAccessProFeatures()
        XCTAssertTrue(canAccess, "购买后应该能访问 Pro 功能")
    }
    
    // MARK: - Price Formatting Tests
    
    func testGetFormattedPrice() async throws {
        // Given: 等待产品加载
        try await StoreKitTestHelper.wait(300)
        
        // When: 获取格式化价格
        let monthlyPrice = await manager.getFormattedPrice(for: .monthly)
        let yearlyPrice = await manager.getFormattedPrice(for: .yearly)
        
        // Then: 验证价格格式
        XCTAssertNotNil(monthlyPrice, "月付价格不应为空")
        XCTAssertNotNil(yearlyPrice, "年付价格不应为空")
        
        // 价格应该包含货币符号或数字
        if let price = monthlyPrice {
            XCTAssertFalse(price.isEmpty, "价格字符串不应为空")
        }
    }
    
    func testGetPriceValue() async throws {
        // Given: 等待产品加载
        try await StoreKitTestHelper.wait(300)
        
        // When: 获取数值价格
        let monthlyValue = await manager.getPriceValue(for: .monthly)
        let yearlyValue = await manager.getPriceValue(for: .yearly)
        
        // Then: 验证价格数值
        XCTAssertNotNil(monthlyValue, "月付价格数值不应为空")
        XCTAssertNotNil(yearlyValue, "年付价格数值不应为空")
        
        if let monthly = monthlyValue, let yearly = yearlyValue {
            XCTAssertGreaterThan(monthly, 0, "月付价格应该大于0")
            XCTAssertGreaterThan(yearly, 0, "年付价格应该大于0")
            XCTAssertGreaterThan(yearly, monthly, "年付价格通常大于月付")
        }
    }
    
    func testCalculateYearlySavings() async throws {
        // Given: 等待产品加载
        try await StoreKitTestHelper.wait(300)
        
        // When: 计算年付节省
        let savings = await manager.getYearlySavings()
        
        // Then: 验证节省计算
        XCTAssertNotNil(savings, "应该能计算节省百分比")
        
        if let savingsString = savings {
            XCTAssertFalse(savingsString.isEmpty, "节省百分比不应为空")
            XCTAssertTrue(savingsString.contains("%"), "应该包含百分号")
        }
    }
    
    // MARK: - Feature Access Tests
    
    func testCanAccessProFeatures_WithSubscription() async throws {
        // Given: 购买订阅
        try await StoreKitTestHelper.wait(300)
        try await manager.purchaseSubscription(.monthly)
        try await StoreKitTestHelper.wait(200)
        
        // When/Then: 应该能访问 Pro 功能
        let canAccess = await manager.canAccessProFeatures()
        XCTAssertTrue(canAccess, "有订阅时应该能访问 Pro 功能")
        
        let hasValidSub = await manager.hasValidSubscription()
        XCTAssertTrue(hasValidSub, "应该有有效订阅")
    }
    
    func testCanAccessProFeatures_WithLifetime() async throws {
        // Given: 购买终身版
        try await StoreKitTestHelper.wait(300)
        try await manager.purchaseLifetime(.lifetime)
        try await StoreKitTestHelper.wait(200)
        
        // When/Then: 应该能访问 Pro 功能
        let canAccess = await manager.canAccessProFeatures()
        XCTAssertTrue(canAccess, "有终身版时应该能访问 Pro 功能")
    }
    
    func testCanAccessProFeatures_NoPurchase() async throws {
        // Given: 没有购买
        try await StoreKitTestHelper.wait(300)
        
        // When/Then: 不应该能访问 Pro 功能
        let canAccess = await manager.canAccessProFeatures()
        XCTAssertFalse(canAccess, "没有购买时不能访问 Pro 功能")
    }
    
    // MARK: - Subscription Period Tests

    func testGetSubscriptionPeriod() async throws {
        // Given: 等待产品加载
        try await StoreKitTestHelper.wait(300)

        // When: 读取 StoreKit 结构化订阅周期（UI 无关；库不再产出本地化周期文案）。
        let monthlyPeriod = await manager.product(for: .monthly)?.subscription?.subscriptionPeriod
        let yearlyPeriod = await manager.product(for: .yearly)?.subscription?.subscriptionPeriod

        // Then: 验证结构化周期单位（月付为 .month，年付为 .year）。
        XCTAssertEqual(monthlyPeriod?.unit, .month, "月付订阅周期单位应为 .month")
        XCTAssertEqual(yearlyPeriod?.unit, .year, "年付订阅周期单位应为 .year")
    }

    func testGetIntroductoryOfferDetails() async throws {
        // Given: 等待产品加载
        try await StoreKitTestHelper.wait(300)

        // When: 读取 StoreKit 结构化介绍性优惠（UI 无关；库不再产出试用文案）。
        let monthlyIntro = await manager.product(for: .monthly)?.subscription?.introductoryOffer
        let yearlyIntro = await manager.product(for: .yearly)?.subscription?.introductoryOffer

        // Then: 验证两个产品都带免费试用（paymentMode == .freeTrial）。
        XCTAssertEqual(monthlyIntro?.paymentMode, .freeTrial, "月付应带免费试用介绍性优惠")
        XCTAssertEqual(yearlyIntro?.paymentMode, .freeTrial, "年付应带免费试用介绍性优惠")
    }
}
