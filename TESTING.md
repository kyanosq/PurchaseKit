# 测试（TESTING）

本文件是 PurchaseKit **测试分层与运行命令的唯一来源**。架构规则见 [ARCH.md](ARCH.md)，
发布流程见 [DELIVERY.md](DELIVERY.md)，StoreKit 测试细节见 [STOREKIT_TESTING_GUIDE.md](STOREKIT_TESTING_GUIDE.md)。

## 测试分层

### 第一层：稳定单元测试（不依赖 `.storekit`）

通过 `StoreKitServiceProtocol` / `PurchaseCacheProtocol` 的可控替身驱动纯逻辑，**在任何受支持的
iOS 17+ 环境上始终完整运行**：

| 测试类 | 覆盖 |
| --- | --- |
| `PricingFormatterTests` | 价格除零 / 非有限数 / 负节省 / Decimal 月均价 |
| `PurchaseCacheTests` | 命名空间派生、旧 key 迁移、`Date`/`Double` 时间兼容、历史与终身证据、可挥发清理 |
| `InAppPurchaseModelsTests` / `PromotionalOfferTests` | 结构化优惠模型、显式公开 init、促销安全策略 |
| `EntitlementStateResolverTests` | 过期订阅者、取消但仍有效、撤销、宽限、终身 |
| `StoreKitManagerRestorePurchasesTests` | 恢复 / 强制刷新 / 缓存重置 / 任务生命周期 / 可持久证据穿越过期宽限 |
| `PublicAPITests` | 公开配置与 manager 构造、源码契约（无不安全默认、无 no-op API、促销 fail-closed、**生产源码不含宿主面向文案 / 营销 UI 助手**） |
| `StoreKitTestingPlatformTests` | StoreKit 集成探针的平台判据（toolchain/runtime 组合），始终执行 |
| `PrivacyManifestTests` | 自带 `PrivacyInfo.xcprivacy`：不跟踪 / 不收集数据 / 仅 UserDefaults + CA92.1；且 `Package.swift` 以 `.process` 声明该资源 |

### 第二层：StoreKit 集成测试（依赖 `.storekit`）

`StoreKitManagerIntegrationTests` 用 `SKTestSession` 加载 `PurchaseKitTest.storekit`，端到端验证
产品加载、购买、恢复、intro 资格与事务完成。该层分为两种运行表面：

- GitHub Actions 的无界面 XCTest host 运行 9 个不弹购买 sheet 的真实 StoreKit 检查（商品加载、价格、
  周期、介绍性优惠、新用户状态），与第一层一起执行结构化零失败、零跳过门禁。
- 调用 `Product.purchase()` / `AppStore.sync()` 的完整购买与恢复用例，需要能提供 UI scene anchor 的宿主测试
  环境。无界面 runner 会返回 UI anchor / `ASDErrorDomain` 错误，因此 CI 不把这种环境能力误判为库回归；
  测试本身完整保留，必须在发布前由真实消费者或有 host app 的测试环境执行。

此外，该层在受影响的 iOS 26.5 模拟器运行时 + 构建工具链早于 Xcode 26.6 的组合上，若原始商品探针
为空，会按精确判据跳过。

## 运行命令

> 使用任意已安装的 iOS 17+ 模拟器；`iPhone 17 Pro` 为占位设备名，可替换为任意可用 iOS 17+ 模拟器
> （如 `iPhone 16 Pro`）。

CI 与本地的区别（详见 [DELIVERY.md](DELIVERY.md)）：

- **CI** 在 `macos-15` runner 上显式锁定 **Xcode 16.4**，destination 为
  `platform=iOS Simulator,OS=18.5,name=iPhone 16 Pro`；xcodebuild 成功后用
  `xcresulttool get test-results summary` 的 JSON 做结构化门禁（`failedTests == 0`、
  `skippedTests == 0`、`passedTests == totalTestCount > 0`）。CI 选择第一层与 9 个 headless-safe
  StoreKit 集成检查；这是该运行表面的零跳过权威信号。
- **本地**通常运行在 iOS 26.5 模拟器运行时上，会出现受 FB22237318 影响的跳过；本地命令用于
  日常迭代与第一层稳定单元测试，不作为零跳过验收信号。

第一层稳定单元测试：

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

只构建（含测试 target）：

```bash
xcodebuild -scheme PurchaseKit \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/PurchaseKit-Build \
  CODE_SIGNING_ALLOWED=NO build -quiet
```

清单解析：

```bash
swift package dump-package > /dev/null
```

## 变更 → 验证映射

| 变更类型 | 必须验证 |
| --- | --- |
| 价格 / 节省 / 月均价逻辑 | `PricingFormatterTests` 全绿 |
| 缓存键 / 迁移 / 历史 / 终身 | `PurchaseCacheTests` 全绿 |
| 权益解析（撤销 / 宽限 / 历史） | `EntitlementStateResolverTests` + `StoreKitManagerRestorePurchasesTests` 全绿 |
| 促销 / 签名策略 | `PromotionalOfferTests` + `PublicAPITests` 的促销源码契约 |
| 公开 init / 源码契约 | `PublicAPITests` 全绿 |
| StoreKit 集成探针判据 | `StoreKitTestingPlatformTests` 全绿（始终执行） |
| 产品加载 / 价格 / 周期 / intro 配置 | CI 的 9 个 headless-safe `StoreKitManagerIntegrationTests` 零失败、零跳过 |
| 购买 / 恢复 / 事务完成 | 完整 `StoreKitManagerIntegrationTests` 在有 UI scene anchor 的 host 环境或真实消费者中通过 |
| 隐私清单 / Required Reason API 声明 | `PrivacyManifestTests` 全绿（清单四项事实 + `Package.swift` 以 `.process` 声明资源） |
| 任何源码改动 | `git diff --check` 无空白错误；`swift package dump-package` 成功 |

## 不要做

- 不要把集成测试改成绕过 `Product.products` 的镜像实现。
- 不要把 `enableStoreKitTestSession()` 改回“打印错误后继续”的静默模式。
- 不要削弱有意义的测试，或把跳过判据放宽为“只要探针为空就跳过”。
- 不要声称 100% 覆盖率；覆盖率以实际运行的测试为准。
