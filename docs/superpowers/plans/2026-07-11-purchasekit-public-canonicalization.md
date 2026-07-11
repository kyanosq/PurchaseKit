# PurchaseKit Public Canonicalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert `$REPO` into the single, independently installable, public-ready PurchaseKit upstream while selectively incorporating proven fixes from the Dit and MarkIt forks.

**Architecture:** Keep one public `PurchaseKit` product and target. Merge `UserDefaultsProtocol` into that target, namespace and migrate persistence, isolate entitlement decisions in a pure resolver, and keep StoreKit interaction behind `StoreKitServiceProtocol`. The library stays UI-neutral and iOS 17+; consumer-repository migrations follow in a separate plan after the library reaches a verified release candidate.

**Tech Stack:** Swift 5.9, Swift Package Manager, StoreKit 2, Observation, XCTest, StoreKitTest, GitHub Actions, Xcode iOS Simulator.

## Global Constraints

- Preserve repository, package, product, target, and import name `PurchaseKit`.
- Use the MIT license and Chinese Git commit messages.
- Support iOS 17+ only in the first public release.
- Add no runtime third-party dependencies.
- Ship no paywall UI, analytics stubs, application marketing copy, App Store credentials, or server verification code.
- Treat the canonical checkout as the only upstream; fork code is evidence, not an overwrite source.
- Never let `.revoked` regain access through offline cache.
- Never silently charge full price when a promotional offer cannot be signed.
- Run a visible red-green cycle for every behavior change.

Before running any command block, initialize the repository variable once:

~~~bash
export REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"
~~~

---

### Task 1: Record the imported source baseline

**Files:**
- Add existing: `.gitignore`
- Add existing: `Package.swift`
- Add existing: `STOREKIT_TESTING_GUIDE.md`
- Add existing: `Sources/PurchaseKit/*.swift`
- Add existing: `Tests/PurchaseKitTests/**`

**Interfaces:**
- Consumes: approved design commit `f34fd3b`.
- Produces: a reviewable pre-fix baseline commit.

- [ ] **Step 1: Verify ignored and sensitive files**

~~~bash
cd "$REPO"
git check-ignore .build .swiftpm .DS_Store
rg -n --hidden -S '(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|/Users/)' Sources Tests Package.swift || true
~~~

Expected: generated files are ignored and production sources contain no credential or absolute-path match.

- [ ] **Step 2: Commit the unchanged implementation**

~~~bash
git add .gitignore Package.swift STOREKIT_TESTING_GUIDE.md Sources Tests
git diff --cached --check
git commit -m '导入 PurchaseKit 现有实现基线'
~~~

Expected: one baseline commit; no generated file is tracked.

---

### Task 2: Make the package independently resolvable

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PurchaseKit/UserDefaultsProtocol.swift`
- Modify: `Sources/PurchaseKit/PurchaseCache.swift`

**Interfaces:**
- Consumes: `UserDefaultsProtocol` from the former adjacent AppSupportKit.
- Produces: a self-contained `PurchaseKit` product with no local path dependency.

- [ ] **Step 1: Prove the isolated checkout currently fails**

~~~bash
rm -rf /tmp/PurchaseKit-Isolated-Red
mkdir -p /tmp/PurchaseKit-Isolated-Red
git archive HEAD | tar -x -C /tmp/PurchaseKit-Isolated-Red
cd /tmp/PurchaseKit-Isolated-Red
swift package dump-package
~~~

Expected: FAIL because `../AppSupportKit` is absent.

- [ ] **Step 2: Merge the protocol into PurchaseKit**

Create `Sources/PurchaseKit/UserDefaultsProtocol.swift`:

~~~swift
import Foundation
import os

public protocol UserDefaultsProtocol {
    func set(_ value: Any?, forKey defaultName: String)
    func object(forKey defaultName: String) -> Any?
    func bool(forKey defaultName: String) -> Bool
    func integer(forKey defaultName: String) -> Int
    func double(forKey defaultName: String) -> Double
    func string(forKey defaultName: String) -> String?
    func stringArray(forKey defaultName: String) -> [String]?
    func data(forKey defaultName: String) -> Data?
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: UserDefaultsProtocol {}

public extension UserDefaultsProtocol {
    func setCodable<T: Codable>(_ value: T?, forKey key: String) {
        guard let value else {
            removeObject(forKey: key)
            return
        }
        do {
            set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Logger(subsystem: "PurchaseKit", category: "Persistence")
                .error("Failed to encode cached value for key \(key, privacy: .private)")
        }
    }

    func codable<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Logger(subsystem: "PurchaseKit", category: "Persistence")
                .warning("Failed to decode cached value for key \(key, privacy: .private)")
            return nil
        }
    }
}
~~~

Remove `import AppSupportKit` from `PurchaseCache.swift`. Do not carry forward the obsolete `synchronize()` requirement.

- [ ] **Step 3: Replace the package topology**

~~~swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PurchaseKit",
    platforms: [.iOS(.v17)],
    products: [.library(name: "PurchaseKit", targets: ["PurchaseKit"])],
    targets: [
        .target(name: "PurchaseKit", path: "Sources/PurchaseKit"),
        .testTarget(
            name: "PurchaseKitTests",
            dependencies: ["PurchaseKit"],
            path: "Tests/PurchaseKitTests",
            resources: [.copy("Resources/PurchaseKitTest.storekit")]
        )
    ]
)
~~~

- [ ] **Step 4: Verify a standalone copy resolves and builds**

~~~bash
rm -rf /tmp/PurchaseKit-Isolated-Green
mkdir -p /tmp/PurchaseKit-Isolated-Green
rsync -a --exclude .git --exclude .build --exclude .swiftpm ./ /tmp/PurchaseKit-Isolated-Green/
cd /tmp/PurchaseKit-Isolated-Green
swift package dump-package
xcodebuild -scheme PurchaseKit -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PurchaseKit-Isolated-DD CODE_SIGNING_ALLOWED=NO build -quiet
~~~

Expected: both commands exit 0 without reading the former AppSupportKit directory.

- [ ] **Step 5: Commit**

~~~bash
git add Package.swift Sources/PurchaseKit/UserDefaultsProtocol.swift Sources/PurchaseKit/PurchaseCache.swift
git commit -m '合并 AppSupportKit 并移除本地路径依赖'
~~~

---

### Task 3: Publish configuration and namespace persistence

**Files:**
- Modify: `Sources/PurchaseKit/StoreKitConfiguration.swift`
- Modify: `Sources/PurchaseKit/PurchaseCache.swift`
- Create: `Tests/PurchaseKitTests/PublicAPITests.swift`
- Modify: `Tests/PurchaseKitTests/StoreKitConfigurationTests.swift`
- Modify: `Tests/PurchaseKitTests/PurchaseCacheTests.swift`
- Modify: `Tests/PurchaseKitTests/Helpers/StoreKitTestHelper.swift`
- Modify: `Tests/PurchaseKitTests/StoreKitManagerRestorePurchasesTests.swift`

**Interfaces:**
- Produces: `public init(namespace:...)`, namespaced keys, and one-time legacy-key migration.

- [ ] **Step 1: Write failing public API tests**

~~~swift
import XCTest
import PurchaseKit

final class PublicAPITests: XCTestCase {
    func testConfigurationCanBeCreatedWithoutTestableImport() {
        let config = StoreKitConfiguration(namespace: "com.example.reader.PurchaseKit")
        XCTAssertEqual(
            config.lastValidationKey,
            "com.example.reader.PurchaseKit.lastSuccessfulValidation"
        )
        XCTAssertEqual(
            config.lastValidPurchasesKey,
            "com.example.reader.PurchaseKit.lastValidPurchases"
        )
    }
}
~~~

Add a cache test that stores a legacy `lastSuccessfulValidation` value, constructs a cache using `com.example.reader.PurchaseKit`, and expects the value at the namespaced destination. Add a second assertion that an existing destination is never overwritten.

Add two serialization tests: one stores `Date()` directly and one stores a positive epoch `Double`; both must round-trip through `getLastValidationTime()`.

- [ ] **Step 2: Verify red**

~~~bash
xcodebuild -scheme PurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PurchaseKit-T3-Red CODE_SIGNING_ALLOWED=NO test -only-testing:PurchaseKitTests/PublicAPITests -only-testing:PurchaseKitTests/PurchaseCacheTests
~~~

Expected: FAIL because the public namespace initializer and migration are absent.

- [ ] **Step 3: Add the public initializer**

~~~swift
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
    precondition(!namespace.isEmpty)
    self.maxOfflineGracePeriod = maxOfflineGracePeriod
    self.lastValidationKey = namespace + ".lastSuccessfulValidation"
    self.lastValidPurchasesKey = namespace + ".lastValidPurchases"
    self.offlineGracePeriodKey = namespace + ".offlineGracePeriod"
    self.cachedUserStatusKey = namespace + ".cachedUserStatus"
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
~~~

Build `.default`, `.debug`, and `.staging` through this initializer using `Bundle.main.bundleIdentifier ?? "PurchaseKit"` and deterministic environment suffixes.

Replace every existing memberwise initializer call with the public namespace initializer. Test code uses a unique namespace such as `"test." + UUID().uuidString` and supplies only the interval overrides needed by that test; key assertions derive expected values from the same namespace.

- [ ] **Step 4: Implement one-time migration**

On cache initialization, map these legacy keys to their configuration destinations:

~~~swift
private static let legacyKeyPaths: [(legacy: String, destination: KeyPath<StoreKitConfiguration, String>)] = [
    ("lastSuccessfulValidation", \.lastValidationKey),
    ("lastValidPurchases", \.lastValidPurchasesKey),
    ("offlineGracePeriod", \.offlineGracePeriodKey),
    ("cachedUserStatus", \.cachedUserStatusKey),
    ("lastLoginRejection", \.lastLoginRejectionKey),
    ("lastForegroundCheck", \.lastForegroundCheckKey)
]
~~~

Copy only when the destination object is nil. Remove the old key only after the copied object can be read back. Read cached dates through `object(forKey:)` and accept either representation:

~~~swift
private static func storedDate(_ raw: Any?) -> Date? {
    if let date = raw as? Date { return date }
    guard let number = raw as? NSNumber, number.doubleValue > 0 else { return nil }
    return Date(timeIntervalSince1970: number.doubleValue)
}
~~~

- [ ] **Step 5: Verify green and commit**

~~~bash
xcodebuild -scheme PurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PurchaseKit-T3-Green CODE_SIGNING_ALLOWED=NO test -only-testing:PurchaseKitTests/PublicAPITests -only-testing:PurchaseKitTests/StoreKitConfigurationTests -only-testing:PurchaseKitTests/PurchaseCacheTests
git add Sources/PurchaseKit/StoreKitConfiguration.swift Sources/PurchaseKit/PurchaseCache.swift Tests/PurchaseKitTests/PublicAPITests.swift Tests/PurchaseKitTests/StoreKitConfigurationTests.swift Tests/PurchaseKitTests/PurchaseCacheTests.swift Tests/PurchaseKitTests/Helpers/StoreKitTestHelper.swift Tests/PurchaseKitTests/StoreKitManagerRestorePurchasesTests.swift
git commit -m '开放配置接口并迁移命名空间缓存'
~~~

Expected: selected tests pass with 0 failures.

---

### Task 4: Import pricing fixes through real regression tests

**Files:**
- Modify: `Sources/PurchaseKit/PricingFormatter.swift`
- Modify: `Sources/PurchaseKit/StoreKitManager.swift`
- Create: `Tests/PurchaseKitTests/PricingFormatterTests.swift`

**Interfaces:**
- Produces: guarded yearly percentage/amount helpers and Decimal monthly-equivalent formatting.

- [ ] **Step 1: Write failing regression tests**

~~~swift
import XCTest
@testable import PurchaseKit

final class PricingFormatterTests: XCTestCase {
    private let formatter = PricingFormatter(locale: Locale(identifier: "en_US"))

    func testDiscountPercentageRejectsZeroBaseline() {
        XCTAssertEqual(formatter.formatDiscountPercentage(0, discountedPrice: 0), "")
    }

    func testYearlySavingsClampsNegativeResult() {
        XCTAssertEqual(
            formatter.yearlySavingsPercentage(monthlyPrice: 4.99, yearlyPrice: 79.99),
            0,
            accuracy: 0.0001
        )
    }

    func testYearlySavingsRejectsZeroMonthlyBaseline() {
        XCTAssertNil(formatter.yearlySavingsPercentage(monthlyPrice: 0, yearlyPrice: 0))
    }

    func testLifetimeComparisonSuppressesFalseBargain() {
        let result = formatter.calculateLifetimeSavings(lifetimePrice: 199, yearlyPrice: 29)
        XCTAssertEqual(result.savings, 0)
        XCTAssertEqual(result.equivalentYears, 0)
        XCTAssertTrue(result.comparisonText.isEmpty)
    }
}
~~~

- [ ] **Step 2: Verify red**

~~~bash
xcodebuild -scheme PurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PurchaseKit-T4-Red CODE_SIGNING_ALLOWED=NO test -only-testing:PurchaseKitTests/PricingFormatterTests
~~~

Expected: missing helper and current output failures.

- [ ] **Step 3: Implement guarded helpers**

~~~swift
public func yearlySavingsPercentage(monthlyPrice: Double, yearlyPrice: Double) -> Double? {
    let baseline = monthlyPrice * 12
    guard baseline.isFinite, yearlyPrice.isFinite, baseline > 0 else { return nil }
    return max(0, baseline - yearlyPrice) / baseline * 100
}

public func yearlySavingsAmount(monthlyPrice: Double, yearlyPrice: Double) -> Double? {
    let baseline = monthlyPrice * 12
    guard baseline.isFinite, yearlyPrice.isFinite else { return nil }
    return max(0, baseline - yearlyPrice)
}
~~~

Guard `formatDiscountPercentage` against non-positive/non-finite baselines, use `locale.currencySymbol` in fallbacks, and suppress lifetime comparison output when savings is zero. Delegate manager yearly-savings APIs to these helpers. Compute the yearly monthly equivalent from `Product.price / Decimal(12)` and format with `product.priceFormatStyle`.

- [ ] **Step 4: Verify green and commit**

~~~bash
xcodebuild -scheme PurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PurchaseKit-T4-Green CODE_SIGNING_ALLOWED=NO test -only-testing:PurchaseKitTests/PricingFormatterTests
git add Sources/PurchaseKit/PricingFormatter.swift Sources/PurchaseKit/StoreKitManager.swift Tests/PurchaseKitTests/PricingFormatterTests.swift
git commit -m '修复价格除零与误导性节省计算'
~~~

---

### Task 5: Replace application copy with structured offer data

**Files:**
- Modify: `Sources/PurchaseKit/InAppPurchaseModels.swift`
- Modify: `Sources/PurchaseKit/StoreKitManager.swift`
- Modify: `Tests/PurchaseKitTests/InAppPurchaseModelsTests.swift`
- Modify: `Tests/PurchaseKitTests/PromotionalOfferTests.swift`

**Interfaces:**
- Produces: `OfferPeriod` and UI-neutral introductory/promotional offer values.

- [ ] **Step 1: Write failing period tests**

~~~swift
func testWeeklyTrialPreservesItsUnit() {
    let offer = IntroductoryOffer.freeTrial(period: OfferPeriod(value: 1, unit: .week))
    guard case .freeTrial(let period) = offer else {
        return XCTFail("Expected free trial")
    }
    XCTAssertEqual(period, OfferPeriod(value: 1, unit: .week))
}

func testPromotionalOfferCarriesDataWithoutCopy() {
    let offer = PromotionalOffer.winBack(
        id: "winback-123",
        discountPercentage: 20,
        period: OfferPeriod(value: 3, unit: .month)
    )
    XCTAssertEqual(offer.offerID, "winback-123")
}
~~~

Replace tests for Chinese titles, badges, descriptions, and MarkIt’s “智能调度” copy.

- [ ] **Step 2: Verify red**

~~~bash
xcodebuild -scheme PurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PurchaseKit-T5-Red CODE_SIGNING_ALLOWED=NO test -only-testing:PurchaseKitTests/InAppPurchaseModelsTests -only-testing:PurchaseKitTests/PromotionalOfferTests
~~~

Expected: compile FAIL because `OfferPeriod` and the new cases are absent.

- [ ] **Step 3: Implement structured models**

~~~swift
public struct OfferPeriod: Sendable, Equatable {
    public enum Unit: Sendable, Equatable { case day, week, month, year }
    public let value: Int
    public let unit: Unit

    public init(value: Int, unit: Unit) {
        precondition(value > 0)
        self.value = value
        self.unit = unit
    }
}

public enum IntroductoryOffer: Sendable, Equatable {
    case freeTrial(period: OfferPeriod)
    case payAsYouGo(firstPrice: String, period: OfferPeriod)
    case payUpFront(discountedPrice: String, period: OfferPeriod)
}

public enum PromotionalOffer: Sendable, Equatable {
    case winBack(id: String, discountPercentage: Int, period: OfferPeriod)
    case retention(id: String, discountPercentage: Int, period: OfferPeriod)
    case upgrade(id: String, discountPercentage: Int)
}
~~~

Add a private StoreKit-period mapper. Remove application-facing `displayName`, `description`, `title`, `subtitle`, `badgeText`, `message`, and `OfferCode.title`. Retain IDs, raw prices, discount data, periods, eligibility, and access states.

Give `OfferCode`, `PurchaseJourney`, `PricingComparison`, and other externally constructed value types explicit public initializers. Remove `LocalizedError` from `StoreError`; keep stable error cases and let host applications map them to localized text.

- [ ] **Step 4: Verify green and commit**

~~~bash
xcodebuild -scheme PurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PurchaseKit-T5-Green CODE_SIGNING_ALLOWED=NO test -only-testing:PurchaseKitTests/InAppPurchaseModelsTests -only-testing:PurchaseKitTests/PromotionalOfferTests
git add Sources/PurchaseKit/InAppPurchaseModels.swift Sources/PurchaseKit/StoreKitManager.swift Tests/PurchaseKitTests/InAppPurchaseModelsTests.swift Tests/PurchaseKitTests/PromotionalOfferTests.swift
git commit -m '将优惠模型收敛为结构化公共数据'
~~~

---

### Task 6: Separate current entitlement from purchase history

**Files:**
- Create: `Sources/PurchaseKit/EntitlementStateResolver.swift`
- Modify: `Sources/PurchaseKit/PurchaseCache.swift`
- Modify: `Sources/PurchaseKit/StoreKitManager.swift`
- Create: `Tests/PurchaseKitTests/EntitlementStateResolverTests.swift`
- Modify: `Tests/PurchaseKitTests/PurchaseCacheTests.swift`
- Modify: `Tests/PurchaseKitTests/StoreKitManagerRestorePurchasesTests.swift`

**Interfaces:**
- Produces: pure `EntitlementStateResolver.userStatus(from:)` and `accessState(from:)`.

- [ ] **Step 1: Write failing state tests**

~~~swift
final class EntitlementStateResolverTests: XCTestCase {
    func testLapsedKnownSubscriberIsNotNewUser() {
        let facts = EntitlementFacts(
            hasActiveSubscription: false,
            hasLifetime: false,
            isTrial: false,
            willAutoRenew: false,
            hadSubscriptionHistory: true,
            renewalState: .expired,
            hasOfflineEvidence: false
        )
        XCTAssertEqual(EntitlementStateResolver.userStatus(from: facts), .expiredSubscriber)
    }

    func testCancelledActiveSubscriberRetainsAccess() {
        let facts = EntitlementFacts(
            hasActiveSubscription: true,
            hasLifetime: false,
            isTrial: false,
            willAutoRenew: false,
            hadSubscriptionHistory: true,
            renewalState: .subscribed,
            hasOfflineEvidence: false
        )
        XCTAssertEqual(EntitlementStateResolver.userStatus(from: facts), .cancelledSubscriber)
        XCTAssertTrue(EntitlementStateResolver.accessState(from: facts).grantsAccess)
    }

    func testRevokedAlwaysDeniesOfflineAccess() {
        let facts = EntitlementFacts(
            hasActiveSubscription: false,
            hasLifetime: false,
            isTrial: false,
            willAutoRenew: false,
            hadSubscriptionHistory: true,
            renewalState: .revoked,
            hasOfflineEvidence: true
        )
        XCTAssertEqual(EntitlementStateResolver.accessState(from: facts), .subscription(.revoked))
        XCTAssertFalse(EntitlementStateResolver.accessState(from: facts).grantsAccess)
    }
}
~~~

- [ ] **Step 2: Verify red**

~~~bash
xcodebuild -scheme PurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PurchaseKit-T6-Red CODE_SIGNING_ALLOWED=NO test -only-testing:PurchaseKitTests/EntitlementStateResolverTests
~~~

Expected: compile FAIL because facts and resolver are absent.

- [ ] **Step 3: Implement the reducer**

~~~swift
struct EntitlementFacts: Equatable {
    let hasActiveSubscription: Bool
    let hasLifetime: Bool
    let isTrial: Bool
    let willAutoRenew: Bool
    let hadSubscriptionHistory: Bool
    let renewalState: RenewalState
    let hasOfflineEvidence: Bool
}

enum EntitlementStateResolver {
    static func userStatus(from facts: EntitlementFacts) -> UserSubscriptionStatus {
        if facts.isTrial && facts.hasActiveSubscription { return .trialUser }
        if facts.hasActiveSubscription {
            return facts.willAutoRenew ? .activeSubscriber : .cancelledSubscriber
        }
        if facts.hasLifetime { return .activeSubscriber }
        return facts.hadSubscriptionHistory ? .expiredSubscriber : .newUser
    }

    static func accessState(from facts: EntitlementFacts) -> ProAccessState {
        if facts.hasLifetime { return .lifetime }
        if facts.renewalState == .revoked { return .subscription(.revoked) }
        if facts.hasActiveSubscription { return .subscription(facts.renewalState) }
        if facts.hasOfflineEvidence { return .offlineProtected }
        return .none
    }
}
~~~

Make `RenewalState` equatable. Cache subscription-history evidence separately from current IDs. Remove the early new-user return and stop erasing history when current entitlements become empty. Assign `activeTransaction` only when expiration is nil or future. Build `proAccessState()` through the resolver; a verified revocation clears matching cache before fallback.

When subscription status is available, verify its renewal info and feed `willAutoRenew` into the resolver. If renewal info cannot be verified, keep access based on the verified current transaction but do not classify the user as cancelled.

Persist a separate non-expiring-entitlement flag for lifetime purchases. It may suppress interactive `AppStore.sync()` at cold launch, but it must not suppress the non-interactive `Transaction.currentEntitlements` refresh or transaction-update listener that can observe refunds.

- [ ] **Step 4: Verify green and commit**

~~~bash
xcodebuild -scheme PurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PurchaseKit-T6-Green CODE_SIGNING_ALLOWED=NO test -only-testing:PurchaseKitTests/EntitlementStateResolverTests -only-testing:PurchaseKitTests/PurchaseCacheTests -only-testing:PurchaseKitTests/StoreKitManagerRestorePurchasesTests
git add Sources/PurchaseKit/EntitlementStateResolver.swift Sources/PurchaseKit/PurchaseCache.swift Sources/PurchaseKit/StoreKitManager.swift Tests/PurchaseKitTests/EntitlementStateResolverTests.swift Tests/PurchaseKitTests/PurchaseCacheTests.swift Tests/PurchaseKitTests/StoreKitManagerRestorePurchasesTests.swift
git commit -m '分离当前权益与历史订阅状态'
~~~

Expected: lapsed users remain historical customers, active cancelled users retain access, and revoked users do not.

---

### Task 7: Enforce promotional and cache-reset safety

**Files:**
- Modify: `Sources/PurchaseKit/StoreKitManager.swift`
- Modify: `Tests/PurchaseKitTests/PromotionalOfferTests.swift`
- Modify: `Tests/PurchaseKitTests/StoreKitManagerRestorePurchasesTests.swift`

**Interfaces:**
- Produces: no-signer promotional denial and synchronous cache/in-memory reset.

- [ ] **Step 1: Write failing tests**

~~~swift
func testPromotionalOfferRequiresSigner() {
    XCTAssertFalse(
        PromotionalOfferPolicy.canSurfaceOffer(
            hasSigner: false,
            status: .expiredSubscriber
        )
    )
    XCTAssertTrue(
        PromotionalOfferPolicy.canSurfaceOffer(
            hasSigner: true,
            status: .expiredSubscriber
        )
    )
}
~~~

Add a manager test that seeds cache and in-memory state, calls `clearOfflineCache()`, and immediately expects empty product IDs, `.newUser`, nil active transaction, and `.none` access.

Add lifecycle tests using weak references and controllable async streams: releasing the manager must cancel its transaction listener and pending refund task, and neither task may retain the manager.

- [ ] **Step 2: Verify red**

~~~bash
xcodebuild -scheme PurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PurchaseKit-T7-Red CODE_SIGNING_ALLOWED=NO test -only-testing:PurchaseKitTests/PromotionalOfferTests -only-testing:PurchaseKitTests/StoreKitManagerRestorePurchasesTests
~~~

- [ ] **Step 3: Implement policy and throwing options**

~~~swift
enum PromotionalOfferPolicy {
    static func canSurfaceOffer(
        hasSigner: Bool,
        status: UserSubscriptionStatus
    ) -> Bool {
        guard hasSigner else { return false }
        return status == .expiredSubscriber
            || status == .cancelledSubscriber
            || status == .activeSubscriber
    }
}
~~~

Use this policy for win-back and retention. Change `purchaseOptions` to `async throws`; if a promotional offer is explicitly requested and the signer, signature, or StoreKit offer is unavailable, throw `.offerNotAvailable` instead of returning an empty option set.

Because the manager is `@MainActor`, clear cache and all in-memory entitlement/offer fields directly inside `clearOfflineCache()`; do not spawn another task.

- [ ] **Step 4: Verify green and commit**

~~~bash
xcodebuild -scheme PurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PurchaseKit-T7-Green CODE_SIGNING_ALLOWED=NO test -only-testing:PurchaseKitTests/PromotionalOfferTests -only-testing:PurchaseKitTests/StoreKitManagerRestorePurchasesTests
git add Sources/PurchaseKit/StoreKitManager.swift Tests/PurchaseKitTests/PromotionalOfferTests.swift Tests/PurchaseKitTests/StoreKitManagerRestorePurchasesTests.swift
git commit -m '阻止未签名促销与残留缓存授权'
~~~

---

### Task 8: Repair StoreKit tests and unsafe public defaults

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/PurchaseKit/StoreKitManager.swift`
- Modify: `Sources/PurchaseKit/PurchaseCatalog.swift`
- Modify: `Tests/PurchaseKitTests/Helpers/StoreKitTestHelper.swift`
- Modify: `Tests/PurchaseKitTests/StoreKitManagerIntegrationTests.swift`
- Modify: `Tests/PurchaseKitTests/PublicAPITests.swift`
- Replace: `STOREKIT_TESTING_GUIDE.md`

**Interfaces:**
- Produces: fail-fast `SKTestSession`, explicit catalog construction, and no empty analytics/campaign APIs.

- [ ] **Step 1: Make integration setup fail fast**

~~~swift
func enableStoreKitTestSession(
    configFileName: String = "PurchaseKitTest"
) throws {
    let session = try SKTestSession(configurationFileNamed: configFileName)
    session.disableDialogs = true
    session.clearTransactions()
    self.session = session
}
~~~

Call it with `try` from integration setup. Before changing the resource entry, run one product-loading integration test and confirm it fails with `SKTestErrorDomain Code=4`.

- [ ] **Step 2: Put the StoreKit file at the resource root**

Ensure `Package.swift` contains:

~~~swift
resources: [.copy("Resources/PurchaseKitTest.storekit")]
~~~

Run:

~~~bash
xcodebuild -scheme PurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PurchaseKit-T8-Resource CODE_SIGNING_ALLOWED=NO test -only-testing:PurchaseKitTests/StoreKitManagerIntegrationTests/testLoadProducts_Success
~~~

Expected: the session opens and the selected test passes.

- [ ] **Step 3: Write the public-construction contract**

In `PublicAPITests`, construct:

~~~swift
@MainActor
func testManagerUsesExplicitCatalog() {
    let catalog = PurchaseCatalog(
        subscriptionIDs: [
            .monthly: "com.example.monthly",
            .yearly: "com.example.yearly"
        ],
        lifetimeIDs: [.lifetime: "com.example.lifetime"]
    )
    _ = StoreKitManager(catalog: catalog)
}
~~~

Add a source contract asserting `StoreKitManager.swift` does not contain the default `catalog: PurchaseCatalog = .stub` or the names `trackPurchaseEvent`, `trackOfferEligibilityCheck`, `triggerWinBackCampaign`, and `triggerRetentionCampaign`.

- [ ] **Step 4: Remove unsafe defaults and no-op APIs**

Use this initializer prefix:

~~~swift
public init(
    catalog: PurchaseCatalog,
    config: StoreKitConfiguration = .current,
    purchaseCache: PurchaseCacheProtocol? = nil,
    pricingFormatter: PricingFormatter? = nil,
    storeKitService: StoreKitServiceProtocol? = nil,
    promotionalOfferSigner: PromotionalOfferSigning? = nil
)
~~~

Move `.stub` to test helpers or compile it only under DEBUG. Delete empty analytics and campaign methods.

- [ ] **Step 5: Replace stale test documentation**

Rewrite `STOREKIT_TESTING_GUIDE.md` with exact unit/integration commands, fail-fast setup, simulator requirements, and known scope. Remove every claim of 100% coverage.

- [ ] **Step 6: Run full suite and commit**

~~~bash
xcodebuild -scheme PurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PurchaseKit-T8-Green CODE_SIGNING_ALLOWED=NO test
git add Package.swift STOREKIT_TESTING_GUIDE.md Sources/PurchaseKit/StoreKitManager.swift Sources/PurchaseKit/PurchaseCatalog.swift Tests/PurchaseKitTests
git commit -m '修复 StoreKit 测试与生产默认接口'
~~~

Expected: exit 0, 0 failures, and normal test-process termination.

---

### Task 9: Bootstrap public governance, license, and CI

**Files:**
- Create: `README.md`
- Create: `LICENSE`
- Create: `AGENTS.md`
- Create: `ARCH.md`
- Create: `TESTING.md`
- Create: `DELIVERY.md`
- Create: `.github/workflows/ci.yml`
- Create: `docs/feature-docs/entitlement-state.md`
- Modify: `.gitignore`

**Interfaces:**
- Produces: public entrypoint, rules sources, MIT license, CI, and release procedure.

- [ ] **Step 1: Write public entrypoint and license**

README identifies “PurchaseKit — StoreKit 2 purchases and entitlement management for iOS 17+”, documents explicit catalog construction, and links the architecture, testing, and delivery rule sources. Use the intended URL `https://github.com/kyanosq/PurchaseKit.git`.

Use standard MIT text with:

~~~text
Copyright (c) 2026 qiujsh
~~~

- [ ] **Step 2: Create the minimal governance set**

`ARCH.md` owns dependency, entitlement, cache, revocation, and signer rules. `TESTING.md` owns test layers/commands. `DELIVERY.md` owns SemVer, CI, tags, and rollback. Create `AGENTS.md`:

~~~markdown
# Agent Instructions

- Git Commit 信息使用中文。
- 架构与权益规则以 `ARCH.md` 为准。
- 测试命令与分层以 `TESTING.md` 为准。
- 发布流程以 `DELIVERY.md` 为准。
- 不提交 `.build/`、`.swiftpm/`、`.DS_Store`、凭据或绝对本机路径。
~~~

Document the current-entitlement/history distinction and access matrix in `docs/feature-docs/entitlement-state.md`.

- [ ] **Step 3: Add CI**

~~~yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Resolve manifest
        run: swift package dump-package > /dev/null
      - name: Build and test
        run: |
          set -o pipefail
          xcodebuild -scheme PurchaseKit \
            -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
            CODE_SIGNING_ALLOWED=NO test
      - name: Reject whitespace errors
        run: git diff --check
~~~

Verify the runner’s simulator name before retaining it; keep CI and TESTING commands identical.

- [ ] **Step 4: Validate and commit**

~~~bash
rg -n 'ARCH.md|TESTING.md|DELIVERY.md' README.md AGENTS.md
rg -n '/Users/|\.\./AppSupportKit|stub\.month|stub\.year|stub\.lifetime' README.md ARCH.md TESTING.md DELIVERY.md Sources Package.swift || true
git diff --check
git add README.md LICENSE AGENTS.md ARCH.md TESTING.md DELIVERY.md .github .gitignore docs/feature-docs
git commit -m '补齐 PurchaseKit 公开治理与持续集成'
~~~

Expected: no absolute paths, local package paths, or stub IDs in public docs/production sources.

---

### Task 10: Run the release-candidate gate

**Files:**
- Verify: every tracked file
- Create: `docs/superpowers/plans/2026-07-11-purchasekit-consumer-migration.md`

**Interfaces:**
- Produces: a verified library release candidate and a separate Dit/MarkIt migration plan; no `0.1.1` tag yet.

- [ ] **Step 1: Build a clean clone**

~~~bash
cd "$REPO"
rm -rf /tmp/PurchaseKit-RC
git clone --no-local . /tmp/PurchaseKit-RC
cd /tmp/PurchaseKit-RC
swift package dump-package > /dev/null
xcodebuild -scheme PurchaseKit -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PurchaseKit-RC-Build CODE_SIGNING_ALLOWED=NO build -quiet
~~~

Expected: the clone resolves and builds without the former adjacent package.

- [ ] **Step 2: Run complete tests from the clone**

~~~bash
cd /tmp/PurchaseKit-RC
xcodebuild -scheme PurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PurchaseKit-RC-Test CODE_SIGNING_ALLOWED=NO test
~~~

Expected: exit 0, 0 failures, and normal termination.

- [ ] **Step 3: Scan public artifacts**

~~~bash
cd "$REPO"
git ls-files | rg '(^|/)(\.DS_Store|\.build|\.swiftpm)(/|$)' && exit 1 || true
rg -n --hidden -S '(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|/Users/)' Sources Tests .github README.md LICENSE ARCH.md TESTING.md DELIVERY.md Package.swift .gitignore && exit 1 || true
git diff --check
git status --short --branch
~~~

Expected: no generated artifact, credential, or absolute-path match; clean `main`.

- [ ] **Step 4: Write and commit consumer migration plan**

The second plan migrates Dit first, then MarkIt, then remaining consumers. Each repository gets its own package-reference, application build, purchase/restore test, and Chinese commit gate before deleting its embedded `Packages/PurchaseKit`. Do not create `0.1.1` until at least one real consumer passes against this canonical checkout.

~~~bash
git add docs/superpowers/plans/2026-07-11-purchasekit-consumer-migration.md
git commit -m '规划 PurchaseKit 消费方唯一上游迁移'
git status --short --branch
~~~

Expected: clean worktree and a library ready for consumer validation, not yet tagged.
