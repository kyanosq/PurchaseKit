import Foundation
import StoreKit

/// 交易验证的两条策略，从 `StoreKitManager` 里抽出来，好处只有一个：可以被测试。
///
/// `Transaction` 在测试里造不出来，但 `VerificationResult<T>` 是公开泛型枚举——
/// 用 `VerificationResult<Int>` 就能把「一条坏条目要不要废掉整批」这个判断钉死。
@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
enum EntitlementVerification {

    /// 逐条验证：单条验证失败只丢弃那一条。
    ///
    /// `Transaction.currentEntitlements` 的每个条目独立签名，一条坏条目并不说明其余条目不可信。
    /// 让它抛出会把整次刷新推进 catch，用户手里已验证的订阅一并落空、退回离线缓存，
    /// 缓存宽限期一过就真的失去访问权限——而这条坏交易在流里的位置还决定了前面多少条被丢掉。
    /// 那既不是 fail closed，也不是 fail open，只是「看运气」。
    static func verifiedOrSkipped<T>(_ result: VerificationResult<T>) -> T? {
        switch result {
        case .verified(let safe):
            return safe
        case .unverified:
            return nil
        }
    }

    /// 上面那条策略作用在一整批上的结果。测试用它表达「中间坏一条，两边都要留下」。
    static func collectVerified<T>(_ results: [VerificationResult<T>]) -> [T] {
        results.compactMap { verifiedOrSkipped($0) }
    }

    /// 验证不过的交易要不要 `finish()`。
    ///
    /// 不 finish 的代价是确定的：`Transaction.updates` 每次冷启动都重投未结束的交易，
    /// 而 JWS 验证失败是这笔交易的永久属性——重投一万次也不会变成已验证。
    ///
    /// 但只对「权益可以从 `Transaction.currentEntitlements` 再次取回」的类型这么做，
    /// 也就是自动续订订阅与非消耗型：即使这次丢掉，下次刷新还能重新拿到。
    /// 消耗型与非续订订阅不进 `currentEntitlements`，一旦 finish 就永久消失——
    /// 验证不过就丢会让用户付了钱拿不到东西。那种交易宁可留着重投，等一个人来看。
    static func shouldFinishUnverified(_ productType: Product.ProductType) -> Bool {
        switch productType {
        case .autoRenewable, .nonConsumable:
            return true
        default:
            return false
        }
    }
}
