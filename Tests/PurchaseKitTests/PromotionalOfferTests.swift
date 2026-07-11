import XCTest
@testable import PurchaseKit

final class PromotionalOfferTests: XCTestCase {

    // MARK: - 结构化促销数据（不含宿主文案）

    func testWinBackCarriesIDDiscountAndPeriod() {
        let offer = PromotionalOffer.winBack(
            id: "offer-123",
            discountPercentage: 20,
            period: OfferPeriod(value: 3, unit: .month)
        )
        XCTAssertEqual(offer.offerID, "offer-123")
        guard case .winBack(let id, let discountPercentage, let period) = offer else {
            return XCTFail("Expected winBack")
        }
        XCTAssertEqual(id, "offer-123")
        XCTAssertEqual(discountPercentage, 20)
        XCTAssertEqual(period, OfferPeriod(value: 3, unit: .month))
    }

    func testRetentionCarriesIDDiscountAndPeriod() {
        let offer = PromotionalOffer.retention(
            id: "ret-001",
            discountPercentage: 15,
            period: OfferPeriod(value: 6, unit: .month)
        )
        XCTAssertEqual(offer.offerID, "ret-001")
        guard case .retention(let id, let discountPercentage, let period) = offer else {
            return XCTFail("Expected retention")
        }
        XCTAssertEqual(id, "ret-001")
        XCTAssertEqual(discountPercentage, 15)
        XCTAssertEqual(period, OfferPeriod(value: 6, unit: .month))
    }

    func testUpgradeCarriesIDAndDiscount() {
        let offer = PromotionalOffer.upgrade(id: "up-9", discountPercentage: 10)
        XCTAssertEqual(offer.offerID, "up-9")
        guard case .upgrade(let id, let discountPercentage) = offer else {
            return XCTFail("Expected upgrade")
        }
        XCTAssertEqual(id, "up-9")
        XCTAssertEqual(discountPercentage, 10)
    }

    // MARK: - 促销安全策略（无签名者不得展示促销，Task 7）

    func testPromotionalOfferRequiresSigner() {
        XCTAssertFalse(
            PromotionalOfferPolicy.canSurfaceOffer(hasSigner: false, status: .expiredSubscriber)
        )
        XCTAssertTrue(
            PromotionalOfferPolicy.canSurfaceOffer(hasSigner: true, status: .expiredSubscriber)
        )
    }

    func testPromotionalOfferOnlySurfacesForSubscribersWithSigner() {
        // 新用户与试用用户即便有签名者也不展示 win-back/retention。
        XCTAssertFalse(PromotionalOfferPolicy.canSurfaceOffer(hasSigner: true, status: .newUser))
        XCTAssertFalse(PromotionalOfferPolicy.canSurfaceOffer(hasSigner: true, status: .trialUser))
        // 已过期/已取消/活跃订阅者在有签名者时可展示。
        XCTAssertTrue(PromotionalOfferPolicy.canSurfaceOffer(hasSigner: true, status: .cancelledSubscriber))
        XCTAssertTrue(PromotionalOfferPolicy.canSurfaceOffer(hasSigner: true, status: .activeSubscriber))
    }
}
