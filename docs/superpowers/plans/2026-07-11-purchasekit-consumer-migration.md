# PurchaseKit 消费方迁移计划

> 本文件是**计划**，不是执行指令。它描述如何把各消费方从内嵌 / 本地路径 PurchaseKit 副本迁移到
> 本仓库这一唯一上游。迁移按应用逐一完成；**在执行任何步骤前，不得修改任何消费方仓库**——
> 本计划仅用于在 canonical 仓库内对齐迁移顺序与验收标准。
>
> 设计来源：[2026-07-11-purchasekit-public-canonicalization-design.md](../specs/2026-07-11-purchasekit-public-canonicalization-design.md)。
> 实施计划：[2026-07-11-purchasekit-public-canonicalization.md](2026-07-11-purchasekit-public-canonicalization.md)。

## 前置条件（canonical 侧）

在迁移任何消费方之前，canonical 仓库应已达到 release candidate：

- 独立 checkout 可解析、构建，不依赖 `../AppSupportKit`。
- 完整套件在**非受影响**运行时（非 iOS 26.5 模拟器 + Xcode 26.5 组合）上零失败、零跳过。
- 公开入口要求**显式** `PurchaseCatalog` / `StoreKitConfiguration(namespace:)` 构造；无隐式占位默认。

## 通用迁移步骤（每个消费方通用）

对每个消费方仓库，按顺序执行；任意一步失败则停止、不上移：

1. **接入唯一上游**：把消费方对 PurchaseKit 的引用改为指向 canonical 仓库——迁移期可先指向本地路径
   `Packages/PurchaseKit`（canonical checkout），验证通过后再切到公开 Git URL
   `https://github.com/kyanosq/PurchaseKit.git`。**不要**在 canonical 未打 `0.1.1` 标签前把消费方
   固定到该标签。
2. **构造显式 catalog 与配置**：用消费方真实的 product ID 构造 `PurchaseCatalog`，用
   `<bundleIdentifier>.PurchaseKit` 构造 `StoreKitConfiguration(namespace:)`。移除任何对 `.stub`
   的生产引用。
3. **迁移应用专属文案到宿主**：标题、徽章、消息、紧迫感 / 营销文案、本地化错误描述由宿主负责。
   canonical 仅返回结构化状态、`displayPrice` 与稳定 `StoreError` case；把宿主需要的展示字符串搬进宿主项目。
   canonical 的公开边界只保留结构化数值（`displayPrice`、`Decimal` 月均价、纯数值节省 / 百分比、
   `PricingComparison`）；以下宿主面向 / 营销 UI 助手已从公开 API 移除，迁移时若消费方旧副本使用了它们，
   需在宿主层重新实现：`PurchaseJourney` / `UrgencyLevel`、`optimizePurchaseJourney`、
   `SubscriptionType.isRecommended`、`PlanComparison` / `formatPlanComparison`、`PricingPeriod` /
   `formatPricePerPeriod`、`getSubscriptionPeriod` / `getIntroductoryOfferDetails` /
   `formatPromotionalOffer` / `formatSavingsAmount`、`StoreKitConfiguration.formattedInterval`。
4. **命名空间兼容**：若消费方旧版本使用了无命名空间的旧缓存键，canonical 的 `PurchaseCache` 会
   执行一次性旧 key → namespaced key 迁移（仅当目标 key 尚无值时复制，回读后删除旧 key）。
   无需手工迁移；但应在真机 / 模拟器上验证已上线用户的购买记录不丢失。
5. **应用构建**：在消费方仓库构建应用（iOS 17+），确认无编译错误、无对旧 PurchaseKit 私有 API 的残留引用。
6. **购买 / 恢复 / paywall 测试**：在消费方仓库运行其购买、恢复与 paywall 测试（或等效人工验证），
   覆盖新用户、有效订阅、过期、恢复、退款 / 撤销路径。
7. **删除内嵌副本**：仅在第 5–6 步全部通过后，删除消费方仓库内的 `Packages/PurchaseKit` 副本或绝对路径
   symlink，并移除对 `../AppSupportKit` 的依赖（PurchaseKit 已内置 `UserDefaultsProtocol`）。
8. **中文提交门禁**：消费方仓库的迁移提交使用中文提交信息，例如“迁移至 PurchaseKit 唯一上游”。

> **第 6 步未通过的消费方不得执行第 7 步**——不删除其旧副本，避免回不去。

## 迁移顺序

### 1. Dit（首先迁移）

选择 Dit 首先迁移，因为它包含最多的分叉修复与测试证据，迁移过程中最有可能暴露 canonical 与
分叉行为差异：

- 逐项裁决 Dit 分叉中已吸收的通用修复（价格除零 / 非有限数保护、`NumberFormatter` 失败回退、
  Decimal 月均价、仅未过期交易记为 active、`Date`/数值缓存时间兼容、清缓存同步清内存权益、
  无签名者不展示促销）已在 canonical 中存在且由测试覆盖。
- 拒绝 / 重写的分叉内容（“已撤销订阅仍可经离线缓存授权”的回退、把所有错误退化为 `Store error`、
  重新硬编码中文价格 / 营销文案、含恒真断言的 adversarial probe、终身买断永久跳过退款验证）
  **不得**在迁移时回灌 canonical；若 Dit 现网行为依赖这些，在宿主层重新实现。
- Dit 是首个“真实消费者验证”候选：其迁移通过后，才具备创建 `0.1.1` 标签的前提。

### 2. MarkIt（随后迁移）

MarkIt 主要保留较旧的状态与价格实现，并包含“智能调度”等应用专属文案：

- 应用专属文案（含“智能调度”）不进入 canonical；迁移时搬进 MarkIt 宿主。
- MarkIt 的 introductory-offer 缓存思路仅作测试场景参考；canonical 使用 StoreKit 实时 eligibility
  判断，迁移时以 canonical 行为为准。
- 在 MarkIt 仓库完成通用步骤 1–8。

### 3. 其余引用方

其余引用 PurchaseKit 的仓库按各自验证通过后移除本地副本，统一遵循通用步骤 1–8。没有通过宿主
测试的应用不删除旧副本。

## 验收（canonical 侧）

- 至少一个真实消费者（首选 Dit）通过该 canonical checkout 完成购买 / 恢复 / paywall 验证后，
  canonical 才具备创建 `0.1.1` 标签的前提。
- 在 `0.1.1` 创建前，canonical 仓库不声明已发布；消费方可继续指向本地路径或未打标签 revision。
- 迁移过程中发现 canonical 缺失的通用能力，回流到 canonical 并补可观察的 TDD 测试，**不**在
  消费方仓库内 fork 出新的行为分叉。

## 不要做

- 不在未经消费方仓库验证前删除其内嵌 PurchaseKit 副本。
- 不在 canonical 未打 `0.1.1` 前把消费方固定到该标签。
- 不把应用专属文案、营销标题或恒真 adversarial probe 回灌 canonical。
- 不让消费方重新引入对 `../AppSupportKit` 的路径依赖。
