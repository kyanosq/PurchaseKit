# 购买与权益接入

本指南对应包含本次交付修复的源码 revision；`0.1.1`、`0.2.0`、`0.2.1` 均不包含完整修复。
行为与缓存规则以 [ARCH.md](../ARCH.md) 为准。

## 一个 App 使用一个长期存活的 manager

在 App 根部创建 `StoreKitManager(catalog:config:)` 并注入各页面。catalog 只包含本 App
用于解锁同一套 Pro 功能的自动续订订阅和非消耗型商品；这不是消耗型商品的交付库。
保持生产环境的 `StoreKitConfiguration.namespace` 稳定，升级时不要换 namespace 或清空缓存。
不要在每次打开付费墙时重建 manager，否则监听、刷新和缓存会由多个实例竞争。

```swift
import SwiftUI
import PurchaseKit

@MainActor
struct PremiumContent: View {
    let store: StoreKitManager // 从 App 根部注入

    var body: some View {
        if store.canAccessProFeatures() {
            Text("Pro") // 宿主负责具体内容和本地化
        } else {
            Text("Free")
        }
    }
}
```

授权统一读取 `canAccessProFeatures()` 或 `proAccessState().grantsAccess`。
`purchasedProductIDs` 用于诊断/识别商品，`userStatus` 用于用户分类，
`hasLocalRestorableEntitlementEvidence` 用于恢复入口提示；它们都不能单独替代授权结果。
不要在 App 中额外 `|| cache.hasLifetimeEntitlement()`，这会绕过退款与完整刷新后的失效处理。

## 购买、恢复与错误

```swift
// 用户点击购买。方法返回前，已验证权益已经保存回读并发布；库随后 finish 交易。
do {
    try await store.purchaseLifetime(.lifetime)
    // 根据 store.canAccessProFeatures() 更新/关闭付费墙。
} catch StoreError.userCancelled {
    // 用户取消；无需报“购买失败”。
} catch StoreError.pending {
    // 显示“等待批准/付款完成”；保持事务监听，批准后自动刷新界面。
} catch {
    // 显示宿主本地化错误和恢复入口，不能只打印日志。
}

// 启动/回前台/进入页面：非交互式查询，不主动调用 AppStore.sync()。
await store.restoreEntitlementsSilently()

// 只有用户明确点击“恢复购买”时才调用，可能出现 Apple 认证界面。
try await store.restorePurchases()
```

购买成功回调和 `Transaction.updates` 共用交付路径：验证签名、检查 catalog/商品类型、
更新对应权益、保存并回读缓存、发布可观察状态，最后 `finish()`。购买成功后的授权不依赖
再枚举 `currentEntitlements`，也不依赖商品价格/订阅组元数据加载成功。
未验证、未知商品或缓存回读失败的交易不结束；调用购买方法的宿主会收到错误，监听路径记录错误并保留重投机会。
缓存回读成功表示持久化接口可读到写入结果，不是进程崩溃或存储硬件故障下的磁盘事务保证。

恢复结束且没有 Pro，只能说明没有当前有效权益；不能断言“从未购买”。已过期和已退款购买
不属于当前授权，历史购买身份仍可能存在。需要核对具体投诉时，应使用用户订单/交易证据，
不能由一条商店评论推定具体的 StoreKit 错误。

## Observation 与 Combine 桥接

SwiftUI 直接读取上述方法即可观察库的状态。如果宿主使用 `ObservableObject` / `@Published`
保存自己的权限快照，需要桥接访问结果，并在回调后重新注册；只监听商品 ID 会漏掉访问状态变化。

```swift
private func observeAccess() {
    withObservationTracking {
        _ = store.canAccessProFeatures()
        _ = store.purchasedProductIDs // 若宿主同时展示购买类型
    } onChange: { [weak self] in
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.observeAccess() // 先重订阅，再执行可能挂起的宿主更新
            await self.updateSnapshot()
        }
    }
}
```

`withObservationTracking` 的通知发生在写入前，所以通过 MainActor Task 在本轮同步提交结束后读取。
不要在每帧或页面 body 中重新发起购买/恢复；并发刷新没有必要。

## 刷新、取消与缓存边界

- 一次刷新只枚举一次权益。ID、终身标记、订阅事实和用户分类来自同一个结果。
- 任务取消或被更新的购买/刷新/清理取代时，丢弃这次未提交结果；`AsyncStream` 的正常结束
  不能替代 `Task.checkCancellation()`。
- 任一条目验证失败，已验证条目仍可生效，但结果不完整：保留先前确认的权益、不续写完整校验时间；
  显式恢复返回 `failedVerification`，静默刷新记录未完成状态。失败载荷本身绝不授予权益。
- 完整、未取消且全部验证成功的快照是当前授权依据，缺失商品应移除，包括终身标记。
  启动时的旧终身标记只用于恢复缓存，不能永久覆盖退款、账号切换后的完整结果。
- 已验证撤销立即移除相应授权。订阅历史用于分类，不为过期订阅提供永久 Pro。
- 不能把“空序列”解释为网络离线：StoreKit 管理本地交易信息，网络状态与枚举结果不是一一对应的。
- 非完整刷新不延长全局校验时间。已验证的直接订阅交付建立新的 Pro 离线宽限依据；
  终身交付依靠终身证据，后续完整快照/撤销仍可使其失效。

## 发布前验证

`swift test` 验证共享交付/提交路径：交付先于 finish、取消不清空、旧刷新不覆盖新购买、
部分验证不清空既有权益、完整空快照与退款清除终身权限、catalog 校验和访问状态观察。
这不等于完成了真实 StoreKit 购买。

消费者还应在有 UI scene 的宿主 App 中启用 `.storekit`，验证买断/订阅购买、完成后恢复、
Ask to Buy 批准、退款，以及 App 的付费墙退出和 Pro 功能放行。测试前后隔离缓存与清理测试交易。
最后用 Sandbox/TestFlight 验证真实账号和设备；本地签发交易不证明 App Store 线上订单已修复。
具体门禁见 [TESTING.md](../TESTING.md) 和 [DELIVERY.md](../DELIVERY.md)。

## Apple 依据

- [Transaction.currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements)：
  返回本 App 的当前权益，包含有效/宽限期自动续订订阅、非消耗型，以及非续订订阅的最近交易；不含已退款/撤销商品。
- [Transaction.finish()](https://developer.apple.com/documentation/storekit/transaction/finish())：交付内容或服务之后完成交易。
- [Transaction.updates](https://developer.apple.com/documentation/storekit/transaction/updates)：处理购买批准、其他设备等更新；
  未完成交易会在启动时重投。不能假设未验证交易一定永远无法恢复，因此不能为消除重投而提前 finish。
