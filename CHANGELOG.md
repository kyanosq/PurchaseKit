# CHANGELOG

遵循 [Semantic Versioning](https://semver.org/)。版本策略见 [DELIVERY.md](DELIVERY.md)：
`0.x.y` 期间，任何公共 API、**行为**或持久化键的破坏性变更都提升 minor 版本。

## 0.2.0

公共 API 未变；权益判定的**行为**变了两处，按策略提升 minor。

### 修复

- **一条无法验证的交易不再废掉整批权益。**
  `calculateUserStatusFromPurchases` / `updateUserPurchases` / `restoreEntitlementsSilently`
  过去在枚举 `Transaction.currentEntitlements` 时对每条调用 `try checkVerified(_:)`，
  单条 JWS 验证失败会当场抛出、退出整个 `for await`，把排在它前后的**已验证**购买一起丢掉，
  然后落到「按离线处理」的分支上靠缓存维持——缓存宽限期一过，持有有效订阅的用户就真的失去访问权限。
  丢多少还取决于坏交易在流里的位置，而顺序不由调用方决定。
  现在逐条跳过：坏条目只丢它自己。策略见 `EntitlementVerification.verifiedOrSkipped`。

  连带影响：`restoreEntitlementsSilently` 里那个 `catch → handleOfflineValidation()` 只可能由
  `checkVerified` 触发（`currentEntitlements` 是不抛的 `AsyncStream`，真正离线时给出空序列而非错误），
  也就是说「一条 JWS 验证不过」曾被当作「设备离线」。该分支随之移除；离线兜底仍由
  `validatePurchasesWithFallback` 负责。

- **未验证的交易不再永远重投。**
  `Transaction.updates` 每次冷启动都会重投未 `finish()` 的交易，而 JWS 验证失败是这笔交易的
  永久属性。过去验证失败只记日志、从不结束，等于每次启动都跑一遍必然失败的路径。
  现在按商品类型分流（`EntitlementVerification.shouldFinishUnverified`）：
  自动续订订阅与非消耗型**结束**它——权益还能从 `currentEntitlements` 再取回，丢了不亏；
  消耗型与非续订订阅**保留**——它们不进 `currentEntitlements`，一旦 finish 就永久消失，
  验证不过就丢会让用户付了钱拿不到东西。未来新增的商品类型默认落在「保留」一侧。
  购买路径（`handlePurchaseResult`）同样处理，仍向调用方抛 `.failedVerification`。

- **发行版日志不再走 stdout。** `StoreKitManager` 里 9 处无条件 `print` 改为 `os.Logger`
  （`subsystem: "PurchaseKit"`, `category: "Store"`），商品 ID 按 `.private` 打点，
  与 `UserDefaultsProtocol` 已有的做法一致。`PurchaseCache` 的调试日志本就由 `#if DEBUG` 包住，未动。

### 工程

- **`Package.swift` 补齐平台声明**：`macOS 14` / `watchOS 10` / `tvOS 17`，与源码里一直写着的
  `@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)` 对齐。
  此前只声明 `.iOS(.v17)`，其余平台回落到 SwiftPM 的默认部署目标（macOS 10.13），
  `os.Logger`（macOS 11+）无法编译——后果不是「macOS 上不可用」，而是命令行 `swift build` /
  `swift test` **根本跑不起来**，整套单元测试从未进过任何命令行门禁。
  （iOS 之外的平台可编译但未做端到端验证，不作为支持承诺。）

- **`.storekit` 资源定位改用 `Bundle.module`**。SwiftPM 命令行构建把资源包放在 `.xctest` 的
  同级目录而非内部，原先「向每个 bundle 要它自己 Resources 里的 .bundle」的搜索永远扫不到它。

- **集成层判据新增「有无宿主 App」一维**（`StoreKitTestingPlatform.outcome(…, hosted:)` →
  `.skipUnhosted`）。命令行测试进程没有宿主 App，`storekitd` 不下发 `.storekit` 配置，
  空探针是结构性限制而非回归。原有的严格性保持不变：**只有「没有宿主」或「受影响运行时 ∧
  受影响工具链」两种理由能换来跳过，其余空探针一律判失败。**

- 新增 `EntitlementVerificationTests`（8 例）。`swift test` 现为 180 例、18 跳过（集成层）、0 失败。

### 已知未覆盖

上述两条修复的**策略**有确定性测试，**调用点**没有：`Transaction` 只能由 StoreKit 签发，
单元测试造不出 `.unverified(Transaction, _)`。策略与调用点之间只隔一行，但那一行仍需
有宿主 App 的集成环境或真实设备来验证。

## 0.1.1

首个持久公开标签。
