# StoreKit 测试指南

本指南是 PurchaseKit 测试分层的唯一操作来源：说明各层如何运行、集成层为什么依赖
StoreKit Testing，以及在哪些运行时/工具链组合上运行集成测试的已知限制。命令与分层规则与
`TESTING.md` 保持一致；本文件补充 StoreKit 专属细节。

## 测试分层

PurchaseKit 把可观察行为拆成两层，避免把纯逻辑绑死在 StoreKit 配置文件上。

### 第一层：稳定单元测试（不依赖 `.storekit`）

通过 `StoreKitServiceProtocol` / `PurchaseCacheProtocol` 的可控替身驱动
`StoreKitManager`、`PurchaseCache`、`EntitlementStateResolver` 与定价逻辑。这一层覆盖：

- 价格除零 / 非有限数 / 负节省 / Decimal 月均价（`PricingFormatterTests`）
- 命名空间派生、旧 key 迁移、`Date`/`Double` 时间兼容、历史与终身证据（`PurchaseCacheTests`）
- 结构化优惠模型、显式公开 init（`InAppPurchaseModelsTests`、`PromotionalOfferTests`）
- 权益解析：过期订阅者、取消但仍有效、撤销、宽限、终身（`EntitlementStateResolverTests`）
- 恢复购买 / 强制刷新 / 缓存重置 / 任务生命周期（`StoreKitManagerRestorePurchasesTests`）
- 公开 API 与源码契约（`PublicAPITests`）
- 自带隐私清单契约（`PrivacyManifestTests`）
- StoreKit 集成探针的平台判据：toolchain/runtime 组合（`StoreKitTestingPlatformTests`）

这些测试不需要 StoreKit 配置文件，可以快速、确定性地运行，并在任何受支持的环境上始终完整执行。

### 第二层：StoreKit 集成测试（依赖 `.storekit`）

`StoreKitManagerIntegrationTests` 使用 `SKTestSession` 加载 `PurchaseKitTest.storekit`，
对真实 StoreKit 行为（产品加载、购买、恢复、intro 资格、事务完成）做端到端验证。

GitHub Actions 的 XCTest runner 没有可供 `Product.purchase()` 使用的 UI scene anchor。CI 因此执行第一层
稳定测试，加上 9 个不展示购买 sheet 的真实 StoreKit 检查；购买 / 恢复用例完整保留，放在有 host app
或真实消费者的环境运行。两者是不同运行表面，不能用无界面 runner 的 UI anchor 失败冒充产品回归。

## 资源布局与 fail-fast 设置

- `.storekit` 文件位于测试 target 根目录：`Tests/PurchaseKitTests/PurchaseKitTest.storekit`。
- `Package.swift` 用 `.copy("PurchaseKitTest.storekit")` 把它复制进测试 bundle。
  SPM 会把单文件资源放进嵌套资源子包 `PurchaseKit_PurchaseKitTests.bundle`，
  因此 `StoreKitTestHelper.locateConfigurationFile(name:)` 会在测试 bundle、主 bundle
  及其嵌套子包中按名定位，再用 `SKTestSession(contentsOf:)` 打开会话。
- `StoreKitTestHelper.enableStoreKitTestSession()` 是 fail-fast 的：找不到配置文件时直接
  `throw StoreError.productNotFound`，让 `setUp` 失败，而不是打印后继续误导后续断言。

## 运行命令

> 使用任意已安装的 iOS 17+ 模拟器即可；下方示例以 `iPhone 17 Pro` 为占位设备名，
> 可替换为目标环境上任意可用的 iOS 17+ 模拟器（如 `iPhone 16 Pro`）。

构建（含测试 target）：

```bash
xcodebuild -scheme PurchaseKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/PurchaseKit-Build \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

只跑第一层稳定单元测试（这些测试在任何受支持环境上始终完整运行）：

```bash
xcodebuild -scheme PurchaseKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/PurchaseKit-Build \
  CODE_SIGNING_ALLOWED=NO test \
  -only-testing:PurchaseKitTests/PricingFormatterTests \
  -only-testing:PurchaseKitTests/PurchaseCacheTests \
  -only-testing:PurchaseKitTests/EntitlementStateResolverTests \
  -only-testing:PurchaseKitTests/StoreKitManagerRestorePurchasesTests \
  -only-testing:PurchaseKitTests/InAppPurchaseModelsTests \
  -only-testing:PurchaseKitTests/PromotionalOfferTests \
  -only-testing:PurchaseKitTests/PublicAPITests \
  -only-testing:PurchaseKitTests/StoreKitConfigurationTests \
  -only-testing:PurchaseKitTests/PurchaseCatalogTests \
  -only-testing:PurchaseKitTests/StoreKitTestingPlatformTests \
  -only-testing:PurchaseKitTests/PrivacyManifestTests
```

完整套件（含 StoreKit 集成测试）：

```bash
xcodebuild -scheme PurchaseKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/PurchaseKit-Build \
  CODE_SIGNING_ALLOWED=NO test
```

## 受支持的环境与已知限制

集成测试依赖 `SKTestSession` 把 `.storekit` 配置下发给模拟器的 `storekitd`。在受影响的
**iOS 26.5 模拟器运行时 + 构建工具链早于 Xcode 26.6** 的组合上，通过 `xcodebuild test`（CLI）
运行时，`.storekit` 配置不会被推送给 `storekitd`（Apple 已确认问题 **FB22237318**，
见 Apple Developer Forums thread 826971）。表现是：`SKTestSession` 能创建，
但 `Product.products(for:)` 静默退回生产 App Store 并返回空。

Apple DTS 已确认该问题在 **Xcode 26.6** 中修复。

### 受支持的环境

- **CI（零跳过门禁）**：在**非** iOS 26.5/Xcode 26.5 的 iOS 17+ 模拟器上运行（GitHub Actions
  `macos-15`、Xcode 16.4、iOS 18.5、`iPhone 16 Pro`）。该组合不受 FB22237318 影响；CI 运行第一层
  与 9 个 headless-safe 集成检查，并对其中任何失败或跳过判为不通过。需要购买 UI 的用例不属于这个
  无界面运行表面。
- **本地开发**：任意 iOS 17+ 模拟器。若恰好处于上述受影响组合，集成层会按下方判据跳过；
  升级到 Xcode 26.6+ 后，同一 iOS 26.5 运行时上的跳过会自动转为失败，从而恢复完整集成覆盖。

### 精确化的跳过判据（不要把任何空探针都当成平台缺陷）

集成层 `setUp` 用一次原始 `Product.products(for:)` 探针，并通过
`StoreKitTestingPlatform.outcome(probeIsEmpty:runtimeVersion:simulator:toolchainVersion:)`
决定处置。判据同时考虑**运行时维度**与**构建工具链维度**：

- 探针**拿到商品** → 正常执行全部集成断言（`.run`），无论运行时/工具链如何。
- **空探针 + iOS 26.5 模拟器运行时 + 构建工具链早于 26.6** → 跳过整个集成层（`.skipAffected`，
  附 FB22237318 与 Xcode 26.6 修复说明）。运行时由 `ProcessInfo.operatingSystemVersion`
  （major 26 / minor 5）+ `targetEnvironment(simulator)` 判定；工具链从构建产物的
  `DTPlatformVersion`/`DTSDKName` 解析。
- **空探针 + 其它任何组合（含真机、非 26.5 运行时、或已升级到 Xcode 26.6+ 的工具链）** →
  直接 `XCTFail`（`.failRegression`）。这意味着资源路径、schema、product ID 或 StoreKit 测试
  设置一旦回归导致空探针，会在非受影响组合上以失败暴露，而不是被静默跳过、CI 仍绿。

`StoreKitTestingPlatformTests` 是这套判据的纯逻辑回归（不启动 StoreKit、始终执行），覆盖全部
toolchain/runtime 组合，包括关键回归：iOS 26.5 模拟器运行时 + 已修复工具链（Xcode 26.6+）时
空探针必须判为失败而非跳过。所有集成断言保持完整。

## 不要做

- 不要把集成测试改成绕过 `Product.products` 的镜像实现；它们必须驱动真实 StoreKit。
- 不要把 `enableStoreKitTestSession()` 改回“打印错误后继续”的静默模式。
- 不要把跳过判据放宽为“只要探针为空就跳过”；必须同时匹配运行时与工具链两个维度。
- 不要在本文件中声称 100% 覆盖率；覆盖率以实际运行的测试为准。
