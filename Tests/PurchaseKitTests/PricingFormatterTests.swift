import XCTest
@testable import PurchaseKit

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
final class PricingFormatterTests: XCTestCase {
    private let formatter = PricingFormatter(locale: Locale(identifier: "en_US"))

    // MARK: - formatDiscountPercentage guards

    func testDiscountPercentageRejectsZeroBaseline() {
        XCTAssertEqual(formatter.formatDiscountPercentage(0, discountedPrice: 0), "")
    }

    func testDiscountPercentageRejectsNegativeBaseline() {
        XCTAssertEqual(formatter.formatDiscountPercentage(-10, discountedPrice: -5), "")
    }

    func testDiscountPercentageRejectsNonFiniteBaseline() {
        XCTAssertEqual(formatter.formatDiscountPercentage(.infinity, discountedPrice: 5), "")
        XCTAssertTrue(formatter.formatDiscountPercentage(100, discountedPrice: .nan).isEmpty)
    }

    func testDiscountPercentageClampsNegativeSavings() {
        // 打折后比原价还贵，绝不能展示负折扣。
        XCTAssertEqual(formatter.formatDiscountPercentage(100, discountedPrice: 150), "0%")
    }

    func testDiscountPercentageComputesRealDiscount() {
        XCTAssertEqual(formatter.formatDiscountPercentage(100, discountedPrice: 60), "40%")
    }

    // MARK: - yearlySavingsPercentage guards

    func testYearlySavingsClampsNegativeResult() {
        // 年付比 12 个月月付还贵：不应出现负节省，回退为 0。
        let percentage = formatter.yearlySavingsPercentage(monthlyPrice: 4.99, yearlyPrice: 79.99)
        XCTAssertEqual(percentage ?? -1, 0, accuracy: 0.0001)
    }

    func testYearlySavingsRejectsZeroMonthlyBaseline() {
        XCTAssertNil(formatter.yearlySavingsPercentage(monthlyPrice: 0, yearlyPrice: 0))
    }

    func testYearlySavingsRejectsNonFiniteInputs() {
        XCTAssertNil(formatter.yearlySavingsPercentage(monthlyPrice: .infinity, yearlyPrice: 49.99))
        XCTAssertNil(formatter.yearlySavingsPercentage(monthlyPrice: 6.99, yearlyPrice: .nan))
    }

    func testYearlySavingsPercentageForRealBargain() {
        // 月付 6.99 × 12 = 83.88，年付 49.99，节省 33.89，约 40.4%。
        let percentage = formatter.yearlySavingsPercentage(monthlyPrice: 6.99, yearlyPrice: 49.99)
        XCTAssertEqual(percentage ?? -1, 40.42, accuracy: 0.05)
    }

    // MARK: - yearlySavingsAmount guards

    func testYearlySavingsAmountForRealBargain() {
        let amount = formatter.yearlySavingsAmount(monthlyPrice: 6.99, yearlyPrice: 49.99)
        XCTAssertEqual(amount ?? -1, 33.89, accuracy: 0.01)
    }

    func testYearlySavingsAmountClampsNegativeResult() {
        let amount = formatter.yearlySavingsAmount(monthlyPrice: 4.99, yearlyPrice: 79.99)
        XCTAssertEqual(amount ?? -1, 0, accuracy: 0.0001)
    }

    func testYearlySavingsAmountRejectsNonFiniteInputs() {
        XCTAssertNil(formatter.yearlySavingsAmount(monthlyPrice: .infinity, yearlyPrice: 49.99))
    }

    func testYearlySavingsAmountRejectsZeroMonthlyBaseline() {
        // 基准价（月付 × 12）为 0 的价对无效，绝不能把无效价对算成节省金额。
        XCTAssertNil(formatter.yearlySavingsAmount(monthlyPrice: 0, yearlyPrice: 0))
        // 此前会产出假节省：(0, -1) → max(0, 0 − (−1)) = 1。必须拒绝。
        XCTAssertNil(formatter.yearlySavingsAmount(monthlyPrice: 0, yearlyPrice: -1))
    }

    func testYearlySavingsAmountRejectsNegativeMonthlyBaseline() {
        // 月基准价为负的价对同样无效，必须返回 nil 而非夹紧后的 0。
        XCTAssertNil(formatter.yearlySavingsAmount(monthlyPrice: -5, yearlyPrice: -10))
        XCTAssertNil(formatter.yearlySavingsAmount(monthlyPrice: -5, yearlyPrice: 49.99))
    }

    // MARK: - lifetime comparison (structured numeric result)

    func testLifetimeComparisonSuppressesFalseBargain() {
        // 终身价高于两年年付价：不报告节省，等效年数为 0（库不再产出展示文案）。
        let result = formatter.calculateLifetimeSavings(lifetimePrice: 199, yearlyPrice: 29)
        XCTAssertEqual(result.savings, 0)
        XCTAssertEqual(result.equivalentYears, 0)
    }

    func testLifetimeComparisonReportsRealBargain() {
        // 终身 150，年付 99（两年 198）：终身比两年年付便宜 48 → 真实节省，等效约 1.52 年。
        let result = formatter.calculateLifetimeSavings(lifetimePrice: 150, yearlyPrice: 99)
        XCTAssertEqual(result.savings, 48, accuracy: 0.0001)
        XCTAssertEqual(result.equivalentYears, 150.0 / 99.0, accuracy: 0.0001)
        XCTAssertGreaterThan(result.equivalentYears, 0)
    }

    func testLifetimeComparisonRejectsNonFiniteBaseline() {
        // 非有限基准价：不产生 nan / inf，回退为 0。
        let result = formatter.calculateLifetimeSavings(lifetimePrice: .infinity, yearlyPrice: 99)
        XCTAssertEqual(result.savings, 0)
        XCTAssertEqual(result.equivalentYears, 0)
    }

    func testLifetimeComparisonRejectsZeroYearlyPrice() {
        // 年付价为 0：避免除零，回退为 0。
        let result = formatter.calculateLifetimeSavings(lifetimePrice: 150, yearlyPrice: 0)
        XCTAssertEqual(result.savings, 0)
        XCTAssertEqual(result.equivalentYears, 0)
    }
}
