import XCTest
import StoreKit
@testable import PurchaseKit

/// 两条验证策略的回归测试。
///
/// `Transaction` 在单元测试里造不出来（它只能由 StoreKit 签发），所以这里测的是
/// **策略本身**，用 `VerificationResult<Int>` 承载。策略与调用点之间只隔一行，
/// 调用点的正确性由 `StoreKitManagerRestorePurchasesTests` 与集成层覆盖。
@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
final class EntitlementVerificationTests: XCTestCase {

    // MARK: - 一条坏条目不该废掉整批

    /// 这条是修复前会失败的那条：旧实现在坏条目上 `throw`，整个 `for await` 当场退出，
    /// 排在它前面的 1 和后面的 3 一起丢——用户手里两笔已验证的购买凭空消失。
    func testABadEntryInTheMiddleDoesNotTakeItsNeighboursDown() {
        let batch: [VerificationResult<Int>] = [
            .verified(1),
            .unverified(2, .invalidSignature),
            .verified(3)
        ]

        XCTAssertEqual(EntitlementVerification.collectVerified(batch), [1, 3])
    }

    /// 坏条目排在最前时，旧实现一条都收不到。这是同一个 bug 最刺眼的形态：
    /// 结果取决于坏交易在流里的位置，而流的顺序不由我们决定。
    func testTheOutcomeDoesNotDependOnWhereTheBadEntrySits() {
        let leading: [VerificationResult<Int>] = [
            .unverified(0, .invalidSignature), .verified(1), .verified(2)
        ]
        let trailing: [VerificationResult<Int>] = [
            .verified(1), .verified(2), .unverified(0, .invalidSignature)
        ]

        XCTAssertEqual(EntitlementVerification.collectVerified(leading), [1, 2])
        XCTAssertEqual(EntitlementVerification.collectVerified(trailing), [1, 2])
    }

    func testEveryVerificationFailureModeIsSkippedNotTrusted() {
        let failures: [VerificationResult<Int>.VerificationError] = [
            .invalidSignature,
            .invalidCertificateChain,
            .revokedCertificate,
            .invalidDeviceVerification
        ]

        for failure in failures {
            XCTAssertNil(
                EntitlementVerification.verifiedOrSkipped(VerificationResult<Int>.unverified(7, failure)),
                "\(failure) 不得放行未验证的载荷"
            )
        }
    }

    func testAVerifiedEntryPassesThroughUnchanged() {
        XCTAssertEqual(EntitlementVerification.verifiedOrSkipped(VerificationResult<Int>.verified(42)), 42)
    }

    func testAnAllBadBatchYieldsNothingRatherThanTrustingAnything() {
        let batch: [VerificationResult<Int>] = [
            .unverified(1, .invalidSignature),
            .unverified(2, .revokedCertificate)
        ]

        XCTAssertTrue(EntitlementVerification.collectVerified(batch).isEmpty)
    }

    // MARK: - 未验证交易的 finish 策略

    /// 可从 `currentEntitlements` 再次取回的类型：结束它，否则 `Transaction.updates`
    /// 每次冷启动都会重投一笔永远验证不过的交易。
    func testRecoverableProductTypesAreFinishedSoTheyStopComingBack() {
        XCTAssertTrue(EntitlementVerification.shouldFinishUnverified(.autoRenewable))
        XCTAssertTrue(EntitlementVerification.shouldFinishUnverified(.nonConsumable))
    }

    /// 不可再取回的类型：留着。finish 一笔没验过的消耗型交易 = 用户付了钱、货没了、
    /// 也没有任何痕迹可以追。宁可让它一直重投，等一个人来看。
    func testUnrecoverableProductTypesAreKeptSoNobodyLosesWhatTheyPaidFor() {
        XCTAssertFalse(EntitlementVerification.shouldFinishUnverified(.consumable))
        XCTAssertFalse(EntitlementVerification.shouldFinishUnverified(.nonRenewable))
    }

    /// 未来 StoreKit 新增商品类型时，默认落到「不结束」一侧——保守的那一侧是不销毁凭据。
    func testAnUnknownFutureProductTypeDefaultsToKeepingTheTransaction() {
        XCTAssertFalse(EntitlementVerification.shouldFinishUnverified(Product.ProductType(rawValue: "SomethingNew")))
    }
}
