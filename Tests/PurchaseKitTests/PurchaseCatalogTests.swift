import XCTest
@testable import PurchaseKit

final class PurchaseCatalogTests: XCTestCase {
    private let catalog = PurchaseCatalog(
        subscriptionIDs: [.monthly: "sub.month", .yearly: "sub.year"],
        lifetimeIDs: [.lifetime: "life.full"]
    )

    func testAvailableSubscriptionsFiltersMissingProducts() throws {
        let available = try catalog.availableSubscriptions(in: Set(["sub.year"]))
        XCTAssertEqual(available, [.yearly])
    }

    func testAvailableLifetimePurchasesFiltersMissingProducts() throws {
        let available = try catalog.availableLifetimePurchases(in: [] as Set<String>)
        XCTAssertTrue(available.isEmpty)
    }

    func testAvailableSubscriptionsPreservesOrder() throws {
        let available = try catalog.availableSubscriptions(in: Set(["sub.year", "sub.month"]))
        XCTAssertEqual(available, [.monthly, .yearly])
    }

    func testAvailableSubscriptionsThrowsWhenMappingMissing() {
        let modified = PurchaseCatalog(
            subscriptionIDs: [.monthly: "sub.month"],
            lifetimeIDs: catalog.lifetimeIDs
        )
        XCTAssertThrowsError(try modified.availableSubscriptions(in: Set(["sub.year", "sub.month"]))) { error in
            XCTAssertEqual(error as? PurchaseCatalogError, .missingSubscriptionMapping(.yearly))
        }
    }

    func testAvailableLifetimePurchasesThrowsWhenMappingMissing() {
        let modified = PurchaseCatalog(
            subscriptionIDs: catalog.subscriptionIDs,
            lifetimeIDs: [:]
        )
        XCTAssertThrowsError(try modified.availableLifetimePurchases(in: Set(["life.full"]))) { error in
            XCTAssertEqual(error as? PurchaseCatalogError, .missingLifetimeMapping(.lifetime))
        }
    }

    func testProductIDThrowsWhenSubscriptionMissing() {
        let modified = PurchaseCatalog(
            subscriptionIDs: [.monthly: "sub.month"],
            lifetimeIDs: catalog.lifetimeIDs
        )
        XCTAssertThrowsError(try modified.productID(for: .yearly)) { error in
            XCTAssertEqual(error as? PurchaseCatalogError, .missingSubscriptionMapping(.yearly))
        }
    }

    func testProductIDThrowsWhenLifetimeMissing() {
        let modified = PurchaseCatalog(
            subscriptionIDs: catalog.subscriptionIDs,
            lifetimeIDs: [:]
        )
        XCTAssertThrowsError(try modified.productID(for: .lifetime)) { error in
            XCTAssertEqual(error as? PurchaseCatalogError, .missingLifetimeMapping(.lifetime))
        }
    }
    
    // MARK: - 新增测试
    
    func testAllProductIDs() throws {
        let allIDs = catalog.allProductIDs
        XCTAssertEqual(allIDs.count, 3)
        XCTAssertTrue(allIDs.contains("sub.month"))
        XCTAssertTrue(allIDs.contains("sub.year"))
        XCTAssertTrue(allIDs.contains("life.full"))
    }
    
    func testLifetimeProductIDs() {
        let lifetimeIDs = catalog.lifetimeProductIDs()
        XCTAssertEqual(lifetimeIDs.count, 1)
        XCTAssertTrue(lifetimeIDs.contains("life.full"))
    }
    
    func testSubscriptionTypeFromProductIDValid() {
        let monthly = SubscriptionType.from(productID: "sub.month", catalog: catalog)
        XCTAssertEqual(monthly, .monthly)
        
        let yearly = SubscriptionType.from(productID: "sub.year", catalog: catalog)
        XCTAssertEqual(yearly, .yearly)
    }
    
    func testSubscriptionTypeFromProductIDInvalid() {
        let unknown = SubscriptionType.from(productID: "unknown.id", catalog: catalog)
        XCTAssertNil(unknown)
    }
    
    func testLifetimePurchaseFromProductIDValid() {
        let lifetime = LifetimePurchase.from(productID: "life.full", catalog: catalog)
        XCTAssertEqual(lifetime, .lifetime)
    }
    
    func testLifetimePurchaseFromProductIDInvalid() {
        let unknown = LifetimePurchase.from(productID: "unknown.id", catalog: catalog)
        XCTAssertNil(unknown)
    }
    
    func testStubCatalog() throws {
        let stub = PurchaseCatalog.stub
        
        // 验证 stub 目录包含所有默认产品
        XCTAssertEqual(try stub.productID(for: .monthly), "stub.month")
        XCTAssertEqual(try stub.productID(for: .yearly), "stub.year")
        XCTAssertEqual(try stub.productID(for: .lifetime), "stub.lifetime")
        
        XCTAssertEqual(stub.allProductIDs.count, 3)
    }
    
    func testProductIDForSubscriptionSuccess() throws {
        let monthlyID = try catalog.productID(for: .monthly)
        XCTAssertEqual(monthlyID, "sub.month")
        
        let yearlyID = try catalog.productID(for: .yearly)
        XCTAssertEqual(yearlyID, "sub.year")
    }
    
    func testProductIDForLifetimeSuccess() throws {
        let lifetimeID = try catalog.productID(for: .lifetime)
        XCTAssertEqual(lifetimeID, "life.full")
    }
    
    func testAvailableSubscriptionsWithAllProducts() throws {
        let available = try catalog.availableSubscriptions(in: Set(["sub.month", "sub.year", "life.full"]))
        XCTAssertEqual(available.count, 2)
        XCTAssertTrue(available.contains(.monthly))
        XCTAssertTrue(available.contains(.yearly))
    }
    
    func testAvailableLifetimePurchasesWithAllProducts() throws {
        let available = try catalog.availableLifetimePurchases(in: Set(["sub.month", "sub.year", "life.full"]))
        XCTAssertEqual(available.count, 1)
        XCTAssertTrue(available.contains(.lifetime))
    }
}
