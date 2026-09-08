# 架构（ARCH）

本文件是 PurchaseKit 的**架构与行为规则唯一来源**：target 边界、依赖方向、权益 / 缓存 /
撤销 / 促销签名规则。测试命令见 [TESTING.md](TESTING.md)，发布流程见 [DELIVERY.md](DELIVERY.md)，
StoreKit 测试细节见 [STOREKIT_TESTING_GUIDE.md](STOREKIT_TESTING_GUIDE.md)，权益状态与访问矩阵的
完整说明见 [docs/feature-docs/entitlement-state.md](docs/feature-docs/entitlement-state.md)。

## Target 与依赖方向

单一 public target `PurchaseKit`，无运行期第三方依赖。

```text
PurchaseCatalog ──▶ StoreKitManager ◀── StoreKitServiceProtocol ◀── RealStoreKitService (StoreKit 2)
                        │
                        ├──▶ StoreKitConfiguration（命名空间派生所有持久化键）
                        ├──▶ PurchaseCacheProtocol ◀── PurchaseCache（UserDefaultsProtocol）
                        ├──▶ PricingFormatter（价格 / 节省 / Decimal 月均价）
                        └──▶ EntitlementStateResolver（纯函数权益解析）

宿主应用 ──import──▶ PurchaseKit（仅此一个公开模块）
```

规则：

- `UserDefaultsProtocol` 直接并入 `PurchaseKit` target（它出现在 `PurchaseCache` 的公共注入接口中），
  不为单协议增加隐藏 target。外部调用者只需 `import PurchaseKit`。
- StoreKit 交互全部收口在 `StoreKitServiceProtocol` 之后；`StoreKitManager` 通过协议访问
  `Product`、`Transaction.currentEntitlements`、`Transaction.updates`、`AppStore.sync()`，
  测试用可控替身驱动，不依赖 `.storekit` 配置。
- 依赖方向单向：`StoreKitManager` 依赖各组件；组件之间不反向依赖 manager。
- 权益判断是纯函数（`EntitlementStateResolver`），输入 `EntitlementFacts`，输出唯一确定的
  `UserSubscriptionStatus` 与 `ProAccessState`，便于确定性单测。

## 公共 API 契约

- 生产入口显式构造：`StoreKitManager(catalog:config:...)` 与 `StoreKitConfiguration(namespace:)`
  必须显式接收参数。`.stub` 仅存在于测试目标，**不**作为生产默认。
- 库返回**结构化状态**、StoreKit 提供的 `displayPrice`、`Decimal` 派生价格与稳定错误 case。
  展示标题、徽章、消息、紧迫感 / 营销文案、计划推荐 / 比较策略与本地化错误描述属于宿主应用。
  库**不**产出介绍性 / 促销优惠标题、本地化周期标签、“节省 / 相当于”句子或紧迫感 / 推荐助手。
- `StoreError` 不含 `LocalizedError`；宿主把 case 映射为本地化文本。
- 外部构造的值类型（如 `PricingComparison`）暴露显式 public init。
- `PricingComparison` 是纯结构化数值结果（价格、等效年数、节省金额），不含宿主面向的格式化 /
  消息字段；其自然语言展示文案由宿主负责。

## 权益状态规则

库区分两件事实：

1. **当前已验证权益**：来自已验证购买/交易更新或 `Transaction.currentEntitlements`，决定当前授权。
2. **历史购买身份**：来自经过验证后写入的本地历史，用于区分新用户与过期 / 取消用户。

- 当前权益为空时**不**清除历史购买身份。状态计算先处理 verified revocation，再处理当前订阅状态，
  最后才用历史身份分类 `.expiredSubscriber` 或 `.cancelledSubscriber`。
- 已验证的撤销交易不授予任何权益，也不进入历史 / 活跃快照。
- 仅在未过期（或无过期时间）时保留 `activeTransaction`。
- `willAutoRenew` 无法验证时不把用户判为 `cancelledSubscriber`（保持 `activeSubscriber`）。

访问状态（`ProAccessState`）的计算顺序刻意如此：

1. 终身证据优先（终身永不因订阅状态失效）；
2. 已验证撤销永远拒绝，且**优先于离线宽限**——`.revoked` 不可被离线缓存覆盖；
3. 已验证当前订阅按 `RenewalState` 授权；
4. 仅当以上都不成立、且存在离线证据时，才退回 `.offlineProtected`。

完整的「事实 → 用户状态 / 访问状态」映射见
[docs/feature-docs/entitlement-state.md](docs/feature-docs/entitlement-state.md) 的访问矩阵。

## 缓存规则

- 持久化键全部由 `StoreKitConfiguration.namespace` 派生（如 `<namespace>.lastSuccessfulValidation`）。
  `.default` 使用 `<bundleIdentifier>.PurchaseKit`；无 bundle identifier 时退回 `PurchaseKit`。
- `PurchaseCache` 在目标 key 尚不存在时执行**一次性**旧 key 到 namespaced key 的迁移，
  仅复制已知旧 key、不覆盖新值；复制值可回读后才删除旧 key。
- 缓存时间兼容历史上以 `Date` 或正数 epoch `Double`/`NSNumber` 写入的表示。
- 订阅历史仅累加、不在权益过期时抹除。终身买断证据可持久，但已验证撤销或完整快照中缺失时必须清除。
- 离线宽限期过期时，`clearVolatileCache()` 仅清理可挥发的访问证据（当前权益 ID、验证时间、缓存状态、
  登录 / 前台检查时间），**保留**订阅历史与终身证据——客户的购买身份不被一次过期的离线宽限抹除。
  完整重置仍由 `clearAllCache()` / `StoreKitManager.clearOfflineCache()` 负责。
- 离线宽限仅适用于「上次已验证、且未出现撤销证据」的权益；验证失败与撤销不会授予权益。

## 交付与刷新边界

- 购买回调和交易监听复用同一交付函数：仅接受 catalog 内类型匹配的已验证交易，更新缓存并回读、发布授权后才 `finish()`。失败不能吞掉后照常结束交易。
- 不结束未验证或未知商品交易，不以重投次数推定验证永远失败。
- 刷新只枚举一次；取消和已被新状态取代的扫描不得提交。一个未验证条目不会丢掉其他已验证权益，但该扫描不再是完整快照，不删除既有授权或续写全局校验时间。
- 完整空快照表示没有当前有效权益，清除当前 ID/终身标记，保留订阅历史；空结果不能直接等同离线。
- `currentEntitlements` 中已验证的订阅也可能处于账单宽限期，不以过去的 `expirationDate` 单独拒绝；没有加载商品元数据时仍能交付当前授权。
- `canAccessProFeatures()` / `proAccessState()` 是宿主唯一授权入口，支持 Observation；原始 ID、历史状态和缓存布尔值不单独授权。
- 自定义 `PurchaseCacheProtocol` 必须实现写入后可回读的当前 ID。持久化失败不 finish，已验证退款在当前实例中仍立即拒绝访问。

接入例子与错误展示见 [docs/purchase-integration.md](docs/purchase-integration.md)。

## 撤销（退款 / revoke）规则

- `.revoked` **永远**拒绝访问，且优先于离线宽限与历史身份。
- 已验证撤销交易触发：移除该商品当前权益与离线宽限证据、清空对应 `activeTransaction`、
  标记 `subscriptionGroupStatus = .revoked`，使解析器优先拒绝。
- 终身买断被撤销时清除可持久终身标记。
- 释放 `StoreKitManager` 后，事务监听任务与退款检查任务必须可被取消且不强持有 manager。

## 促销签名规则

促销购买需要服务端 JWS 签名（`PromotionalOfferSigning`）。

- 未配置签名者时：eligibility 不返回 promotional offer；`PromotionalOfferPolicy.canSurfaceOffer`
  返回 false；显式请求 promotional offer 时 `purchaseOptions` 抛出 `.offerNotAvailable`。
- **绝不**因无法签名而静默退回原价购买——`purchaseOptions` 的 `.promotional` 分支以
  `guard let signer = promotionalOfferSigner else { throw StoreError.offerNotAvailable }` 开头，fail closed。
- Offer code 通过专用 StoreKit sheet 兑换，不并入购买 options。

## 价格安全规则

- `formatDiscountPercentage`、`yearlySavingsPercentage`、`yearlySavingsAmount`、
  `calculateLifetimeSavings` 均对非正 / 非有限基准价 guard；负节省夹紧为 0 或返回 nil。
- `NumberFormatter` 失败时退回 locale 自身货币符号，不硬编码人民币符号。
- 年订阅月均价格由 `Product.price / Decimal(12)` 与 `product.priceFormatStyle` 计算，
  避免转成 `Double` 造成的精度与 locale 漂移。

## 隐私清单（Privacy Manifest）

PurchaseKit 使用 UserDefaults（Required Reason API）持久化当前宿主 app 自身的购买 / 权益状态，
因此 SDK 自带 [`Sources/PurchaseKit/PrivacyInfo.xcprivacy`](Sources/PurchaseKit/PrivacyInfo.xcprivacy)，
由 `Package.swift` 在 PurchaseKit target 中以 `.process("PrivacyInfo.xcprivacy")` 显式声明为资源。

- `NSPrivacyTracking = false`，`NSPrivacyTrackingDomains` 与 `NSPrivacyCollectedDataTypes` 为空：
  库不跟踪、不收集数据、不连接 tracking domains。
- `NSPrivacyAccessedAPITypes` 仅声明 `NSPrivacyAccessedAPICategoryUserDefaults`，reason 为 `CA92.1`
  （访问同一 app 自身的信息）。
- 作为公开 Swift Package，隐私清单**随 SDK 自身打包**，不依赖宿主 app 的 privacy manifest。
- 契约由第一层 `PrivacyManifestTests` 锁定（见 [TESTING.md](TESTING.md)）：以
  `PropertyListSerialization` 解析清单结构，严格断言上述四项事实，并校验 `Package.swift` 的资源声明，
  防止「清单文件存在却未打包」。
