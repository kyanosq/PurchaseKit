import Foundation
import StoreKit
import Combine
import os
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// 发行版里也会执行的日志走统一日志系统，不走 stdout。与 `UserDefaultsProtocol` 一致：
/// 可能暴露用户购买内容的字段按 `.private` 打点，不在设备日志里留下明文商品 ID。
/// （`PurchaseCache` 的调试日志本就用 `#if DEBUG` 包住，这里补的是发行版也会跑的那些。）
private let storeLog = Logger(subsystem: "PurchaseKit", category: "Store")

// MARK: - Notification Names

public extension Notification.Name {
    static let purchaseRefunded = Notification.Name("purchaseRefunded")
    static let purchaseValidationFailed = Notification.Name("purchaseValidationFailed")
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
public struct PromotionalOfferSignature: Sendable {
    public let offerID: String
    public let keyIdentifier: String
    public let nonce: UUID
    public let signature: Data
    public let timestamp: Int

    public init(offerID: String, keyIdentifier: String, nonce: UUID, signature: Data, timestamp: Int) {
        self.offerID = offerID
        self.keyIdentifier = keyIdentifier
        self.nonce = nonce
        self.signature = signature
        self.timestamp = timestamp
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
public protocol PromotionalOfferSigning {
    func signingInfo(for product: Product, offer: Product.SubscriptionOffer) async throws -> PromotionalOfferSignature
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
@MainActor
@Observable
public final class StoreKitManager {
    
    // MARK: - Catalog
    private let catalog: PurchaseCatalog
    
    // MARK: - Published Properties
    
    public private(set) var userStatus: UserSubscriptionStatus = .newUser
    public private(set) var availableSubscriptions: [SubscriptionType] = []
    public private(set) var availableLifetimePurchases: [LifetimePurchase] = []
    public private(set) var currentOffer: OfferType = .none
    public private(set) var products: [Product] = []
    public private(set) var purchasedProductIDs: Set<String> = []
    public private(set) var subscriptionGroupStatus: RenewalState = .expired
    public private(set) var activeTransaction: Transaction?
    public private(set) var eligiblePromotionalOffers: [Product.SubscriptionOffer] = []
    
    // MARK: - Private Properties
    
    @ObservationIgnored private var updateListenerTask: Task<Void, Never>?
    @ObservationIgnored private var refundCheckTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    public private(set) var eligibleIntroductoryOfferProductIDs: Set<String> = []
    
    // MARK: - Service Dependencies
    
    private let config: StoreKitConfiguration
    private let purchaseCache: PurchaseCacheProtocol
    private let pricingFormatter: PricingFormatter
    private let storeKitService: StoreKitServiceProtocol
    @ObservationIgnored private var promotionalOfferSigner: PromotionalOfferSigning?
    
    // Invalidates suspended scans when another scan, delivery or reset supersedes them.
    private var entitlementRevision = 0
    private enum PersistenceError: Error { case writeFailed }

    // MARK: - Offline Purchase Protection
    
    private var lastValidPurchases: Set<String> {
        get { purchaseCache.getLastValidPurchases() }
        set {
            purchaseCache.setLastValidPurchases(newValue)
            saveCachedUserStatus()
        }
    }
    
    private var cachedUserStatus: UserSubscriptionStatus {
        get { purchaseCache.getCachedUserStatus() ?? purchaseCache.inferUserStatusFromPurchases() }
        set { purchaseCache.setCachedUserStatus(newValue) }
    }

    private var lifetimeProductIDSet: Set<String> {
        Set(catalog.lifetimeProductIDs())
    }

    private func lifetimePurchases(from purchases: Set<String>) -> Set<String> {
        purchases.intersection(lifetimeProductIDSet)
    }

    // MARK: - Entitlement facts (fed into EntitlementStateResolver)

    /// 最近一次已验证计算得到的“当前活跃订阅/试用/续订意图”快照。
    /// 来自当前权益或直接交易交付的已验证事实，不包含离线推测。
    private var entitlementHasActiveSubscription = false
    private var entitlementIsTrial = false
    private var entitlementWillAutoRenew = true
    @ObservationIgnored private var renewalInfoVerified = false

    /// 终身证据在启动时从缓存还原，随后仅由已提交的当前权益决定。它不会关闭
    /// 非交互式 `Transaction.currentEntitlements` 刷新或事务监听。
    private func hasDurableLifetime() -> Bool {
        !lifetimePurchases(from: purchasedProductIDs).isEmpty
    }

    /// 经过验证后写入的订阅历史证据，与当前权益 ID 分离。
    private func hadSubscriptionHistory() -> Bool {
        !purchaseCache.getSubscriptionHistory().isEmpty
    }

    /// 离线宽限证据：仅在仍在宽限期内、且本地仍有已验证购买记录时成立。
    private func hasOfflineEvidence() -> Bool {
        let protection = purchaseCache.getOfflineProtectionStatus(maxGracePeriod: config.maxOfflineGracePeriod)
        return protection.isProtected && !purchasedProductIDs.isDisjoint(with: catalog.subscriptionIDs.values)
    }

    /// 当前订阅是否自动续订。无法验证续订信息时不判为 cancelled（保持 activeSubscriber）。
    private func resolvedWillAutoRenew(hasActiveSubscription: Bool) -> Bool {
        guard hasActiveSubscription else { return true }
        return renewalInfoVerified ? entitlementWillAutoRenew : true
    }
    
    private func saveCachedUserStatus() {
        purchaseCache.setCachedUserStatus(userStatus)
    }
    
    private var lastValidationTime: Date? {
        get { purchaseCache.getLastValidationTime() }
        set { purchaseCache.setLastValidationTime(newValue) }
    }
    
    // MARK: - Login State Protection
    
    private var lastLoginRejectionTime: Date? {
        get { purchaseCache.getLastLoginRejectionTime() }
        set { purchaseCache.setLastLoginRejectionTime(newValue) }
    }
    
    private var lastForegroundCheckTime: Date? {
        get { purchaseCache.getLastForegroundCheckTime() }
        set { purchaseCache.setLastForegroundCheckTime(newValue) }
    }
    
    private var isInLoginCooldown: Bool { purchaseCache.isInLoginCooldown() }
    
    private func isUserCancellationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "ASDErrorDomain" && nsError.code == 500 { return true }
        if nsError.domain == SKErrorDomain && nsError.code == SKError.paymentCancelled.rawValue { return true }
        if nsError.code == NSUserCancelledError { return true }
        return false
    }
    
    private enum StoreKitErrorHandlingResult {
        case userCancelled
        case networkError
        case unknown(Error)
        var shouldFallbackToCache: Bool {
            switch self {
            case .userCancelled, .networkError: return true
            case .unknown: return true
            }
        }
    }
    
    private func handleStoreKitError(_ error: Error) -> StoreKitErrorHandlingResult {
        if isUserCancellationError(error) { lastLoginRejectionTime = Date(); return .userCancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return .networkError }
        if error is StoreError { return .unknown(error) }
        return .unknown(error)
    }

    private func normalizeStoreError(_ error: Error) -> StoreError {
        if let storeError = error as? StoreError { return storeError }
        switch handleStoreKitError(error) {
        case .userCancelled:
            return .userCancelled
        case .networkError:
            return .networkError
        case .unknown:
            return .unknown
        }
    }
    
    // MARK: - Initialization
    
    public init(
        catalog: PurchaseCatalog,
        config: StoreKitConfiguration = .current,
        purchaseCache: PurchaseCacheProtocol? = nil,
        pricingFormatter: PricingFormatter? = nil,
        storeKitService: StoreKitServiceProtocol? = nil,
        promotionalOfferSigner: PromotionalOfferSigning? = nil
    ) {
        self.catalog = catalog
        self.config = config
        self.purchaseCache = purchaseCache ?? PurchaseCache(config: config)
        self.pricingFormatter = pricingFormatter ?? PricingFormatter()
        self.storeKitService = storeKitService ?? RealStoreKitService()
        self.promotionalOfferSigner = promotionalOfferSigner

        restoreStateFromCache()
        updateListenerTask = listenForTransactions()

        Task { @MainActor in
            try await Task.sleep(nanoseconds: UInt64(config.storeKitInitDelay * 1_000_000_000))
            do {
                try await loadProducts()
            } catch {
                storeLog.error("Failed to load products during initialization: \(String(describing: error), privacy: .public)")
            }
            await restoreEntitlementsSilently()
            if self.purchaseCache.shouldValidateOnStartup() && !self.purchaseCache.isInLoginCooldown() {
                await validatePurchasesWithFallback()
            }
            await optimizeCurrentOffer()
        }
        
#if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleAppWillEnterForeground()
            }
        }
#endif
    }
    
    // MARK: - State restore
    private func restoreStateFromCache() {
        let cachedPurchases = purchaseCache.getLastValidPurchases().intersection(catalog.allProductIDs)
        let cachedLifetimePurchases = lifetimePurchases(from: cachedPurchases)
        let protection = purchaseCache.getOfflineProtectionStatus(maxGracePeriod: config.maxOfflineGracePeriod)

        // 在替换/清理可挥发的当前 ID 之前，先把它们播种进可持久的订阅历史与终身证据。
        // 这是从旧的 `lastValidPurchases` 表示升级的路径：曾经付费的客户，不能因为之后
        // 一次离线宽限期过期就丢失购买身份。订阅 ID 与终身 ID 的拆分由显式 catalog 驱动。
        seedDurableEvidence(from: cachedPurchases)

        let hasDurableLifetimeFlag = purchaseCache.hasLifetimeEntitlement()

        if !cachedPurchases.isEmpty && protection.isProtected {
            purchasedProductIDs = hasDurableLifetimeFlag ? cachedPurchases.union(lifetimeProductIDSet) : cachedPurchases
            if !cachedLifetimePurchases.isEmpty || hasDurableLifetimeFlag {
                userStatus = .activeSubscriber
            } else if let cachedStatus = purchaseCache.getCachedUserStatus() {
                userStatus = cachedStatus
            } else {
                userStatus = purchaseCache.inferUserStatusFromPurchases()
            }
            saveCachedUserStatus()
        } else if hasDurableLifetimeFlag || !cachedLifetimePurchases.isEmpty {
            // 终身买断是可持久证据：即便订阅离线宽限已过期、或当前没有任何缓存 ID，
            // 也必须还原激活访问。仅有终身标记（无当前 ID）时退回到 catalog 的终身 ID 集。
            let lifetimeIDs = cachedLifetimePurchases.isEmpty ? lifetimeProductIDSet : cachedLifetimePurchases
            purchasedProductIDs = lifetimeIDs
            purchaseCache.setLastValidPurchases(lifetimeIDs)
            purchaseCache.setLifetimeEntitlement(true)
            userStatus = .activeSubscriber
            saveCachedUserStatus()
        } else if !protection.isProtected && !cachedPurchases.isEmpty {
            // 离线宽限期已过期：仅清理可挥发的访问证据。上面已播种的可持久订阅历史与终身
            // 证据保留下来，因此客户的已验证购买身份不会被抹除。
            let hadHistory = hadSubscriptionHistory()
            purchaseCache.clearVolatileCache()
            purchasedProductIDs = []
            userStatus = hadHistory ? .expiredSubscriber : .newUser
            saveCachedUserStatus()
        } else {
            userStatus = .newUser
        }
    }

    /// 用显式 catalog 把缓存的当前购买 ID 拆分为订阅 ID 与终身 ID，并播种进可持久的
    /// 订阅历史与终身证据。仅累加、不覆盖；空集合为 no-op。
    private func seedDurableEvidence(from cachedPurchases: Set<String>) {
        guard !cachedPurchases.isEmpty else { return }
        let lifetimeIDs = lifetimePurchases(from: cachedPurchases)
        let subscriptionIDs = cachedPurchases.intersection(catalog.subscriptionIDs.values)
        if !subscriptionIDs.isEmpty {
            purchaseCache.recordSubscriptionHistory(subscriptionIDs)
        }
        if !lifetimeIDs.isEmpty {
            purchaseCache.setLifetimeEntitlement(true)
        }
    }
    
    func clearLoginCooldown() { lastLoginRejectionTime = nil }
    
    private func shouldValidateOnStartup() -> Bool {
        purchaseCache.shouldValidateOnStartup() && !purchaseCache.isInLoginCooldown()
    }
    
    /// 回到前台时重新解析权益。**不调用 `AppStore.sync()`**。
    ///
    /// 这里原本先 `sync()` 再刷新，而 `sync()` 会弹 App Store 登录框。
    /// `willEnterForeground` 在**冷启动**时也会发一次（`didFinishLaunching` 之后、
    /// `didBecomeActive` 之前），下面那道节流只挡 6 小时——于是任何隔天打开 app 的
    /// 老用户，一启动就被要求登录 App Store，谁也没点过「恢复购买」。
    ///
    /// StoreKit 2 的 `currentEntitlements` 本身就是最新的，`forceRefreshPurchases()`
    /// 读它即可，无需 `sync()`。Apple 也明确 `AppStore.sync()` 只应由用户显式动作
    /// 触发——现在它只剩 `restorePurchases()` 这一个调用点，也就是「恢复购买」按钮。
    /// `internal` 而非 `private`：观察者的注册在 `#if canImport(UIKit)` 之下，
    /// 而包的测试跑在 macOS 上——靠发通知来测会变成一条永远不执行的绿测试。
    func handleAppWillEnterForeground() async {
        if purchaseCache.isInLoginCooldown() { return }
        guard purchaseCache.shouldCheckOnForeground() else { return }
        if let lastValidation = lastValidationTime {
            let hours = Date().timeIntervalSince(lastValidation) / 3600
            if hours < 6 { return }
        }
        let cachedPurchases = purchaseCache.getLastValidPurchases().intersection(catalog.allProductIDs)
        guard !cachedPurchases.isEmpty else { return }
        lastForegroundCheckTime = Date()
        await forceRefreshPurchases()
    }
    
    private func validatePurchasesWithFallback() async {
        do {
            try await updateUserPurchases()
            await updateUserStatus(refreshPurchases: false)
        } catch is CancellationError { return
        } catch StoreError.failedVerification { return
        } catch is PersistenceError { return
        } catch {
            let result = handleStoreKitError(error)
            if result.shouldFallbackToCache { await handleOfflineValidation() }
        }
    }
    
    deinit {
        updateListenerTask?.cancel()
        refundCheckTask?.cancel()
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }
    
    // MARK: - Products loading
    private var productsLoadTask: Task<[Product], Error>?

    private func loadProducts(forceRefresh: Bool = false) async throws {
        if !forceRefresh && !products.isEmpty { return }

        if forceRefresh {
            productsLoadTask?.cancel()
            productsLoadTask = nil
        }

        if let task = productsLoadTask {
            do {
                let fetched = try await task.value
                try await applyLoadedProducts(fetched)
                return
            } catch {
                productsLoadTask = nil
                if error is PurchaseCatalogError { throw StoreError.productNotFound }
                throw error
            }
        }

        let ids = Set(catalog.allProductIDs)
        let task = Task<[Product], Error> {
            try await storeKitService.fetchProducts(for: ids)
        }
        productsLoadTask = task

        do {
            let fetched = try await task.value
            try await applyLoadedProducts(fetched)
        } catch {
            productsLoadTask = nil
            if error is PurchaseCatalogError { throw StoreError.productNotFound }
            throw error
        }
    }

    private func applyLoadedProducts(_ loadedProducts: [Product]) async throws {
        defer { productsLoadTask = nil }
        products = loadedProducts
        let availableIDs = Set(loadedProducts.map { $0.id })
        availableSubscriptions = try catalog.availableSubscriptions(in: availableIDs)
        availableLifetimePurchases = try catalog.availableLifetimePurchases(in: availableIDs)
        await loadOfferEligibility()
        await loadPromotionalOffers()
    }

    private func loadOfferEligibility() async {
        await updateOfferEligibility()
    }

    private func loadPromotionalOffers() async {
        eligiblePromotionalOffers.removeAll()
        for product in products where product.type == .autoRenewable {
            if let subscription = product.subscription {
                eligiblePromotionalOffers.append(contentsOf: subscription.promotionalOffers)
            }
        }
    }
    
    // MARK: - Transaction listener
    private func listenForTransactions() -> Task<Void, Never> {
        let updates = storeKitService.transactionUpdates()
        return Task { [weak self] in
            for await result in updates {
                guard let self else { return }
                await self.processTransactionUpdate(result)
            }
        }
    }

    private func processTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        do {
            try await deliverTransaction(result.mapEntitlement()) {
                if case .verified(let transaction) = result { await transaction.finish() }
            }
        } catch {
            storeLog.error("Transaction not delivered; left unfinished: \(String(describing: error), privacy: .public)")
        }
    }

    // The same delivery boundary is used by purchases and Transaction.updates.
    // Finish only after the verified entitlement has been persisted and published.
    func deliverTransaction(
        _ result: Result<EntitlementTransaction, Error>,
        finish: () async -> Void
    ) async throws {
        let entitlement = try result.get()
        guard supports(entitlement) else { throw StoreError.productNotFound }
        try applyEntitlements([entitlement], complete: false, currentSnapshot: false)
        await finish()
        if let revoked = entitlement.revocationDate {
            NotificationCenter.default.post(name: .purchaseRefunded, object: self, userInfo: [
                "productID": entitlement.productID, "revocationDate": revoked,
                "revocationReason": entitlement.transaction?.revocationReason?.rawValue ?? "unknown"
            ])
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified: throw StoreError.failedVerification
        case .verified(let safe): return safe
        }
    }

    // MARK: - User status management
    private func updateUserStatus(refreshPurchases: Bool = true) async {
        if refreshPurchases {
            do { try await updateUserPurchases() } catch { return }
        }
        let revision = entitlementRevision
        await updateSubscriptionGroupStatus()
        guard !Task.isCancelled, revision == entitlementRevision else { return }
        calculateUserStatusFromPurchases()
        await updateOfferEligibility()
    }

    private func calculateUserStatusFromPurchases() {
        let facts = EntitlementFacts(
            hasActiveSubscription: entitlementHasActiveSubscription,
            hasLifetime: hasDurableLifetime(),
            isTrial: entitlementIsTrial,
            willAutoRenew: resolvedWillAutoRenew(hasActiveSubscription: entitlementHasActiveSubscription),
            hadSubscriptionHistory: hadSubscriptionHistory(),
            renewalState: subscriptionGroupStatus,
            hasOfflineEvidence: hasOfflineEvidence()
        )
        userStatus = EntitlementStateResolver.userStatus(from: facts)
        saveCachedUserStatus()
    }

    private func updateSubscriptionGroupStatus() async {
        guard let subscription = products.first(where: { $0.type == .autoRenewable })?.subscription else { return }
        let revision = entitlementRevision
        do {
            let statuses = try await subscription.status
            guard !Task.isCancelled, revision == entitlementRevision else { return }
            let verifiedStatuses = statuses.filter {
                if case .verified = $0.transaction, case .verified = $0.renewalInfo { return true }
                return false
            }
            guard !verifiedStatuses.isEmpty else { return }
            let prioritized = verifiedStatuses.max { lhs, rhs in
                renewalStatePriority(mapRenewalState(lhs.state)) < renewalStatePriority(mapRenewalState(rhs.state))
            }
            let state = prioritized.map { mapRenewalState($0.state) } ?? .expired
            // 验证续订信息以确定 willAutoRenew。验证失败时不把用户判为 cancelled。
            if let chosen = prioritized {
                do {
                    let renewalInfo = try checkVerified(chosen.renewalInfo)
                    self.subscriptionGroupStatus = state
                    self.entitlementWillAutoRenew = renewalInfo.willAutoRenew
                    self.renewalInfoVerified = true
                } catch {
                    self.renewalInfoVerified = false
                }
            } else {
                self.subscriptionGroupStatus = state
            }
        } catch { storeLog.error("Failed to update subscription group status: \(String(describing: error), privacy: .public)") }
    }

    private func mapRenewalState(_ state: Product.SubscriptionInfo.RenewalState) -> RenewalState {
        switch state {
        case .subscribed:
            return .subscribed
        case .inGracePeriod:
            return .inGracePeriod
        case .inBillingRetryPeriod:
            return .inBillingRetryPeriod
        case .expired:
            return .expired
        case .revoked:
            return .revoked
        default:
            return .expired
        }
    }

    private func renewalStatePriority(_ state: RenewalState) -> Int {
        switch state {
        case .subscribed:
            return 5
        case .inGracePeriod:
            return 4
        case .inBillingRetryPeriod:
            return 3
        case .expired:
            return 2
        case .revoked:
            return 1
        }
    }
    
    private func updateUserPurchases() async throws {
        if isInLoginCooldown { throw StoreError.userCancelled }
        try await refreshEntitlements(from: storeKitService.currentEntitlements().map { $0.mapEntitlement() })
    }

    func refreshEntitlements<S: AsyncSequence>(from stream: S) async throws
    where S.Element == Result<EntitlementTransaction, Error> {
        try Task.checkCancellation()
        entitlementRevision += 1
        let revision = entitlementRevision
        var verified: [EntitlementTransaction] = []
        var complete = true
        for try await result in stream {
            try Task.checkCancellation()
            switch result {
            case .success(let transaction): verified.append(transaction)
            case .failure: complete = false
            }
        }
        try Task.checkCancellation()
        guard revision == entitlementRevision else { throw CancellationError() }
        try applyEntitlements(verified, complete: complete, currentSnapshot: true)
        // A partial result may add verified rights, but cannot prove other rights absent.
        if !complete { throw StoreError.failedVerification }
    }

    private func supports(_ item: EntitlementTransaction) -> Bool {
        switch item.productType {
        case .autoRenewable: return catalog.subscriptionIDs.values.contains(item.productID)
        case .nonConsumable: return lifetimeProductIDSet.contains(item.productID)
        default: return false
        }
    }

    private func applyEntitlements(
        _ items: [EntitlementTransaction], complete: Bool, currentSnapshot: Bool
    ) throws {
        entitlementRevision += 1
        var purchased = complete ? [] : purchasedProductIDs.intersection(catalog.allProductIDs)
        var active = complete ? nil : activeTransaction
        var trial = complete ? false : entitlementIsTrial
        var verifiedSubscriptionIDs = !complete && entitlementHasActiveSubscription
            ? purchasedProductIDs.intersection(catalog.subscriptionIDs.values) : []
        var revokedSubscription = false
        for item in items where supports(item) {
            let expired = item.expirationDate.map { $0 <= Date() } ?? false
            if item.revocationDate != nil || item.isUpgraded || (!currentSnapshot && expired) {
                purchased.remove(item.productID)
                if item.productType == .autoRenewable {
                    verifiedSubscriptionIDs.remove(item.productID)
                    if active?.productID == item.productID { active = nil }
                    revokedSubscription = revokedSubscription || item.revocationDate != nil
                }
                continue
            }
            purchased.insert(item.productID)
            if item.productType == .autoRenewable {
                verifiedSubscriptionIDs.insert(item.productID)
                trial = item.isTrial
                active = expired ? nil : item.transaction
                purchaseCache.recordSubscriptionHistory([item.productID])
            }
        }
        let hasSubscription = !verifiedSubscriptionIDs.isEmpty
        if !hasSubscription { trial = false }
        // Persist before acknowledging delivery. A failed cache must leave the transaction retryable.
        purchaseCache.setLastValidPurchases(purchased)
        let lifetime = !lifetimePurchases(from: purchased).isEmpty
        purchaseCache.setLifetimeEntitlement(lifetime)
        let persisted = purchaseCache.getLastValidPurchases() == purchased
            && (lifetime || !purchaseCache.hasLifetimeEntitlement())
        if persisted && (complete || (!currentSnapshot && hasSubscription)) { lastValidationTime = Date() }
        purchasedProductIDs = purchased
        activeTransaction = active
        entitlementHasActiveSubscription = hasSubscription
        entitlementIsTrial = trial
        if hasSubscription {
            // currentEntitlements also includes subscriptions in billing grace; no product fetch is needed to grant.
            subscriptionGroupStatus = .subscribed
        } else if revokedSubscription {
            subscriptionGroupStatus = .revoked
        } else if complete {
            subscriptionGroupStatus = .expired
        }
        calculateUserStatusFromPurchases()
        guard persisted else { throw PersistenceError.writeFailed }
    }

    private func handleOfflineValidation() async {
        guard !Task.isCancelled else { return }
        entitlementRevision += 1
        entitlementHasActiveSubscription = false
        entitlementIsTrial = false
        activeTransaction = nil
        do {
            let cachedPurchases = purchaseCache.getLastValidPurchases().intersection(catalog.allProductIDs)
            let cachedLifetimePurchases = lifetimePurchases(from: cachedPurchases)
            let cachedStatus = purchaseCache.getCachedUserStatus()
            let hadPurchaseHistory = !cachedPurchases.isEmpty || (cachedStatus != nil && cachedStatus != .newUser)
            let protection = purchaseCache.getOfflineProtectionStatus(maxGracePeriod: config.maxOfflineGracePeriod)
            if protection.isProtected {
                self.purchasedProductIDs = cachedPurchases
                if !cachedLifetimePurchases.isEmpty {
                    self.userStatus = .activeSubscriber
                } else if let cachedStatus {
                    self.userStatus = cachedStatus
                } else {
                    self.userStatus = purchaseCache.inferUserStatusFromPurchases()
                }
                self.saveCachedUserStatus()
            } else if !cachedLifetimePurchases.isEmpty {
                self.purchasedProductIDs = cachedLifetimePurchases
                purchaseCache.setLastValidPurchases(cachedLifetimePurchases)
                self.lastValidationTime = nil
                self.userStatus = .activeSubscriber
                self.saveCachedUserStatus()
            } else {
                self.purchasedProductIDs = []
                purchaseCache.setLastValidPurchases([])
                self.lastValidationTime = nil
                // 无购买历史的用户在离线/校验失败时应保持 newUser，避免误判为过期用户。
                self.userStatus = hadPurchaseHistory ? .expiredSubscriber : .newUser
                self.saveCachedUserStatus()
            }
        }
    }
    
    // MARK: - Public API
    public func restoreEntitlementsSilently() async {
        do {
            try await updateUserPurchases()
            await updateUserStatus(refreshPurchases: false)
        } catch {
            // Cancellation and incomplete verification must not replace the last committed snapshot.
            storeLog.info("Silent entitlement refresh did not complete: \(String(describing: error), privacy: .public)")
        }
    }

    public func checkUserEligibility() async -> UserOfferEligibility {
        await updateOfferEligibility()
        switch userStatus {
        case .newUser:
            if await canReceiveIntroductoryOffer(), let freeTrial = OfferStrategy.newUserFreeTrial(from: self) {
                return .eligible(.introductory(freeTrial))
            } else if let firstMonthOffer = OfferStrategy.newUserFirstMonth(from: self) {
                return .eligible(.introductory(firstMonthOffer))
            } else {
                return .ineligible
            }
        case .expiredSubscriber, .cancelledSubscriber:
            if await canReceivePromotionalOffer(), let winBack = OfferStrategy.winBackOffer(from: self) {
                return .eligible(.promotional(winBack))
            } else {
                return .ineligible
            }
        case .activeSubscriber:
            if await shouldOfferRetention(), let retention = OfferStrategy.retentionOffer(from: self) {
                return .eligible(.promotional(retention))
            } else { return .ineligible }
        case .trialUser: return .ineligible
        }
    }
    
    private func updateOfferEligibility() async {
        eligibleIntroductoryOfferProductIDs.removeAll()
        for product in products where product.type == .autoRenewable {
            if let subscription = product.subscription, subscription.introductoryOffer != nil {
                let isEligible = await isEligibleForIntroductoryOffer(productID: product.id)
                if isEligible { eligibleIntroductoryOfferProductIDs.insert(product.id) }
            }
        }
    }
    
    private func canReceiveIntroductoryOffer() async -> Bool {
        for subscriptionType in availableSubscriptions {
            do {
                let id = try catalogProductID(for: subscriptionType)
                if await isEligibleForIntroductoryOffer(productID: id) { return true }
            } catch {
                #if DEBUG
                print("[StoreKitManager] catalogProductID(for:) failed for \(subscriptionType): \(error)")
                #endif
                continue
            }
        }
        return false
    }
    
    private func canReceivePromotionalOffer() async -> Bool {
        // 无签名者时绝不展示 win-back，避免把无法签名的促销暴露给用户。
        return PromotionalOfferPolicy.canSurfaceOffer(hasSigner: promotionalOfferSigner != nil, status: userStatus)
    }

    private func shouldOfferRetention() async -> Bool {
        guard PromotionalOfferPolicy.canSurfaceOffer(hasSigner: promotionalOfferSigner != nil, status: userStatus) else {
            return false
        }
        guard let transaction = activeTransaction, let expirationDate = transaction.expirationDate else { return false }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0
        return days <= 7 && days > 0
    }
    
    private func isEligibleForIntroductoryOffer(productID: String) async -> Bool {
        guard let product = products.first(where: { $0.id == productID }), let subscription = product.subscription else { return false }
        return await subscription.isEligibleForIntroOffer
    }
    
    private func optimizeCurrentOffer() async {
        let eligibility = await checkUserEligibility()
        await MainActor.run {
            switch eligibility {
            case .eligible(let offer): self.currentOffer = offer
            case .ineligible, .unknown: self.currentOffer = .none
            }
        }
    }
    
    public func purchaseSubscription(_ type: SubscriptionType, applying offerOverride: OfferType? = nil) async throws {
        clearLoginCooldown()
        let product = try await fetchProduct(for: type)
        // 显式请求促销优惠但无法签名时，purchaseOptions 会抛出 .offerNotAvailable，购买直接失败而不走原价。
        let purchaseOptions = try await purchaseOptions(for: product, type: type, offer: offerOverride ?? currentOffer)
        let result: Product.PurchaseResult
        result = try await storeKitService.purchase(product, options: purchaseOptions)
        try await handlePurchaseResult(result)
    }

    public func purchaseLifetime(_ type: LifetimePurchase) async throws {
        clearLoginCooldown()
        let id = try catalogProductID(for: type)
        let product = try await fetchProduct(byID: id)
        let result = try await storeKitService.purchase(product, options: [])
        try await handlePurchaseResult(result)
    }
    
    public func restorePurchases() async throws {
        clearLoginCooldown()
        do {
            try await storeKitService.sync()
            try await updateUserPurchases()
        } catch {
            throw normalizeStoreError(error)
        }
        await updateUserStatus(refreshPurchases: false)
        await optimizeCurrentOffer()
    }
    
    public func forceRefreshPurchases() async {
        do {
            try await updateUserPurchases()
            await updateUserStatus(refreshPurchases: false)
        } catch is CancellationError { return
        } catch StoreError.failedVerification { return
        } catch is PersistenceError { return
        } catch {
            await handleOfflineValidation()
        }
        await optimizeCurrentOffer()
    }

    public func reloadProducts() async throws {
        do {
            try await loadProducts(forceRefresh: true)
        } catch {
            throw normalizeStoreError(error)
        }
        await optimizeCurrentOffer()
    }

    public func setPromotionalOfferSigner(_ signer: PromotionalOfferSigning?) {
        promotionalOfferSigner = signer
    }

    public func getOfflineProtectionStatus() -> (isProtected: Bool, remainingTime: TimeInterval?) {
        purchaseCache.getOfflineProtectionStatus(maxGracePeriod: config.maxOfflineGracePeriod)
    }
    
    /// 同步清空持久化缓存与全部内存权益状态。manager 为 @MainActor，直接在当前上下文重置，
    /// 不派发新任务，确保调用返回后状态立即一致。
    public func clearOfflineCache() {
        entitlementRevision += 1
        purchaseCache.clearAllCache()
        purchasedProductIDs = []
        userStatus = .newUser
        activeTransaction = nil
        currentOffer = .none
        subscriptionGroupStatus = .expired
        entitlementHasActiveSubscription = false
        entitlementIsTrial = false
        entitlementWillAutoRenew = true
        renewalInfoVerified = false
        eligiblePromotionalOffers = []
        eligibleIntroductoryOfferProductIDs = []
    }

    public func startPeriodicRefundCheck() {
        refundCheckTask?.cancel()
        // 把依赖 self 的值先拷贝为局部量，任务体只在 sleep 之后再 guard self，
        // 这样任务在挂起期间不会强持有 manager。
        let delayNanoseconds = UInt64(config.refundCheckDelay * 1_000_000_000)
        let cache = purchaseCache
        refundCheckTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            if Task.isCancelled { return }
            guard let self else { return }
            if !cache.getLastValidPurchases().isEmpty { await self.handleAppWillEnterForeground() }
        }
    }
    
    // MARK: - Marketing campaign triggers
    // 已移除空的 win-back / retention campaign 触发方法：它们只是重新计算状态、不提供任何行为，
    // 属于应用专属埋点/营销入口，不应出现在 UI 无关的公开库中。

#if canImport(UIKit)
    public func presentOfferCodeRedemption(in windowScene: UIWindowScene) async throws {
        do {
            try await AppStore.presentOfferCodeRedeemSheet(in: windowScene)
        } catch {
            if let storeKitError = error as? StoreError {
                switch storeKitError {
                case .userCancelled: throw StoreError.userCancelled
                case .networkError: throw StoreError.networkError
                default: throw StoreError.unknown
                }
            } else if (error as NSError).domain == NSURLErrorDomain {
                throw StoreError.networkError
            } else {
                throw StoreError.unknown
            }
        }
    }
#endif
    
    public func checkFamilySharingStatus() async -> Bool {
        guard let transaction = activeTransaction else { return false }
        return transaction.ownershipType == .familyShared
    }
    
    public func getSubscriptionStatus() async -> Product.SubscriptionInfo.Status? {
        guard let product = products.first(where: { $0.type == .autoRenewable }), let subscription = product.subscription else { return nil }
        do {
            let statuses = try await subscription.status
            return statuses.first
        } catch {
            _ = handleStoreKitError(error)
            storeLog.error("Failed to read subscription status: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
    
    public func willRenewAutomatically() async -> Bool {
        guard let status = await getSubscriptionStatus() else { return false }
        do {
            let renewalInfo = try checkVerified(status.renewalInfo)
            return renewalInfo.willAutoRenew
        } catch {
            _ = handleStoreKitError(error)
            storeLog.error("Failed to verify renewal info: \(String(describing: error), privacy: .public)")
            return false
        }
    }
    
    public func getExpirationDate() async -> Date? { activeTransaction?.expirationDate }
    public func getNextBillingDate() async -> Date? { activeTransaction?.expirationDate }

    // MARK: - Convenience helpers for App UI
    public func getProductPrice(_ type: SubscriptionType) -> String? { getFormattedPrice(for: type) }
    public func getProductLocalizedDescription(_ type: SubscriptionType) -> String? {
        do {
            let id = try catalogProductID(for: type)
            return products.first(where: { $0.id == id })?.description
        } catch {
            #if DEBUG
            print("[StoreKitManager] catalogProductID(for:) failed in getProductLocalizedDescription: \(error)")
            #endif
            return nil
        }
    }

    public func getFormattedPrice(for type: SubscriptionType) -> String? {
        do {
            let id = try catalogProductID(for: type)
            if let product = products.first(where: { $0.id == id }) { return pricingFormatter.getFormattedPrice(for: product) }
            return nil
        } catch {
            #if DEBUG
            print("[StoreKitManager] catalogProductID(for:) failed in getFormattedPrice: \(error)")
            #endif
            return nil
        }
    }

    public func getFormattedPrice(for type: LifetimePurchase) -> String? {
        do {
            let id = try catalogProductID(for: type)
            if let product = products.first(where: { $0.id == id }) { return pricingFormatter.getFormattedPrice(for: product) }
            return nil
        } catch {
            #if DEBUG
            print("[StoreKitManager] catalogProductID(for:) failed in getFormattedPrice(lifetime): \(error)")
            #endif
            return nil
        }
    }

    public func getPriceValue(for type: SubscriptionType) -> Double? {
        do {
            let id = try catalogProductID(for: type)
            guard let product = products.first(where: { $0.id == id }) else { return nil }
            return pricingFormatter.getFormattedPriceValue(for: product)
        } catch {
            #if DEBUG
            print("[StoreKitManager] catalogProductID(for:) failed in getPriceValue: \(error)")
            #endif
            return nil
        }
    }

    public func getPriceValue(for type: LifetimePurchase) -> Double? {
        do {
            let id = try catalogProductID(for: type)
            guard let product = products.first(where: { $0.id == id }) else { return nil }
            return pricingFormatter.getFormattedPriceValue(for: product)
        } catch {
            #if DEBUG
            print("[StoreKitManager] catalogProductID(for:) failed in getPriceValue(lifetime): \(error)")
            #endif
            return nil
        }
    }
    
    public func calculateLifetimeSavings(for lifetimePlan: LifetimePurchase) -> PricingComparison? {
        guard let lifetimePrice = getPriceValue(for: lifetimePlan), let yearlyPrice = getPriceValue(for: .yearly) else { return nil }
        return pricingFormatter.calculateLifetimeSavings(lifetimePrice: lifetimePrice, yearlyPrice: yearlyPrice)
    }
    
    public func formatCurrency(_ value: Double) -> String { pricingFormatter.formatCurrency(value) }

    // MARK: - Price Comparison Helpers
    
    /// 获取年付的月均价格
    /// - Parameter type: 订阅类型（应该是 .yearly）
    /// - Returns: 基于 StoreKit Decimal 与 product.priceFormatStyle 的月均价格字符串。
    public func getMonthlyEquivalentPrice(for type: SubscriptionType) -> String? {
        guard type == .yearly, let yearlyProduct = product(for: .yearly) else { return nil }
        return pricingFormatter.monthlyEquivalent(for: yearlyProduct)
    }

    /// 计算年付相比月付的节省百分比
    /// - Returns: 格式化的节省百分比字符串（如 "40%"）；月付价格非正（如配置成免费）
    ///   或没有节省时返回 nil，避免出现 "nan%" / 负数文案。
    public func getYearlySavings() -> String? {
        guard let yearlyPrice = getPriceValue(for: .yearly),
              let monthlyPrice = getPriceValue(for: .monthly),
              let percentage = pricingFormatter.yearlySavingsPercentage(monthlyPrice: monthlyPrice, yearlyPrice: yearlyPrice),
              percentage > 0 else {
            return nil
        }
        return String(format: "%.0f%%", percentage)
    }

    /// 获取年付相比月付的具体节省金额（带货币符号）
    /// - Returns: 格式化的节省金额字符串（如 "$33"）；没有节省时返回 nil。
    public func getYearlySavingsAmount() -> String? {
        guard let yearlyPrice = getPriceValue(for: .yearly),
              let monthlyPrice = getPriceValue(for: .monthly),
              let amount = pricingFormatter.yearlySavingsAmount(monthlyPrice: monthlyPrice, yearlyPrice: yearlyPrice),
              amount > 0 else {
            return nil
        }
        return formatCurrency(amount)
    }
    
    public func hasValidSubscription() -> Bool { userStatus == .activeSubscriber || userStatus == .trialUser }
    
    public func proAccessState() -> ProAccessState {
        _ = entitlementRevision // Track cache-backed changes through Observation as well.
        // 经纯函数解析器决定访问状态：撤销永远拒绝且优先于离线宽限；终身证据优先。
        let facts = EntitlementFacts(
            hasActiveSubscription: entitlementHasActiveSubscription,
            hasLifetime: hasDurableLifetime(),
            isTrial: entitlementIsTrial,
            willAutoRenew: resolvedWillAutoRenew(hasActiveSubscription: entitlementHasActiveSubscription),
            hadSubscriptionHistory: hadSubscriptionHistory(),
            renewalState: subscriptionGroupStatus,
            hasOfflineEvidence: hasOfflineEvidence()
        )
        return EntitlementStateResolver.accessState(from: facts)
    }

    // Cache check with offline protection & lifetime purchase
    public func canAccessProFeatures() -> Bool {
        proAccessState().grantsAccess
    }

    /// 本地存在「一旦校验成功即可恢复」的权益证据。
    ///
    /// 与订阅历史不同，此查询刻意排除仅过期 / 取消的历史，避免宿主对已流失用户
    /// 误称「上线后权益会回来」。它在三种情况下为真：本地仍有当前已验证购买 ID、
    /// 持有持久终身买断标记，或当前访问状态已授权（活跃订阅 / 终身 / 离线宽限）。
    /// 这是 UI 无关的结构化权益查询：宿主据此决定是否提示「联网后恢复」，而非营销文案。
    public var hasLocalRestorableEntitlementEvidence: Bool {
        if !purchaseCache.getLastValidPurchases().isEmpty { return true }
        if purchaseCache.hasLifetimeEntitlement() { return true }
        return canAccessProFeatures()
    }
    
    // MARK: - Helpers to map type -> Product
    public func productID(for type: SubscriptionType) throws -> String {
        try catalog.productID(for: type)
    }

    public func productID(for type: LifetimePurchase) throws -> String {
        try catalog.productID(for: type)
    }
    public func product(for type: SubscriptionType) -> Product? {
        do {
            let id = try catalogProductID(for: type)
            return products.first { $0.id == id }
        } catch {
            #if DEBUG
            print("[StoreKitManager] catalogProductID(for:) failed in product(for: SubscriptionType): \(error)")
            #endif
            return nil
        }
    }
    public func product(for type: LifetimePurchase) -> Product? {
        do {
            let id = try catalogProductID(for: type)
            return products.first { $0.id == id }
        } catch {
            #if DEBUG
            print("[StoreKitManager] catalogProductID(for:) failed in product(for: LifetimePurchase): \(error)")
            #endif
            return nil
        }
    }

    public func hasEligibleIntroductoryOffer(for type: SubscriptionType) -> Bool {
        do {
            let id = try catalogProductID(for: type)
            return eligibleIntroductoryOfferProductIDs.contains(id)
        } catch {
            #if DEBUG
            print("[StoreKitManager] catalogProductID(for:) failed in hasEligibleIntroductoryOffer: \(error)")
            #endif
            return false
        }
    }
    
    // MARK: - Purchase handling
    private func handlePurchaseResult(_ result: Product.PurchaseResult) async throws {
        switch result {
        case .success(let verification):
            try await deliverTransaction(verification.mapEntitlement()) {
                if case .verified(let transaction) = verification { await transaction.finish() }
            }
        case .userCancelled: throw StoreError.userCancelled
        case .pending: throw StoreError.pending
        @unknown default: throw StoreError.unknown
        }
    }
}

// MARK: - Private helpers

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
extension StoreKitManager {
    private func catalogProductID(for type: SubscriptionType) throws -> String {
        do {
            return try catalog.productID(for: type)
        } catch {
            throw StoreError.productNotFound
        }
    }

    private func catalogProductID(for type: LifetimePurchase) throws -> String {
        do {
            return try catalog.productID(for: type)
        } catch {
            throw StoreError.productNotFound
        }
    }

    private func fetchProduct(for type: SubscriptionType) async throws -> Product {
        let id = try catalogProductID(for: type)
        return try await fetchProduct(byID: id)
    }

    private func fetchProduct(byID id: String) async throws -> Product {
        if let product = products.first(where: { $0.id == id }) { return product }
        try await loadProducts()
        if let product = products.first(where: { $0.id == id }) { return product }
        try await loadProducts(forceRefresh: true)
        if let product = products.first(where: { $0.id == id }) { return product }
        throw StoreError.productNotFound
    }

    private func purchaseOptions(for product: Product, type _: SubscriptionType, offer: OfferType?) async throws -> Set<Product.PurchaseOption> {
        guard let offer else { return [] }
        switch offer {
        case .promotional(let promotionalOffer):
            // 显式请求促销优惠时必须 fail closed：缺签名者、缺匹配 StoreKit offer 或签名失败
            // 都抛出 `.offerNotAvailable`，绝不退回原价购买。
            guard let signer = promotionalOfferSigner else {
                throw StoreError.offerNotAvailable
            }
            guard let storeOffer = promotionalStoreOffer(for: product, promotionalOffer: promotionalOffer) else {
                throw StoreError.offerNotAvailable
            }
            do {
                let signature = try await signer.signingInfo(for: product, offer: storeOffer)
                let option = Product.PurchaseOption.promotionalOffer(
                    offerID: signature.offerID,
                    keyID: signature.keyIdentifier,
                    nonce: signature.nonce,
                    signature: signature.signature,
                    timestamp: signature.timestamp
                )
                return Set([option])
            } catch {
                throw StoreError.offerNotAvailable
            }
        case .offerCode:
            // Offer codes must be redeemed through the dedicated StoreKit sheet prior to purchase.
            return []
        case .introductory, .none:
            return []
        }
    }

    private func promotionalStoreOffer(for product: Product, promotionalOffer: PromotionalOffer) -> Product.SubscriptionOffer? {
        promotionalStoreOffer(for: product, promotionalOfferID: promotionalOffer.offerID)
    }

    private func promotionalStoreOffer(for product: Product, promotionalOfferID: String) -> Product.SubscriptionOffer? {
        return product.subscription?.promotionalOffers.first(where: { $0.id == promotionalOfferID })
    }
}

// MARK: - Promotional Offer Policy

/// 促销优惠展示策略：未配置签名者时一律不展示 win-back/retention，
/// 因为促销购买需要服务端 JWS 签名，无法签名时只能 fail closed。
enum PromotionalOfferPolicy {
    static func canSurfaceOffer(hasSigner: Bool, status: UserSubscriptionStatus) -> Bool {
        guard hasSigner else { return false }
        return status == .expiredSubscriber || status == .cancelledSubscriber || status == .activeSubscriber
    }
}

// MARK: - Store Errors

/// 稳定的错误 case，不含 `LocalizedError` 与面向宿主的本地化文案。
/// 宿主应用负责把 case 映射为面向用户的本地化展示文本。
public enum StoreError: Error {
    case failedVerification
    case productNotFound
    case userCancelled
    case pending
    case invalidOfferCode
    case offerNotAvailable
    case subscriptionExpired
    case familySharingNotSupported
    case networkError
    case unknown
}

// MARK: - Subscription Group Status
public enum RenewalState: Equatable { case subscribed, expired, inBillingRetryPeriod, inGracePeriod, revoked }

public enum ProAccessState: Equatable {
    case none
    case lifetime
    case subscription(RenewalState)
    case offlineProtected
}

public extension ProAccessState {
    var grantsAccess: Bool {
        switch self {
        case .none:
            return false
        case .lifetime, .offlineProtected:
            return true
        case .subscription(let state):
            switch state {
            case .subscribed, .inGracePeriod, .inBillingRetryPeriod:
                return true
            case .expired, .revoked:
                return false
            }
        }
    }
}
