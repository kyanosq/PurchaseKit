import Foundation
import StoreKit
import StoreKitTest
@testable import PurchaseKit

/// StoreKit 测试辅助类
/// 用于配置和管理 StoreKit 测试会话
@available(iOS 15.0, macOS 12.0, watchOS 8.0, tvOS 15.0, *)
final class StoreKitTestHelper {

    // MARK: - Singleton

    static let shared = StoreKitTestHelper()

    private var session: SKTestSession?

    private init() {}

    // MARK: - Session Management

    /// 启用 StoreKit 测试会话。失败时直接抛错（fail fast），让 setUp 失败而不是静默继续。
    /// - Parameter configFileName: StoreKit 配置文件名（不含 .storekit 扩展名）
    func enableStoreKitTestSession(configFileName: String = "PurchaseKitTest") throws {
        // SPM 会把 .storekit 放进嵌套资源子包（PurchaseKit_PurchaseKitTests.bundle），
        // 按名搜索会得到 SKTestErrorDomain Code=4 "File not found"。这里用 URL 定位并直接传入。
        guard let url = Self.locateConfigurationFile(name: configFileName) else {
            print("[StoreKitTestHelper] Configuration file \(configFileName).storekit not found in any test bundle")
            throw StoreError.productNotFound
        }
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        self.session = session
        print("[StoreKitTestHelper] Test session enabled: \(configFileName)")
    }

    /// 在测试 bundle、主 bundle 及其嵌套资源子包中查找 .storekit 配置文件。
    ///
    /// `Bundle.module` 必须排在最前：SwiftPM 命令行构建把资源包放在 `.xctest` 的**同级目录**
    /// （`.build/<triple>/debug/PurchaseKit_PurchaseKitTests.bundle`），不在 `.xctest` 内部，
    /// 因此下面那轮「向每个 bundle 要它自己 Resources 里的 .bundle」永远扫不到它。
    /// `Bundle.module` 由 SwiftPM 为带资源的目标生成，在 Xcode 与命令行两种布局下都正确。
    private static func locateConfigurationFile(name: String) -> URL? {
        if let url = Bundle.module.url(forResource: name, withExtension: "storekit") {
            return url
        }
        let bundles: [Bundle] = [Bundle(for: StoreKitTestHelper.self), Bundle.main] + Bundle.allBundles
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: "storekit") {
                return url
            }
            if let subBundles = bundle.urls(forResourcesWithExtension: "bundle", subdirectory: nil) {
                for subURL in subBundles {
                    if let subBundle = Bundle(url: subURL),
                       let url = subBundle.url(forResource: name, withExtension: "storekit") {
                        return url
                    }
                }
            }
        }
        return nil
    }

    /// 清除所有交易记录
    func clearTransactions() {
        session?.clearTransactions()
        print("[StoreKitTestHelper] Transactions cleared")
    }

    /// 重置测试会话
    func resetSession() {
        session?.clearTransactions()
        session = nil
        print("[StoreKitTestHelper] Session reset")
    }

    /// 设置是否禁用对话框
    func setDisableDialogs(_ disable: Bool) {
        session?.disableDialogs = disable
    }

    // MARK: - Purchase Simulation

    /// 模拟购买成功
    /// - Parameter productID: 产品 ID
    func simulatePurchaseSuccess(for productID: String) {
        // StoreKit Test 会自动处理购买成功
        print("[StoreKitTestHelper] Purchase success simulated for: \(productID)")
    }

    /// 模拟用户取消购买
    func simulatePurchaseCancellation() {
        // 可以通过 SKTestSession 的 API 模拟各种场景
        print("[StoreKitTestHelper] Purchase cancellation simulated")
    }

    /// 模拟退款
    /// - Parameter transactionID: 交易 ID
    func simulateRefund(for transactionID: UInt64) async throws {
        try session?.refundTransaction(identifier: UInt(transactionID))
        print("[StoreKitTestHelper] Refund simulated for transaction: \(transactionID)")
    }

    /// 过期订阅（用于测试过期场景）
    func expireSubscription() async throws {
        try session?.expireSubscription(productIdentifier: "")
        print("[StoreKitTestHelper] Subscription expired")
    }

    // MARK: - Test Catalog Helper

    /// 创建测试用的 Catalog
    static func createTestCatalog() -> PurchaseCatalog {
        return PurchaseCatalog(
            subscriptionIDs: [
                .monthly: "com.test.subscription.monthly",
                .yearly: "com.test.subscription.yearly"
            ],
            lifetimeIDs: [:]
        )
    }

    /// 创建测试用的 Configuration
    static func createTestConfig() -> StoreKitConfiguration {
        return StoreKitConfiguration(
            namespace: "test.integration." + UUID().uuidString,
            maxOfflineGracePeriod: 86400,
            loginCooldownPeriod: 600,
            foregroundCheckInterval: 3600,
            startupValidationInterval: 3600,
            refundCheckDelay: 0, // 测试时无延迟
            foregroundRefundCheckInterval: 3600,
            proAccessCacheInterval: 60,
            storeKitInitDelay: 0 // 测试时无延迟
        )
    }

    // MARK: - Async Helper

    /// 等待异步操作完成
    /// - Parameter milliseconds: 等待时间（毫秒）
    static func wait(_ milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

// MARK: - Test Product IDs

@available(iOS 15.0, macOS 12.0, watchOS 8.0, tvOS 15.0, *)
extension StoreKitTestHelper {

    /// 测试产品 ID
    enum TestProductID {
        static let monthlySubscription = "com.test.subscription.monthly"
        static let yearlySubscription = "com.test.subscription.yearly"
        static let monthlyPremium = "com.test.premium.monthly"
        static let yearlyPremium = "com.test.premium.yearly"
        static let lifetime = "com.test.premium.lifetime"
    }
}

// MARK: - StoreKit 集成探针平台判定（Sprint 3：加入构建工具链维度）

/// 集成层“空探针”应如何处置的纯枚举结果。
enum StoreKitConfigProbeOutcome {
    /// 探针拿到商品：正常执行集成断言。
    case run
    /// 空探针 + 受影响的 iOS 26.5 模拟器运行时且构建工具链早于修复版本：跳过（已知平台缺陷）。
    case skipAffected
    /// 空探针 + 当前测试进程没有宿主 App：`storekitd` 不向无宿主进程下发 `.storekit` 配置，
    /// 这是 SwiftPM 命令行 `swift test` 的结构性限制，不是回归。同一批断言在 Xcode/模拟器
    /// 的宿主运行下照常执行。
    case skipUnhosted
    /// 空探针 + 其它任何组合：判为真实回归（资源路径/schema/product ID/StoreKit 设置问题）。
    case failRegression
}

/// 把“空探针是否跳过”这一判断收敛为可单测的纯逻辑，避免集成层把任何空探针都当作平台缺陷跳过。
///
/// 判据同时考虑两个维度：
/// - **运行时维度**：仅 iOS 26.5 模拟器运行时受 FB22237318 影响——`xcodebuild test`（CLI）
///   不向目标模拟器的 `storekitd` 下发 `.storekit` 配置，`SKTestSession` 静默退回生产 App Store，
///   `Product.products(for:)` 返回空。
/// - **构建工具链维度**（Sprint 3 加入）：Apple DTS 已确认该问题在 **Xcode 26.6** 中修复。
///   因此即便目标仍是 iOS 26.5 模拟器运行时，只要构建工具链已升级到 26.6，空探针就必须判为
///   真实回归并失败——不得继续跳过、掩盖本应由 Xcode 26.6 修复的回归。
enum StoreKitTestingPlatform {

    /// FB22237318 的修复版本：Xcode 26.6（即 iOS 26.6 SDK）。构建工具链达到或超过该版本时，
    /// 即便目标为 iOS 26.5 模拟器运行时，也不再受 `.storekit` 配置下发缺陷影响。
    static let storeKitConfigPushFixedInToolchain = OperatingSystemVersion(
        majorVersion: 26,
        minorVersion: 6,
        patchVersion: 0
    )

    /// 运行时维度：仅 iOS 26.5 模拟器运行时受影响。纯函数，便于确定性回归。
    static func isAffectedRuntime(_ runtimeVersion: OperatingSystemVersion, simulator: Bool) -> Bool {
        guard simulator else { return false }
        return runtimeVersion.majorVersion == 26 && runtimeVersion.minorVersion == 5
    }

    /// 工具链维度：构建工具链早于修复版本时受影响。无法确定工具链版本时保守视为受影响，
    /// 以保留本地已记录的 Xcode 26.5 跳过行为；CI 不使用 iOS 26.5 运行时，故该保守回退不影响门禁。
    static func isAffectedToolchain(_ toolchainVersion: OperatingSystemVersion?) -> Bool {
        guard let toolchainVersion else { return true }
        return !isAtLeast(toolchainVersion, storeKitConfigPushFixedInToolchain)
    }

    /// 纯函数：由探针、宿主环境、运行时与构建工具链决定集成层处置。可在不启动 StoreKit 的情况下
    /// 做确定性回归：空探针只有两种被原谅的理由——**没有宿主 App**，或**受影响运行时 ∧ 受影响
    /// 工具链**——其余一律判失败。
    ///
    /// `hosted` 默认 `true`，使既有调用点（都描述宿主模拟器场景）语义不变。
    static func outcome(
        probeIsEmpty: Bool,
        runtimeVersion: OperatingSystemVersion,
        simulator: Bool,
        toolchainVersion: OperatingSystemVersion?,
        hosted: Bool = true
    ) -> StoreKitConfigProbeOutcome {
        if !probeIsEmpty { return .run }
        // 无宿主优先：它是比平台缺陷更根本、也更确定的解释——没有宿主 App 时
        // `storekitd` 根本不会收到配置，与运行时版本无关。
        if !hosted { return .skipUnhosted }
        let affected = isAffectedRuntime(runtimeVersion, simulator: simulator)
            && isAffectedToolchain(toolchainVersion)
        return affected ? .skipAffected : .failRegression
    }

    /// `OperatingSystemVersion` 非原生 `Comparable`，按 major/minor/patch 比较“是否达到”。
    private static func isAtLeast(_ lhs: OperatingSystemVersion, _ rhs: OperatingSystemVersion) -> Bool {
        if lhs.majorVersion != rhs.majorVersion { return lhs.majorVersion > rhs.majorVersion }
        if lhs.minorVersion != rhs.minorVersion { return lhs.minorVersion > rhs.minorVersion }
        return lhs.patchVersion >= rhs.patchVersion
    }

    // MARK: - 运行时探测（用于集成层 setUp）

    /// 当前进程运行的 OS 版本（模拟器上即模拟器运行时的 iOS 版本）。
    static var currentRuntimeVersion: OperatingSystemVersion {
        ProcessInfo.processInfo.operatingSystemVersion
    }

    /// 当前测试进程是否有宿主 App。`swift test` / `xctest` CLI 下主 bundle 是 xctest 工具本身
    /// （或干脆没有 bundle identifier）；Xcode 的 app-hosted 测试里主 bundle 是被测 App。
    static var currentIsAppHosted: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return identifier != "com.apple.dt.xctest.tool"
    }

    /// 当前是否运行在模拟器上。
    static var currentIsSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// 构建本测试 bundle 所用的 Xcode/SDK 版本。从构建产物的 `DTPlatformVersion`/`DTSDKName`
    /// 解析；无法确定时返回 nil（由谓词保守视为受影响）。
    static var currentToolchainVersion: OperatingSystemVersion? {
        detectBuildSDKVersion()
    }

    /// 当前是否受 FB22237318 影响：同时满足受影响运行时与受影响工具链。
    static var isAffectedByStoreKitConfigPushDefect: Bool {
        isAffectedRuntime(currentRuntimeVersion, simulator: currentIsSimulator)
            && isAffectedToolchain(currentToolchainVersion)
    }

    private static func detectBuildSDKVersion() -> OperatingSystemVersion? {
        let bundles: [Bundle] = [Bundle(for: StoreKitTestHelper.self), Bundle.main] + Bundle.allBundles
        for bundle in bundles {
            guard let info = bundle.infoDictionary else { continue }
            if let platformVersion = info["DTPlatformVersion"] as? String,
               let version = parseVersion(platformVersion) {
                return version
            }
            if let sdkName = info["DTSDKName"] as? String,
               let version = parseVersion(fromTrailingDigits: sdkName) {
                return version
            }
        }
        return nil
    }

    private static func parseVersion(_ text: String) -> OperatingSystemVersion? {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return OperatingSystemVersion(
            majorVersion: parts[0],
            minorVersion: parts[1],
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
    }

    /// 从形如 `iphonesimulator26.5` 的 SDK 名称中解析尾部的版本号。
    private static func parseVersion(fromTrailingDigits sdkName: String) -> OperatingSystemVersion? {
        guard let range = sdkName.range(of: #"\d"#, options: .regularExpression) else { return nil }
        return parseVersion(String(sdkName[range.lowerBound...]))
    }
}
