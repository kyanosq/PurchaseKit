import Foundation

// MARK: - 权益事实与纯函数解析器

/// 把权益判断从 StoreKitManager 中隔离出来的纯数据快照。
/// `hasActiveSubscription`/`hasLifetime`/`isTrial` 等都来自“已验证”来源；
/// `hadSubscriptionHistory`/`hasOfflineEvidence` 是与当前权益分离的本地证据。
struct EntitlementFacts: Equatable {
    let hasActiveSubscription: Bool
    let hasLifetime: Bool
    let isTrial: Bool
    let willAutoRenew: Bool
    let hadSubscriptionHistory: Bool
    let renewalState: RenewalState
    let hasOfflineEvidence: Bool
}

/// 纯函数权益解析器：同一份事实唯一决定用户状态与访问状态。
///
/// 计算顺序（访问状态）刻意如此：
/// 1. 终身证据优先（终身永不因订阅状态失效）；
/// 2. 已验证撤销永远拒绝，且优先于离线宽限——`.revoked` 不可被离线缓存覆盖；
/// 3. 已验证当前订阅按 renewalState 授权；
/// 4. 仅当以上都不成立、且存在离线证据时，才退回 `.offlineProtected`。
enum EntitlementStateResolver {
    static func userStatus(from facts: EntitlementFacts) -> UserSubscriptionStatus {
        if facts.isTrial && facts.hasActiveSubscription { return .trialUser }
        if facts.hasActiveSubscription {
            // willAutoRenew 不可验证时调用方应传入 true，避免把用户误判为 cancelled。
            return facts.willAutoRenew ? .activeSubscriber : .cancelledSubscriber
        }
        if facts.hasLifetime { return .activeSubscriber }
        // 当前权益为空不能抹掉历史购买身份：有历史的是过期订阅者，否则才是新用户。
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
