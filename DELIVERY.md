# 交付与发布（DELIVERY）

本文件是 PurchaseKit **CI、版本策略、打标签与回滚流程的唯一来源**。架构规则见 [ARCH.md](ARCH.md)，
测试命令见 [TESTING.md](TESTING.md)，StoreKit 测试细节见 [STOREKIT_TESTING_GUIDE.md](STOREKIT_TESTING_GUIDE.md)。

## 版本策略

- 首个持久公开标签为 `0.1.1`，后续遵循 [Semantic Versioning](https://semver.org/)。
- `0.x.y` 期间，任何公共 API、行为或持久化键的破坏性变更都会提升 minor 版本。
- **`0.1.1` 仅在至少一个真实消费者通过该 canonical checkout 完成迁移验证后才会创建。**
  在那之前不发布标签；消费者迁移流程见
  [docs/superpowers/plans/2026-07-11-purchasekit-consumer-migration.md](docs/superpowers/plans/2026-07-11-purchasekit-consumer-migration.md)。
- 提交信息使用中文。

## CI

CI 定义在 `.github/workflows/ci.yml`，在 `push` 到 `main` 与所有 `pull_request` 上运行。

环境选择（强制、确定性）：

- runner：GitHub Actions `macos-15`，其官方镜像默认携带 **Xcode 16.4**、**iOS 18.5 模拟器运行时**
  与 **iPhone 16 Pro**。
- 工具链显式锁定为 `/Applications/Xcode_16.4.app`（`DEVELOPER_DIR` 环境变量），不依赖 runner
  镜像的默认 Xcode 选择。
- 该组合（Xcode 16.4 / iOS 18.5）**不**属于 FB22237318 受影响组合（iOS 26.5 模拟器运行时 +
  Xcode 26.5），可稳定运行商品加载类 StoreKit 集成检查；但 GitHub 的无界面 XCTest host 没有
  `Product.purchase()` 所需 UI scene anchor，因此购买 / 恢复用例由有 host app 的真实消费者验证。

CI 实际命令（与 [TESTING.md](TESTING.md) 引用的一致）：

```bash
xcodebuild -scheme PurchaseKit \
  -destination 'platform=iOS Simulator,OS=18.5,name=iPhone 16 Pro' \
  -resultBundlePath TestResults.xcresult \
  CODE_SIGNING_ALLOWED=NO test
```

门禁步骤（每步失败即整体失败）：

1. `swift package dump-package` 成功（清单可解析）。
2. `xcodebuild ... test` 在 iOS 18.5 / iPhone 16 Pro 上运行第一层稳定套件与 9 个 headless-safe
   StoreKit 集成检查，捕获 `.xcresult`；
   `set -eo pipefail` 使 xcodebuild 的非零退出码（失败）直接失败。
3. **结构化零失败且零跳过门禁**：xcodebuild 成功后运行
   `xcrun xcresulttool get test-results summary --path TestResults.xcresult` 得到 JSON，
   用系统 Python 解析，**当且仅当** `failedTests == 0`、`skippedTests == 0` 且
   `passedTests == totalTestCount`（且 `totalTestCount > 0`）时通过。`.xcresult` 摘要是权威来源，
   不再依赖控制台 grep（后者无法可靠区分跳过原因，且会被测试方法名命中产生假阳性）。
4. 上传 `.xcresult` 作为 artifact（`if: always()`，失败时也上传）。
5. `git diff --check` 拒绝空白错误。

本地命令见 [TESTING.md](TESTING.md)。CI 的零跳过信号仅覆盖其明确选择的 headless-safe 表面；完整
购买 / 恢复信号来自有 UI scene anchor 的 host app 或真实消费者测试。

## 打标签流程

1. CI 的稳定 + headless-safe 门禁零失败、零跳过，且完整购买 / 恢复流已由真实消费者验证；
   `git diff --check` 通过；
   凭据 / 绝对路径 / 相邻包路径 / 生成物 / stub ID 扫描无命中。
2. 至少一个真实消费者已通过该 canonical checkout 完成迁移验证（购买、恢复、paywall 测试通过）。
3. 更新 `CHANGELOG`（若引入）或发布说明后，创建带注释标签 `git tag -a 0.x.y -m "..."`。
4. 标签创建前不得在 README / DELIVERY 之外的公开处声明该版本已发布。

## 回滚流程

- 若已发布版本出现回归：通过消费者回退到上一个已知良好的 Git revision 或标签，而非在库内
  打补丁式回滚行为（避免在 canonical 上掩盖问题）。
- 破坏性权益 / 缓存回归优先以新 minor 版本修正，并在发布说明中明确迁移影响。
- `.revoked` 经离线缓存恢复访问、或缺促销签名者时静默原价购买，属于**安全回归**，
  必须立即修复并补回归测试，不得以“兼容旧行为”为由保留。
