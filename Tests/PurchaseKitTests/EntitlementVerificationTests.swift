import XCTest
import StoreKit
import Observation
@testable import PurchaseKit

@MainActor
final class EntitlementVerificationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var cache: PurchaseCache!
    private var manager: StoreKitManager!
    private let lifetime = "stub.lifetime"
    private let monthly = "stub.month"

    override func setUp() async throws {
        suite = "delivery." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        let config = StoreKitConfiguration(namespace: suite, storeKitInitDelay: 3600)
        cache = PurchaseCache(userDefaults: defaults, config: config)
        manager = StoreKitManager(catalog: .stub, config: config, purchaseCache: cache)
    }

    override func tearDown() async throws {
        manager = nil
        defaults.removePersistentDomain(forName: suite)
    }

    private func scan(_ results: [Result<EntitlementTransaction, Error>]) async throws {
        try await manager.refreshEntitlements(from: AsyncStream { continuation in
            results.forEach { continuation.yield($0) }
            continuation.finish()
        })
    }

    func testLifetimeDeliveryPersistsAndPublishesBeforeFinishWithoutRescan() async throws {
        var finished = false
        try await manager.deliverTransaction(.success(.init(productID: lifetime, productType: .nonConsumable))) {
            XCTAssertTrue(self.manager.canAccessProFeatures())
            XCTAssertEqual(self.manager.purchasedProductIDs, [self.lifetime])
            XCTAssertEqual(self.cache.getLastValidPurchases(), [self.lifetime])
            XCTAssertTrue(self.cache.hasLifetimeEntitlement())
            finished = true
        }
        XCTAssertTrue(finished)
    }

    func testSubscriptionDeliveryWorksBeforeProductsLoad() async throws {
        try await manager.deliverTransaction(.success(.init(productID: monthly, productType: .autoRenewable, expirationDate: .distantFuture))) {
            XCTAssertTrue(self.manager.canAccessProFeatures())
            XCTAssertTrue(self.cache.getSubscriptionHistory().contains(self.monthly))
        }
    }

    func testUnverifiedTransactionNeverGrantsOrFinishes() async {
        do {
            do {
                try await manager.deliverTransaction(.failure(StoreError.failedVerification)) {
                    XCTFail("Unverified transaction must remain unfinished")
                }
                XCTFail("Verification failure must reach the caller")
            } catch StoreError.failedVerification {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertFalse(manager.canAccessProFeatures())
        }
    }

    func testUnknownProductNeverGrantsOrFinishes() async {
        do {
            try await manager.deliverTransaction(.success(.init(productID: "other.app.lifetime", productType: .nonConsumable))) { XCTFail("Unknown product") }
            XCTFail("Expected productNotFound")
        } catch StoreError.productNotFound {} catch { XCTFail("\(error)") }
        XCTAssertFalse(manager.canAccessProFeatures())
    }

    func testPartialScanKeepsPriorRightsAndAcceptsVerifiedNeighboursWithoutRenewingCache() async throws {
        try await scan([.success(.init(productID: lifetime, productType: .nonConsumable))])
        let validated = cache.getLastValidationTime()
        do {
            try await scan([
                .failure(StoreError.failedVerification),
                .success(.init(productID: monthly, productType: .autoRenewable, expirationDate: .distantFuture))
            ])
            XCTFail("Partial verification must be reported")
        } catch StoreError.failedVerification {}
        XCTAssertEqual(manager.purchasedProductIDs, [lifetime, monthly])
        XCTAssertEqual(cache.getLastValidationTime(), validated)
        XCTAssertTrue(manager.canAccessProFeatures())
    }

    func testCompleteEmptySnapshotClearsLifetimeButRetainsSubscriptionHistory() async throws {
        try await scan([
            .success(.init(productID: lifetime, productType: .nonConsumable)),
            .success(.init(productID: monthly, productType: .autoRenewable))
        ])
        try await scan([])
        XCTAssertFalse(manager.canAccessProFeatures())
        XCTAssertFalse(cache.hasLifetimeEntitlement())
        XCTAssertTrue(manager.purchasedProductIDs.isEmpty)
        XCTAssertEqual(manager.userStatus, .expiredSubscriber)
    }

    func testVerifiedRevocationWinsEvenInPartialScan() async throws {
        try await scan([.success(.init(productID: lifetime, productType: .nonConsumable))])
        do {
            try await scan([
                .success(.init(productID: lifetime, productType: .nonConsumable, revocationDate: Date())),
                .failure(StoreError.failedVerification)
            ])
            XCTFail("Partial verification must be reported")
        } catch StoreError.failedVerification {}
        XCTAssertFalse(manager.canAccessProFeatures())
        XCTAssertFalse(cache.hasLifetimeEntitlement())
    }

    func testOldScanCannotOverwriteNewPurchase() async throws {
        let (stream, continuation) = AsyncStream<Result<EntitlementTransaction, Error>>.makeStream()
        let started = expectation(description: "scan started")
        let scan = Task {
            try await manager.refreshEntitlements(from: stream.map { result in
                started.fulfill()
                return result
            })
        }
        continuation.yield(.success(.init(productID: "ignored", productType: .consumable)))
        await fulfillment(of: [started], timeout: 5)
        try await manager.deliverTransaction(.success(.init(productID: lifetime, productType: .nonConsumable))) {}
        continuation.finish()
        do { try await scan.value; XCTFail("Superseded scan must be discarded") }
        catch is CancellationError {}
        XCTAssertTrue(manager.canAccessProFeatures())
        XCTAssertEqual(manager.purchasedProductIDs, [lifetime])
    }

    func testClearCacheInvalidatesSuspendedScan() async throws {
        let (stream, continuation) = AsyncStream<Result<EntitlementTransaction, Error>>.makeStream()
        let started = expectation(description: "scan started")
        let scan = Task {
            try await manager.refreshEntitlements(from: stream.map { result in
                started.fulfill()
                return result
            })
        }
        continuation.yield(.success(.init(productID: lifetime, productType: .nonConsumable)))
        await fulfillment(of: [started], timeout: 5)
        manager.clearOfflineCache()
        continuation.finish()
        do { try await scan.value; XCTFail("Reset must invalidate scan") } catch is CancellationError {}
        XCTAssertFalse(manager.canAccessProFeatures())
    }

    func testRevocationPublishesDenialBeforeFinish() async throws {
        try await scan([.success(.init(productID: monthly, productType: .autoRenewable))])
        try await manager.deliverTransaction(.success(.init(productID: monthly, productType: .autoRenewable, revocationDate: Date()))) {
            XCTAssertFalse(self.manager.canAccessProFeatures())
            XCTAssertTrue(self.cache.getLastValidPurchases().isEmpty)
        }
    }

    func testRevokedOldPlanDoesNotEraseAnotherVerifiedSubscription() async throws {
        try await scan([
            .success(.init(productID: "stub.year", productType: .autoRenewable, expirationDate: .distantFuture)),
            .success(.init(productID: monthly, productType: .autoRenewable, revocationDate: Date()))
        ])
        XCTAssertEqual(manager.purchasedProductIDs, ["stub.year"])
        XCTAssertTrue(manager.canAccessProFeatures())
    }

    func testCacheWriteFailureLeavesPurchaseUnfinishedAndRevocationDenied() async throws {
        let failingDefaults = DroppingWritesDefaults(suiteName: suite)!
        let config = StoreKitConfiguration(namespace: suite, storeKitInitDelay: 3600)
        let failingCache = PurchaseCache(userDefaults: failingDefaults, config: config)
        let store = StoreKitManager(catalog: .stub, config: config, purchaseCache: failingCache)
        failingDefaults.dropWrites = true
        do {
            try await store.deliverTransaction(.success(.init(productID: lifetime, productType: .nonConsumable))) {
                XCTFail("An unpersisted purchase must not be finished")
            }
            XCTFail("Persistence failure must reach caller")
        } catch {}
        failingDefaults.dropWrites = false
        try await store.deliverTransaction(.success(.init(productID: lifetime, productType: .nonConsumable))) {}
        failingDefaults.dropWrites = true
        do {
            try await store.deliverTransaction(.success(.init(productID: lifetime, productType: .nonConsumable, revocationDate: Date()))) {
                XCTFail("A failed revocation write must remain retryable")
            }
            XCTFail("Expected persistence error")
        } catch {}
        XCTAssertFalse(store.canAccessProFeatures(), "A stale lifetime flag must not override a verified refund")
        XCTAssertTrue(failingCache.hasLifetimeEntitlement(), "The test must actually simulate a stale persistent flag")
    }

    func testAccessObservationSeesCacheBackedLifetimeChanges() async throws {
        let changed = expectation(description: "access changes")
        withObservationTracking { _ = manager.canAccessProFeatures() } onChange: { changed.fulfill() }
        try await manager.deliverTransaction(.success(.init(productID: lifetime, productType: .nonConsumable))) {}
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertTrue(manager.canAccessProFeatures())
    }
}

private final class DroppingWritesDefaults: UserDefaults, @unchecked Sendable {
    var dropWrites = false
    override func set(_ value: Any?, forKey key: String) {
        if !dropWrites { super.set(value, forKey: key) }
    }
}
