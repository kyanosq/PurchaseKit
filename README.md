# PurchaseKit

> StoreKit 2 内购与权益管理库，面向 iOS 17+ 的 Swift Package。

PurchaseKit 把 StoreKit 2 的购买、恢复、订阅状态与权益判断收敛成一个 **UI 无关** 的库：
宿主应用负责界面、文案与本地化，PurchaseKit 负责稳定的状态、缓存与安全策略。

- 单一 public product / target / 模块名：`PurchaseKit`。
- 通过 Swift Package Manager 的 Git URL 安装。
- 面向 iOS 17+，使用 StoreKit 2 与 `Observation`。清单自 0.2.0 起同时声明
  macOS 14 / watchOS 10 / tvOS 17，与源码里一直写着的 `@available` 一致——目的是让
  `swift build` / `swift test` 能在命令行跑起来（此前不能，见 [TESTING.md](TESTING.md)）。
  **iOS 之外的平台可编译但未做端到端验证，不作为支持承诺。**
- 不含 paywall UI、应用营销文案、analytics SDK、App Store 私钥或服务端收据验证。

## 能力

- 显式 `PurchaseCatalog` 映射订阅 / 终身商品 ID。
- 命名空间化的持久化（`StoreKitConfiguration(namespace:)`），含一次性旧 key 迁移。
- 把「当前已验证权益」与「历史购买身份」分离的纯函数权益解析器。
- 撤销（`.revoked`）永远拒绝访问、且优先于离线宽限；离线宽限仅适用于上次已验证、未撤销的权益。
- 促销优惠 fail-closed：未配置服务端签名者时不展示、不应用，显式请求时抛出 `.offerNotAvailable`，
  绝不静默退回原价购买。
- 价格安全：除零 / 非有限数 / 负节省保护；月均价格使用 StoreKit 的 `Decimal` 与 `priceFormatStyle`。
  库只返回**结构化数值**（`displayPrice`、`Decimal` 月均价、纯数值节省 / 百分比、`PricingComparison`
  的价格与等效年数）；试用 / 促销标题、本地化周期标签、“节省 / 相当于”句子、计划推荐与紧迫感等
  展示文案由宿主应用负责。
- 自带 [`PrivacyInfo.xcprivacy`](Sources/PurchaseKit/PrivacyInfo.xcprivacy) 隐私清单：PurchaseKit 使用
  UserDefaults（Required Reason API，reason `CA92.1`）持久化当前宿主 app 自身的购买 / 权益状态，
  不跟踪、不收集数据、不连接 tracking domains。清单由 `Package.swift` 以 `.process` 随 SDK 打包，
  **不依赖宿主 app 的 privacy manifest**。

## 安装

在 Xcode 中：File → Add Package Dependencies，输入：

```
https://github.com/kyanosq/PurchaseKit.git
```

或在 `Package.swift` 中：

```swift
dependencies: [
    .package(url: "https://github.com/kyanosq/PurchaseKit.git", from: "0.1.1")
]
```

> 版本 `0.1.1` 已在真实消费者通过 canonical checkout 验证后发布。
> 本次购买交付修复尚未打发布标签；验证修复时请固定包含修复的 Git revision，不能只保留旧的 Package.resolved。

购买、恢复与防踩坑的完整接入方式见 [购买与权益接入](docs/purchase-integration.md)。

## 最小示例

PurchaseKit 的所有生产入口都要求**显式**构造 catalog 与配置——没有隐式的占位默认。

```swift
import PurchaseKit

let catalog = PurchaseCatalog(
    subscriptionIDs: [
        .monthly: "com.yourcompany.app.monthly",
        .yearly:  "com.yourcompany.app.yearly"
    ],
    lifetimeIDs: [
        .lifetime: "com.yourcompany.app.lifetime"
    ]
)

// 命名空间由宿主决定；所有持久化键由它派生。
let config = StoreKitConfiguration(namespace: "com.yourcompany.app.PurchaseKit")

let store = StoreKitManager(catalog: catalog, config: config)

// 当前访问状态（结构化，UI 无关）。
let access = store.proAccessState()
let canUsePro = store.canAccessProFeatures()

// 购买与恢复。
try await store.purchaseSubscription(.yearly)
try await store.restorePurchases()
```

权益判断返回结构化状态与 StoreKit 提供的 `displayPrice`；展示文案、标题与本地化由宿主负责。
详见 [`ARCH.md`](ARCH.md) 与 [`docs/feature-docs/entitlement-state.md`](docs/feature-docs/entitlement-state.md)。

## 文档

- [ARCH.md](ARCH.md) — target 边界、依赖方向、权益 / 缓存 / 撤销 / 促销签名规则的唯一来源。
- [TESTING.md](TESTING.md) — 测试分层、运行命令与「变更 → 验证」映射。
- [DELIVERY.md](DELIVERY.md) — CI、版本策略、打标签与回滚流程。
- [CHANGELOG.md](CHANGELOG.md) — 每个版本改了什么行为，以及仍未覆盖什么。
- [AGENTS.md](AGENTS.md) — 自动化 agent 的最小约束。
- [STOREKIT_TESTING_GUIDE.md](STOREKIT_TESTING_GUIDE.md) — StoreKit 集成测试的运行细节与已知限制。
- [docs/feature-docs/entitlement-state.md](docs/feature-docs/entitlement-state.md) — 权益状态与访问矩阵。

## 许可证

[MIT](LICENSE)。
