import XCTest
@testable import PurchaseKit

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
final class EntitlementStateResolverTests: XCTestCase {

    // MARK: - userStatus

    func testLapsedKnownSubscriberIsNotNewUser() {
        // 当前权益为空，但有经过验证的订阅历史：必须是过期订阅者，不能回退成新用户。
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
        // 活跃订阅但关闭自动续订：分类为已取消，但仍保留访问权限。
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

    func testActiveSubscriberIsClassifiedWhenAutoRenewing() {
        let facts = EntitlementFacts(
            hasActiveSubscription: true,
            hasLifetime: false,
            isTrial: false,
            willAutoRenew: true,
            hadSubscriptionHistory: true,
            renewalState: .subscribed,
            hasOfflineEvidence: false
        )
        XCTAssertEqual(EntitlementStateResolver.userStatus(from: facts), .activeSubscriber)
        XCTAssertEqual(EntitlementStateResolver.accessState(from: facts), .subscription(.subscribed))
    }

    func testTrialUserClassificationRequiresActiveSubscription() {
        let facts = EntitlementFacts(
            hasActiveSubscription: true,
            hasLifetime: false,
            isTrial: true,
            willAutoRenew: true,
            hadSubscriptionHistory: false,
            renewalState: .subscribed,
            hasOfflineEvidence: false
        )
        XCTAssertEqual(EntitlementStateResolver.userStatus(from: facts), .trialUser)
    }

    func testLifetimeOnlyUserIsClassifiedAsActive() {
        let facts = EntitlementFacts(
            hasActiveSubscription: false,
            hasLifetime: true,
            isTrial: false,
            willAutoRenew: false,
            hadSubscriptionHistory: false,
            renewalState: .expired,
            hasOfflineEvidence: false
        )
        XCTAssertEqual(EntitlementStateResolver.userStatus(from: facts), .activeSubscriber)
        XCTAssertEqual(EntitlementStateResolver.accessState(from: facts), .lifetime)
    }

    func testGenuineNewUserHasNoHistory() {
        let facts = EntitlementFacts(
            hasActiveSubscription: false,
            hasLifetime: false,
            isTrial: false,
            willAutoRenew: false,
            hadSubscriptionHistory: false,
            renewalState: .expired,
            hasOfflineEvidence: false
        )
        XCTAssertEqual(EntitlementStateResolver.userStatus(from: facts), .newUser)
        XCTAssertEqual(EntitlementStateResolver.accessState(from: facts), .none)
    }

    // MARK: - accessState / revocation / offline

    func testRevokedAlwaysDeniesOfflineAccess() {
        // 已验证撤销：即便存在离线宽限证据，也必须拒绝访问。
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

    func testRevokedDeniesEvenWithLifetimeAbsentButActiveFlagStale() {
        // 撤销优先级高于活跃订阅：renewalState == .revoked 时直接拒绝。
        let facts = EntitlementFacts(
            hasActiveSubscription: true,
            hasLifetime: false,
            isTrial: false,
            willAutoRenew: true,
            hadSubscriptionHistory: true,
            renewalState: .revoked,
            hasOfflineEvidence: true
        )
        XCTAssertEqual(EntitlementStateResolver.accessState(from: facts), .subscription(.revoked))
        XCTAssertFalse(EntitlementStateResolver.accessState(from: facts).grantsAccess)
    }

    func testOfflineEvidenceGrantsAccessWithoutFalselyClassifyingCancellation() {
        let facts = EntitlementFacts(
            hasActiveSubscription: false,
            hasLifetime: false,
            isTrial: false,
            willAutoRenew: false,
            hadSubscriptionHistory: true,
            renewalState: .expired,
            hasOfflineEvidence: true
        )
        XCTAssertEqual(EntitlementStateResolver.userStatus(from: facts), .expiredSubscriber)
        XCTAssertEqual(EntitlementStateResolver.accessState(from: facts), .offlineProtected)
        XCTAssertTrue(EntitlementStateResolver.accessState(from: facts).grantsAccess)
    }
}
