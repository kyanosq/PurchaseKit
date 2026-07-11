import XCTest
import PurchaseKit
import StoreKit

/// Verifies the public configuration surface can be used by a normal downstream
/// client through `import PurchaseKit` alone — no `@testable` access required.
final class PublicAPITests: XCTestCase {

    func testConfigurationCanBeCreatedWithoutTestableImport() {
        let config = StoreKitConfiguration(namespace: "com.example.reader.PurchaseKit")
        XCTAssertEqual(config.lastValidationKey, "com.example.reader.PurchaseKit.lastSuccessfulValidation")
        XCTAssertEqual(config.lastValidPurchasesKey, "com.example.reader.PurchaseKit.lastValidPurchases")
    }

    func testConfigurationDerivesEveryNamespacedKey() {
        let namespace = "com.example.host.app.PurchaseKit"
        let config = StoreKitConfiguration(namespace: namespace)
        XCTAssertEqual(config.lastValidationKey, namespace + ".lastSuccessfulValidation")
        XCTAssertEqual(config.lastValidPurchasesKey, namespace + ".lastValidPurchases")
        XCTAssertEqual(config.offlineGracePeriodKey, namespace + ".offlineGracePeriod")
        XCTAssertEqual(config.cachedUserStatusKey, namespace + ".cachedUserStatus")
        XCTAssertEqual(config.lastLoginRejectionKey, namespace + ".lastLoginRejection")
        XCTAssertEqual(config.lastForegroundCheckKey, namespace + ".lastForegroundCheck")
    }

    func testConfigurationAppliesDefaultIntervals() {
        let config = StoreKitConfiguration(namespace: "com.example.defaults")
        XCTAssertEqual(config.maxOfflineGracePeriod, 7 * 24 * 60 * 60)
        XCTAssertEqual(config.loginCooldownPeriod, 30 * 60)
        XCTAssertEqual(config.foregroundCheckInterval, 3 * 60 * 60)
        XCTAssertEqual(config.startupValidationInterval, 7 * 24 * 60 * 60)
        XCTAssertEqual(config.refundCheckDelay, 10 * 60)
        XCTAssertEqual(config.foregroundRefundCheckInterval, 6 * 60 * 60)
        XCTAssertEqual(config.proAccessCacheInterval, 30)
        XCTAssertEqual(config.storeKitInitDelay, 2)
    }

    func testConfigurationAcceptsIntervalOverrides() {
        let config = StoreKitConfiguration(
            namespace: "com.example.overrides",
            maxOfflineGracePeriod: 120,
            storeKitInitDelay: 0
        )
        XCTAssertEqual(config.maxOfflineGracePeriod, 120)
        XCTAssertEqual(config.storeKitInitDelay, 0)
        // Untouched intervals keep their defaults.
        XCTAssertEqual(config.loginCooldownPeriod, 30 * 60)
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
extension PublicAPITests {
    @MainActor
    func testManagerUsesExplicitCatalog() {
        // 生产构造必须显式传入 catalog；`.stub` 不再是生产默认，仅存在于测试目标。
        let catalog = PurchaseCatalog(
            subscriptionIDs: [
                .monthly: "com.example.monthly",
                .yearly: "com.example.yearly"
            ],
            lifetimeIDs: [.lifetime: "com.example.lifetime"]
        )
        _ = StoreKitManager(catalog: catalog)
    }

    /// 源码契约：StoreKitManager.swift 不得再包含已下线的不安全默认（catalog = .stub）
    /// 或空操作 analytics/campaign API。读取真实源文件断言，防止回归。
    func testStoreKitManagerSourceOmitsUnsafeDefaultsAndNoOpAPIs() throws {
        let testFile = URL(fileURLWithPath: #file)
        let repoRoot = testFile
            .deletingLastPathComponent()   // Tests/PurchaseKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/PurchaseKit/StoreKitManager.swift"),
            encoding: .utf8
        )
        let forbidden = [
            "catalog: PurchaseCatalog = .stub",
            "trackPurchaseEvent",
            "trackOfferEligibilityCheck",
            "triggerWinBackCampaign",
            "triggerRetentionCampaign"
        ]
        for token in forbidden {
            XCTAssertFalse(
                source.contains(token),
                "StoreKitManager.swift 不得包含已下线的不安全默认或空操作 API：\(token)"
            )
        }
    }

    /// 源码契约（促销安全）：显式请求促销优惠但缺签名者时，`purchaseOptions` 必须抛出
    /// `.offerNotAvailable`，**不得**静默退回原价购买（即不得对该分支返回空 option set）。
    /// 读取真实源文件锁定 fail-closed 路径，防止回归为“静默原价”的不安全默认。
    func testStoreKitManagerSourceFailClosesPromotionalOfferWithoutSigner() throws {
        let testFile = URL(fileURLWithPath: #file)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/PurchaseKit/StoreKitManager.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("throw StoreError.offerNotAvailable"),
            "purchaseOptions 在缺签名者/缺匹配 offer/签名失败时必须抛出 .offerNotAvailable"
        )
        // fail-closed 必须出现在促销分支内：缺签名者即抛。
        XCTAssertTrue(
            source.contains("guard let signer = promotionalOfferSigner else"),
            "促销分支必须以 'guard let signer ... else { throw .offerNotAvailable }' 开头，fail closed"
        )
    }

    /// `PricingComparison` 必须对外暴露显式公开 init：宿主仅凭 `import PurchaseKit` 即可构造，
    /// 不能依赖 internal 合成成员 init。以 init 的函数引用作为编译期断言——若 init 退回 internal，
    /// 该引用在普通 `import PurchaseKit` 下将无法编译。
    func testPricingComparisonExposesPublicInitializer() {
        let initializer: (Double, Double, Double, Double) -> PricingComparison =
            PricingComparison.init(lifetimePrice:yearlyPrice:equivalentYears:savings:)
        XCTAssertTrue(
            String(describing: type(of: initializer)).contains("PricingComparison"),
            "PricingComparison 必须暴露可被外部模块引用的公开 init"
        )
    }

    /// 源码契约（公开边界）：生产源码不得重新引入已下线的宿主面向展示文案 / 营销 UI 助手。
    /// 读取 `Sources/PurchaseKit` 下全部 `.swift`，断言被移除的 API 名与宿主文案不再回归。
    /// 这锁定「展示标题 / 徽章 / 消息 / 紧迫感 / 计划推荐 / 本地化周期标签由宿主负责」的公开边界。
    func testProductionSourcesOmitHostFacingMarketingCopy() throws {
        let testFile = URL(fileURLWithPath: #file)
        let repoRoot = testFile
            .deletingLastPathComponent()   // Tests/PurchaseKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let sourcesDir = repoRoot.appendingPathComponent("Sources/PurchaseKit")
        let sourceURLs = FileManager.default
            .enumerator(at: sourcesDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        let source = try (sourceURLs ?? [])
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        // 已下线的宿主面向 / 营销 UI 助手 API 名（连同其公开入口一并移除）。
        let removedAPIs = [
            "optimizePurchaseJourney",
            "PurchaseJourney",
            "UrgencyLevel",
            "isRecommended",
            "PlanComparison",
            "formatPlanComparison",
            "PricingPeriod",
            "formattedInterval",
            "formatPricePerPeriod",
            "getIntroductoryOfferDetails",
            "formatPromotionalOffer",
            "formatSavingsAmount",
            "formatSubscriptionPeriod",
            "getSubscriptionPeriod",
            "isRecommendedPlan"
        ]
        for token in removedAPIs {
            XCTAssertFalse(
                source.contains(token),
                "生产源码不得重新引入已下线的宿主面向 / 营销 UI 助手 API：\(token)"
            )
        }

        // 已下线的宿主面向展示 / 营销文案（库不再产出，由宿主负责）。
        // 仅匹配足够特异的整句 / 标签，避免命中描述纯数值计算的通用注释用词。
        let removedCopy = [
            "Free trial",
            "Equivalent to",
            "免费试用",
            "/天",
            "/周",
            "/月",
            "/年",
            "Save "
        ]
        for token in removedCopy {
            XCTAssertFalse(
                source.contains(token),
                "生产源码不得重新硬编码宿主面向展示 / 营销文案：\(token)"
            )
        }
    }
}
