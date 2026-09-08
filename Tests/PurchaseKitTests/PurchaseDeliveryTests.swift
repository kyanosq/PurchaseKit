import XCTest
import StoreKit
import Observation
@testable import PurchaseKit

// Uses the production manager/cache. StoreKit-signed transaction mapping remains covered by integration tests.
extension StoreKitManagerRestorePurchasesTests {
    @MainActor
    func testCancelledSilentRefreshPreservesLifetimeAndValidationDate() async throws {
        let suite = "delivery." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = StoreKitConfiguration(namespace: suite, storeKitInitDelay: 3600)
        let cache = PurchaseCache(userDefaults: defaults, config: config)
        let product = try PurchaseCatalog.stub.productID(for: LifetimePurchase.lifetime)
        let validation = Date(timeIntervalSinceNow: -60)
        cache.setLastValidPurchases([product])
        cache.setLifetimeEntitlement(true)
        cache.setLastValidationTime(validation)
        let storedValidation = cache.getLastValidationTime()
        let service = SuspendedEntitlementsService()
        let manager = StoreKitManager(catalog: .stub, config: config, purchaseCache: cache, storeKitService: service)
        let refresh = Task { await manager.restoreEntitlementsSilently() }
        await fulfillment(of: [service.started], timeout: 5)
        refresh.cancel()
        await refresh.value
        XCTAssertEqual(manager.purchasedProductIDs, [product])
        XCTAssertEqual(cache.getLastValidPurchases(), [product])
        XCTAssertEqual(cache.getLastValidationTime(), storedValidation)
        XCTAssertTrue(manager.canAccessProFeatures())
    }
}

private final class SuspendedEntitlementsService: StoreKitServiceProtocol, @unchecked Sendable {
    let started = XCTestExpectation(description: "entitlement stream started")
    func fetchProducts(for identifiers: Set<String>) async throws -> [Product] { [] }
    func purchase(_ product: Product, options: Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult { throw StoreError.unknown }
    func currentEntitlements() -> CurrentEntitlementsStream {
        started.fulfill()
        return AsyncStream { _ in }
    }
    func transactionUpdates() -> TransactionUpdatesStream { AsyncStream { $0.finish() } }
    func sync() async throws {}
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result { case .verified(let value): return value; case .unverified: throw StoreError.failedVerification }
    }
}
