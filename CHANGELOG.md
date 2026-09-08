# CHANGELOG

遵循 [Semantic Versioning](https://semver.org/)。版本策略见 [DELIVERY.md](DELIVERY.md)：
`0.x.y` 期间，任何公共 API、**行为**或持久化键的破坏性变更都提升 minor 版本。

## Unreleased（计划 0.3.0，尚未打标签）

- 购买成功回调与交易监听直接交付已验证权益：缓存可回读、可观察授权已发布之后才 finish；未验证/未知商品/缓存失败保留重投。
- ID 与状态共用一次扫描；取消或被更新状态取代的扫描不提交。部分验证保留既有权益，不续写全局校验时间。
- 完整快照缺失、退款和撤销清除终身授权；订阅历史继续保留。商品 catalog 以外的 ID 不授予 Pro。
- 没有加载商品元数据也能交付订阅；宿主观察统一授权入口，避免只看商品 ID 的分裂状态。
- 新增 [接入与防踩坑文档](docs/purchase-integration.md)，替换下面旧版本不正确的验证/finish 建议。
- 回归测试直接覆盖生产交付与快照提交函数，宿主测试验证仍须按 DELIVERY 执行。

## 0.2.1

- 回前台改为非交互式权益刷新，不自动调用 `AppStore.sync()`。

## 0.2.0

公共 API 未变；权益判定的**行为**变了两处，按策略提升 minor。

### 修复

- **一条无法验证的交易不再废掉整批权益。**
  `calculateUserStatusFromPurchases` / `updateUserPurchases` / `restoreEntitlementsSilently`
  过去在枚举 `Transaction.currentEntitlements` 时对每条调用 `try checkVerified(_:)`，
  单条 JWS 验证失败会当场抛出、退出整个 `for await`，把排在它前后的**已验证**购买一起丢掉，
  然后落到「按离线处理」的分支上靠缓存维持——缓存宽限期一过，持有有效订阅的用户就真的失去访问权限。
  丢多少还取决于坏交易在流里的位置，而顺序不由调用方决定。
  该版本改为逐条跳过，但仍把部分结果当完整结果；现已在 Unreleased 修正。

- 该版本曾对未验证的自动续订与非消耗型交易调用 finish。此策略现已撤回：
  不能在未交付权益时结束交易，不能断言验证失败永远不可恢复。
  同时纠正旧说明：空权益序列不等同离线；非续订订阅也在 `currentEntitlements` 的返回范围内。

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
