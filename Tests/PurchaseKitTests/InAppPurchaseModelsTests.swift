import XCTest
@testable import PurchaseKit

final class InAppPurchaseModelsTests: XCTestCase {

    // MARK: - OfferPeriod（结构化周期）

    func testOfferPeriodPreservesValueAndUnit() {
        let period = OfferPeriod(value: 3, unit: .month)
        XCTAssertEqual(period.value, 3)
        XCTAssertEqual(period.unit, .month)
    }

    func testOfferPeriodIsEquatableAcrossUnits() {
        XCTAssertEqual(OfferPeriod(value: 1, unit: .week), OfferPeriod(value: 1, unit: .week))
        XCTAssertNotEqual(OfferPeriod(value: 1, unit: .week), OfferPeriod(value: 1, unit: .month))
        XCTAssertNotEqual(OfferPeriod(value: 1, unit: .week), OfferPeriod(value: 2, unit: .week))
    }

    func testOfferPeriodExposesAllUnits() {
        let _: [OfferPeriod.Unit] = [.day, .week, .month, .year]
    }

    // MARK: - SubscriptionType / LifetimePurchase（不含营销文案）

    func testSubscriptionTypeCasesAreAvailable() {
        XCTAssertEqual(SubscriptionType.allCases, [.monthly, .yearly])
    }

    func testLifetimePurchaseCasesAreAvailable() {
        XCTAssertEqual(LifetimePurchase.allCases, [.lifetime])
    }

    // MARK: - IntroductoryOffer（保留周期与价格，不含标题/副标题/徽章）

    func testWeeklyTrialPreservesItsUnit() {
        let offer = IntroductoryOffer.freeTrial(period: OfferPeriod(value: 1, unit: .week))
        guard case .freeTrial(let period) = offer else {
            return XCTFail("Expected free trial")
        }
        XCTAssertEqual(period, OfferPeriod(value: 1, unit: .week))
    }

    func testPayAsYouGoRetainsFirstPriceAndPeriod() {
        let offer = IntroductoryOffer.payAsYouGo(
            firstPrice: "$0.99",
            period: OfferPeriod(value: 1, unit: .month)
        )
        guard case .payAsYouGo(let firstPrice, let period) = offer else {
            return XCTFail("Expected pay as you go")
        }
        XCTAssertEqual(firstPrice, "$0.99")
        XCTAssertEqual(period, OfferPeriod(value: 1, unit: .month))
    }

    func testPayUpFrontRetainsDiscountedPriceAndPeriod() {
        let offer = IntroductoryOffer.payUpFront(
            discountedPrice: "$6",
            period: OfferPeriod(value: 3, unit: .month)
        )
        guard case .payUpFront(let discountedPrice, let period) = offer else {
            return XCTFail("Expected pay up front")
        }
        XCTAssertEqual(discountedPrice, "$6")
        XCTAssertEqual(period, OfferPeriod(value: 3, unit: .month))
    }

    // MARK: - PromotionalOffer（保留 id/折扣/周期，不含标题/文案）

    func testPromotionalOfferCarriesDataWithoutCopy() {
        let offer = PromotionalOffer.winBack(
            id: "winback-123",
            discountPercentage: 20,
            period: OfferPeriod(value: 3, unit: .month)
        )
        XCTAssertEqual(offer.offerID, "winback-123")
        guard case .winBack(let id, let discountPercentage, let period) = offer else {
            return XCTFail("Expected win back")
        }
        XCTAssertEqual(id, "winback-123")
        XCTAssertEqual(discountPercentage, 20)
        XCTAssertEqual(period, OfferPeriod(value: 3, unit: .month))
    }

    func testRetentionOfferExposesOfferID() {
        let offer = PromotionalOffer.retention(
            id: "ret-001",
            discountPercentage: 15,
            period: OfferPeriod(value: 6, unit: .month)
        )
        XCTAssertEqual(offer.offerID, "ret-001")
    }

    func testUpgradeOfferExposesOfferID() {
        let offer = PromotionalOffer.upgrade(id: "up-9", discountPercentage: 10)
        XCTAssertEqual(offer.offerID, "up-9")
    }

    // MARK: - OfferCode（保留结构，不含展示标题）

    func testOfferCodeRetainsStructuredFields() {
        let offerCode = OfferCode(
            code: "SAVE20",
            discount: 20,
            type: .percentage(20),
            partner: nil
        )
        XCTAssertEqual(offerCode.code, "SAVE20")
        XCTAssertEqual(offerCode.discount, 20)
        XCTAssertEqual(offerCode.partner, nil)
        guard case .percentage(let percent) = offerCode.type else {
            return XCTFail("Expected percentage type")
        }
        XCTAssertEqual(percent, 20)
    }

    func testOfferCodeAcceptsFreeMonthsAndFixedPriceTypes() {
        let freeMonths = OfferCode(code: "FREE3", discount: 0, type: .freeMonths(3), partner: nil)
        guard case .freeMonths(let months) = freeMonths.type else {
            return XCTFail("Expected free months type")
        }
        XCTAssertEqual(months, 3)

        let fixed = OfferCode(code: "SPECIAL", discount: 0, type: .fixedPrice("¥9.9"), partner: "Partner")
        XCTAssertEqual(fixed.partner, "Partner")
        guard case .fixedPrice(let price) = fixed.type else {
            return XCTFail("Expected fixed price type")
        }
        XCTAssertEqual(price, "¥9.9")
    }

    // MARK: - UserSubscriptionStatus

    func testUserSubscriptionStatusCases() {
        let _: UserSubscriptionStatus = .newUser
        let _: UserSubscriptionStatus = .activeSubscriber
        let _: UserSubscriptionStatus = .expiredSubscriber
        let _: UserSubscriptionStatus = .cancelledSubscriber
        let _: UserSubscriptionStatus = .trialUser
    }

    func testProAccessStateAccessSemantics() {
        XCTAssertFalse(ProAccessState.none.grantsAccess)
        XCTAssertTrue(ProAccessState.lifetime.grantsAccess)
        XCTAssertTrue(ProAccessState.offlineProtected.grantsAccess)
        XCTAssertTrue(ProAccessState.subscription(.subscribed).grantsAccess)
        XCTAssertTrue(ProAccessState.subscription(.inGracePeriod).grantsAccess)
        XCTAssertTrue(ProAccessState.subscription(.inBillingRetryPeriod).grantsAccess)
        XCTAssertFalse(ProAccessState.subscription(.expired).grantsAccess)
        XCTAssertFalse(ProAccessState.subscription(.revoked).grantsAccess)
    }

    // MARK: - UserOfferEligibility

    func testUserOfferEligibilityEligible() {
        let offer = IntroductoryOffer.freeTrial(period: OfferPeriod(value: 7, unit: .day))
        let eligibility = UserOfferEligibility.eligible(.introductory(offer))

        if case .eligible(let offerType) = eligibility {
            if case .introductory(let intro) = offerType {
                if case .freeTrial(let period) = intro {
                    XCTAssertEqual(period, OfferPeriod(value: 7, unit: .day))
                } else {
                    XCTFail("Expected freeTrial offer")
                }
            } else {
                XCTFail("Expected introductory offer type")
            }
        } else {
            XCTFail("Expected eligible status")
        }
    }

    func testUserOfferEligibilityIneligible() {
        let eligibility = UserOfferEligibility.ineligible
        if case .ineligible = eligibility {} else { XCTFail("Expected ineligible status") }
    }

    func testUserOfferEligibilityUnknown() {
        let eligibility = UserOfferEligibility.unknown
        if case .unknown = eligibility {} else { XCTFail("Expected unknown status") }
    }

    // MARK: - OfferType

    func testOfferTypeIntroductory() {
        let intro = IntroductoryOffer.freeTrial(period: OfferPeriod(value: 14, unit: .day))
        let offerType = OfferType.introductory(intro)
        if case .introductory(let offer) = offerType {
            if case .freeTrial(let period) = offer {
                XCTAssertEqual(period, OfferPeriod(value: 14, unit: .day))
            } else {
                XCTFail("Expected freeTrial")
            }
        } else {
            XCTFail("Expected introductory offer type")
        }
    }

    func testOfferTypePromotional() {
        let promo = PromotionalOffer.winBack(
            id: "test-id",
            discountPercentage: 20,
            period: OfferPeriod(value: 1, unit: .month)
        )
        let offerType = OfferType.promotional(promo)
        if case .promotional(let offer) = offerType {
            XCTAssertEqual(offer.offerID, "test-id")
        } else {
            XCTFail("Expected promotional offer type")
        }
    }

    func testOfferTypeOfferCode() {
        let code = OfferCode(code: "TEST", discount: 30, type: .percentage(30), partner: nil)
        let offerType = OfferType.offerCode(code)
        if case .offerCode(let offer) = offerType {
            XCTAssertEqual(offer.code, "TEST")
        } else {
            XCTFail("Expected offerCode type")
        }
    }

    func testOfferTypeNone() {
        let offerType = OfferType.none
        if case .none = offerType {} else { XCTFail("Expected none offer type") }
    }
}
