import Foundation
import StoreKit

// MARK: - Pricing Formatter

/// 面向宿主的展示文案（标题、徽章、消息、紧迫感、本地化周期标签、“节省/相当于”句子、
/// 计划推荐策略）由宿主应用负责。本类型只保留 UI 无关的能力：通用货币格式化、
/// StoreKit 的 `displayPrice`、`Decimal` 派生的月均价、格式化的纯数值百分比，以及纯数值节省计算。
@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
public struct PricingFormatter {
    private let locale: Locale
    private let currencyFormatter: NumberFormatter

    public init(locale: Locale = .current) {
        self.locale = locale
        self.currencyFormatter = NumberFormatter()
        self.currencyFormatter.numberStyle = .currency
        self.currencyFormatter.locale = locale
    }

    // MARK: - Basic Formatting

    public func formatCurrency(_ value: Double) -> String {
        if let formatted = currencyFormatter.string(from: NSNumber(value: value)) { return formatted }
        // NumberFormatter 失败时退回 locale 自身货币符号，而不是硬编码人民币符号。
        return "\(locale.currencySymbol ?? "")\(Int(value))"
    }

    public func formatCurrency(_ decimal: Decimal) -> String {
        if let formatted = currencyFormatter.string(from: decimal as NSDecimalNumber) { return formatted }
        return "\(locale.currencySymbol ?? "")\(decimal)"
    }

    // MARK: - Product Formatting

    public func getFormattedPrice(for product: Product) -> String {
        return product.displayPrice
    }

    public func getFormattedPriceValue(for product: Product) -> Double {
        return Double(truncating: product.price as NSNumber)
    }

    // MARK: - Discount Formatting

    /// 格式化的纯数值百分比（如 "40%"）。拒绝非正 / 非有限基准价，避免产生 nan% / inf%；
    /// 打折后比原价还贵时夹紧为 0，绝不返回负折扣。
    public func formatDiscountPercentage(_ originalPrice: Double, discountedPrice: Double) -> String {
        guard originalPrice.isFinite, discountedPrice.isFinite, originalPrice > 0 else { return "" }
        let discount = (originalPrice - discountedPrice) / originalPrice * 100
        return String(format: "%.0f%%", max(0, discount))
    }

    // MARK: - Yearly Savings

    /// 年付相比月付的节省百分比，基准价为 12 个月月付。
    /// 基准价非正或非有限时返回 nil；年付更贵时夹紧为 0，绝不返回负节省。
    public func yearlySavingsPercentage(monthlyPrice: Double, yearlyPrice: Double) -> Double? {
        let baseline = monthlyPrice * 12
        guard baseline.isFinite, yearlyPrice.isFinite, baseline > 0 else { return nil }
        return max(0, baseline - yearlyPrice) / baseline * 100
    }

    /// 年付相比月付的节省金额，基准价为 12 个月月付。
    /// 基准价非正或非有限时返回 nil（避免把无效价对算成节省，例如 `(0, -1)`）；
    /// 年付更贵时夹紧为 0。
    public func yearlySavingsAmount(monthlyPrice: Double, yearlyPrice: Double) -> Double? {
        let baseline = monthlyPrice * 12
        guard baseline.isFinite, yearlyPrice.isFinite, baseline > 0 else { return nil }
        return max(0, baseline - yearlyPrice)
    }

    /// 年订阅的月均价格。直接用 StoreKit 的 `Decimal` 与 `product.priceFormatStyle`，
    /// 避免把 Decimal 转成 Double 再格式化造成的精度与 locale 漂移。
    public func monthlyEquivalent(for product: Product) -> String? {
        guard product.subscription?.subscriptionPeriod.unit == .year else { return nil }
        let monthly = product.price / Decimal(12)
        return monthly.formatted(product.priceFormatStyle)
    }

    // MARK: - Lifetime Comparison

    /// 终身买断相对年付的结构化节省结果（纯数值，不含宿主展示文案）。
    /// 非有限 / 无可比年价 / 终身并不比两年年付便宜时，`savings` 与 `equivalentYears` 均为 0。
    /// 把该结果转成自然语言展示文案（如等效年数的描述）是宿主应用的职责。
    public func calculateLifetimeSavings(lifetimePrice: Double, yearlyPrice: Double) -> PricingComparison {
        let noComparison = PricingComparison(
            lifetimePrice: lifetimePrice,
            yearlyPrice: yearlyPrice,
            equivalentYears: 0,
            savings: 0
        )
        guard lifetimePrice.isFinite, yearlyPrice.isFinite, yearlyPrice > 0 else { return noComparison }
        let twoYearPrice = yearlyPrice * 2
        let savings = max(0, twoYearPrice - lifetimePrice)
        // 终身并不比两年年付便宜时不报告节省，避免宿主展示误导性比较。
        guard savings > 0 else { return noComparison }
        let equivalentYears = lifetimePrice / yearlyPrice
        return PricingComparison(
            lifetimePrice: lifetimePrice,
            yearlyPrice: yearlyPrice,
            equivalentYears: equivalentYears,
            savings: savings
        )
    }
}

// MARK: - Pricing Comparison

/// 终身买断相对年付的结构化数值比较。仅暴露价格、等效年数与节省金额；
/// 自然语言展示文案由宿主应用负责。
public struct PricingComparison {
    public let lifetimePrice: Double
    public let yearlyPrice: Double
    public let equivalentYears: Double
    public let savings: Double

    /// 显式公开 init：外部构造的值类型必须能仅凭 `import PurchaseKit` 构造，
    /// 不得依赖 internal 合成成员 init。
    public init(
        lifetimePrice: Double,
        yearlyPrice: Double,
        equivalentYears: Double,
        savings: Double
    ) {
        self.lifetimePrice = lifetimePrice
        self.yearlyPrice = yearlyPrice
        self.equivalentYears = equivalentYears
        self.savings = savings
    }
}
