# 权益状态与访问矩阵

PurchaseKit 把「当前已验证权益」与「历史购买身份」分离，并由纯函数
`EntitlementStateResolver` 把同一份 `EntitlementFacts` 唯一映射到用户状态与访问状态。
架构规则见 [../../ARCH.md](../../ARCH.md)。

## 两件事实

1. **当前已验证权益**：来自 `Transaction.currentEntitlements`（已验证、未撤销、未过期），
   决定当前在线授权。已验证的撤销交易不授予任何权益，也不进入历史 / 活跃快照。
2. **历史购买身份**：来自经过验证后写入的本地订阅历史与终身标记，与当前权益 ID 分离、仅累加，
   用于区分新用户与过期 / 取消用户。当前权益为空时**不**清除历史购买身份。

## `EntitlementFacts`

| 字段 | 来源 |
| --- | --- |
| `hasActiveSubscription` | 当前已验证、未过期的自动续订交易 |
| `hasLifetime` | 已验证终身交易 或 可持久终身标记 |
| `isTrial` | 当前活跃交易为 introductory offer |
| `willAutoRenew` | 已验证的续订信息；无法验证时按 true 处理，避免误判为 cancelled |
| `hadSubscriptionHistory` | 非空的本地订阅历史 |
| `renewalState` | 订阅组状态：`subscribed` / `inGracePeriod` / `inBillingRetryPeriod` / `expired` / `revoked` |
| `hasOfflineEvidence` | 仍在宽限期内、且本地仍有已验证购买记录（不含撤销证据） |

## 用户状态（`UserSubscriptionStatus`）

计算顺序：

1. `isTrial && hasActiveSubscription` → `trialUser`
2. `hasActiveSubscription` → `willAutoRenew ? activeSubscriber : cancelledSubscriber`
3. `hasLifetime` → `activeSubscriber`
4. 否则 → `hadSubscriptionHistory ? expiredSubscriber : newUser`

> `willAutoRenew` 无法验证时调用方传入 true，因此活跃但续订信息未验证的用户保持 `activeSubscriber`，
> 不会被误判为 `cancelledSubscriber`。

## 访问状态（`ProAccessState`）访问矩阵

计算顺序刻意如此（撤销优先于离线宽限；终身优先于一切）：

| 条件（按优先级自上而下） | `ProAccessState` | 授权访问 |
| --- | --- | --- |
| `hasLifetime` | `.lifetime` | ✅ |
| `renewalState == .revoked` | `.subscription(.revoked)` | ❌（即便存在离线证据） |
| `hasActiveSubscription`，`renewalState` ∈ {`subscribed`, `inGracePeriod`, `inBillingRetryPeriod`} | `.subscription(state)` | ✅ |
| `hasActiveSubscription`，`renewalState` ∈ {`expired`, ...}（理论上不会与 hasActive 并存） | `.subscription(state)` | 按上表，`expired` ❌ |
| 无当前订阅，但有 `hasOfflineEvidence` | `.offlineProtected` | ✅（仅限宽限期内、无撤销证据） |
| 其余 | `.none` | ❌ |

`RenewalState` 授权语义：

| `RenewalState` | 授权访问 |
| --- | --- |
| `subscribed` | ✅ |
| `inGracePeriod` | ✅ |
| `inBillingRetryPeriod` | ✅ |
| `expired` | ❌ |
| `revoked` | ❌ |

## 本地可恢复权益证据（`StoreKitManager.hasLocalRestorableEntitlementEvidence`）

`hasLocalRestorableEntitlementEvidence` 是 UI 无关的结构化布尔查询，回答
「本地是否持有『成功校验即可恢复 Pro』的证据」：

```
!purchaseCache.getLastValidPurchases().isEmpty
|| purchaseCache.hasLifetimeEntitlement()
|| canAccessProFeatures()
```

它与上述两类事实的关系：

| 概念 | 含义 | 与本属性的关系 |
| --- | --- | --- |
| 当前授权（`canAccessProFeatures()` / `ProAccessState`） | 此刻是否实际放行 Pro（在线、已验证） | 本属性在当前授权为 true 时也为 true，但**范围更宽**：即便当前授权尚未刷新，只要本地有已验证购买记录或终身标记即返回 true |
| durable 订阅历史（`hadSubscriptionHistory` / `hasOfflineEvidence`） | 用于区分新用户与过期 / 取消用户的累加身份，**包含**仅过期 / 已取消的历史 | 本属性**不依据**订阅历史判定；它只看 last-valid 购买记录、终身标记与当前授权，因此**刻意排除**纯过期 / 取消的历史，避免对已流失用户误称「上线后权益会回来」 |

适用场景：宿主 App 在无需等待在线校验往返时，据此决定是否展示 / 预热「恢复购买」入口或预置信任。
该属性只返回布尔事实，**不产生任何 UI 文案**；paywall 与恢复流程的措辞、营销逻辑属于宿主，
不应进入 PurchaseKit。

## 关键不变量

- `.revoked` **永远**拒绝访问，且优先于离线宽限与历史身份；离线缓存不可覆盖撤销。
- 离线宽限仅适用于「上次已验证、且未出现撤销证据」的权益；验证失败与撤销不会授予权益。
- 终身买断是可持久证据：即便订阅离线宽限已过期、或当前没有任何缓存 ID，仍还原 `.lifetime` 访问。
- 有订阅历史的用户在当前权益为空时是 `expiredSubscriber`，**不**回退为 `newUser`。
- 释放 `StoreKitManager` 后，事务监听任务与退款检查任务必须可被取消且不强持有 manager。
