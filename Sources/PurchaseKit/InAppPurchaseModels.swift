import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Structured offer period

/// UI 无关的优惠周期结构。保留 StoreKit 给出的 value 与 unit，而不是把它压扁成
/// “天数”或一段本地化文案，避免宿主拿到错误的试用长度。
public struct OfferPeriod: Sendable, Equatable {
    public enum Unit: Sendable, Equatable { case day, week, month, year }

    public let value: Int
    public let unit: Unit

    /// value 必须为正；非法周期是数据错误，应尽早暴露而不是被静默接受。
    public init(value: Int, unit: Unit) {
        precondition(value > 0, "OfferPeriod value must be positive")
        self.value = value
        self.unit = unit
    }
}

// MARK: - 购买项目（结构化，不含营销文案）

public enum SubscriptionType: CaseIterable, Sendable {
    case monthly
    case yearly

    @available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
    @MainActor public func price(from storeManager: StoreKitManager) -> String? {
        storeManager.getFormattedPrice(for: self)
    }
}

public enum LifetimePurchase: CaseIterable, Sendable {
    case lifetime

    @available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
    @MainActor public func price(from storeManager: StoreKitManager) -> String? {
        storeManager.getFormattedPrice(for: self)
    }
}

// MARK: - 优惠（保留 ID、原始价格、折扣数据、周期与资格；不含宿主文案）

public enum OfferType {
    case introductory(IntroductoryOffer)
    case promotional(PromotionalOffer)
    case offerCode(OfferCode)
    case none
}

/// 介绍性优惠。保留试用/首期付款/预付的价格与周期，不再生成标题、副标题或徽章文案。
public enum IntroductoryOffer: Sendable, Equatable {
    case freeTrial(period: OfferPeriod)
    case payAsYouGo(firstPrice: String, period: OfferPeriod)
    case payUpFront(discountedPrice: String, period: OfferPeriod)
}

/// 促销优惠。保留 id、折扣百分比与周期；签名由宿主服务提供，未签名时不在此处暴露。
public enum PromotionalOffer: Sendable, Equatable {
    case winBack(id: String, discountPercentage: Int, period: OfferPeriod)
    case retention(id: String, discountPercentage: Int, period: OfferPeriod)
    case upgrade(id: String, discountPercentage: Int)

    /// 非 UI 文案访问器：仅暴露 id 供购买链路匹配 StoreKit offer。
    public var offerID: String {
        switch self {
        case .winBack(let id, _, _): return id
        case .retention(let id, _, _): return id
        case .upgrade(let id, _): return id
        }
    }
}

/// 优惠码。保留 code、折扣、类型与合作伙伴，不再生成展示标题。
public struct OfferCode: Sendable, Equatable {
    public let code: String
    public let discount: Int
    public let type: OfferCodeType
    public let partner: String?

    public enum OfferCodeType: Sendable, Equatable {
        case percentage(Int)
        case freeMonths(Int)
        case fixedPrice(String)
    }

    public init(code: String, discount: Int, type: OfferCodeType, partner: String?) {
        self.code = code
        self.discount = discount
        self.type = type
        self.partner = partner
    }
}

// MARK: - 用户购买状态和优惠资格

public enum UserSubscriptionStatus {
    case newUser
    case activeSubscriber
    case expiredSubscriber
    case cancelledSubscriber
    case trialUser
}

public enum UserOfferEligibility {
    case eligible(OfferType)
    case ineligible
    case unknown
}

// MARK: - 优惠策略（从 StoreKit 商品查询结构化数据）

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
private extension OfferPeriod {
    /// 把 StoreKit 的订阅周期映射为 UI 无关的 OfferPeriod，保留 value 与 unit。
    init(_ period: Product.SubscriptionPeriod) {
        let unit: OfferPeriod.Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: unit = .day
        }
        self.init(value: max(1, Int(period.value)), unit: unit)
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
public struct OfferStrategy {
    @MainActor public static func newUserFreeTrial(from storeManager: StoreKitManager) -> IntroductoryOffer? {
        for product in storeManager.products {
            if let subscription = product.subscription,
               let introOffer = subscription.introductoryOffer,
               case .freeTrial = introOffer.paymentMode {
                return .freeTrial(period: OfferPeriod(introOffer.period))
            }
        }
        return nil
    }

    @MainActor public static func newUserFirstMonth(from storeManager: StoreKitManager) -> IntroductoryOffer? {
        guard let monthlyProduct = storeManager.product(for: .monthly),
              let subscription = monthlyProduct.subscription,
              let introOffer = subscription.introductoryOffer,
              case .payAsYouGo = introOffer.paymentMode else {
            return nil
        }
        return .payAsYouGo(firstPrice: introOffer.displayPrice, period: OfferPeriod(introOffer.period))
    }

    @MainActor public static func seasonalDiscount(from storeManager: StoreKitManager) -> IntroductoryOffer? {
        guard let yearlyProduct = storeManager.product(for: .yearly),
              let subscription = yearlyProduct.subscription,
              let introOffer = subscription.introductoryOffer,
              case .payUpFront = introOffer.paymentMode else {
            return nil
        }
        return .payUpFront(discountedPrice: introOffer.displayPrice, period: OfferPeriod(introOffer.period))
    }

    @MainActor public static func winBackOffer(from storeManager: StoreKitManager) -> PromotionalOffer? {
        for offer in storeManager.eligiblePromotionalOffers {
            if offer.type == .promotional {
                let duration = offer.period.value
                if duration >= 1 && duration <= 6, let id = offer.id {
                    let discount = calculateDiscountPercentage(from: offer, storeManager: storeManager)
                    return .winBack(id: id, discountPercentage: discount, period: OfferPeriod(offer.period))
                }
            }
        }
        return nil
    }

    @MainActor public static func retentionOffer(from storeManager: StoreKitManager) -> PromotionalOffer? {
        for offer in storeManager.eligiblePromotionalOffers {
            if offer.type == .promotional {
                let duration = offer.period.value
                if duration >= 6 && duration <= 12, let id = offer.id {
                    let discount = calculateDiscountPercentage(from: offer, storeManager: storeManager)
                    return .retention(id: id, discountPercentage: discount, period: OfferPeriod(offer.period))
                }
            }
        }
        return nil
    }

    @MainActor private static func calculateDiscountPercentage(from offer: Product.SubscriptionOffer, storeManager: StoreKitManager) -> Int {
        guard let originalProduct = storeManager.products.first(where: { product in
            product.subscription?.promotionalOffers.contains { $0.id == offer.id } ?? false
        }) else {
            return 10
        }
        let originalPrice = originalProduct.price
        let offerPriceDecimal = offer.price
        if originalPrice > 0 {
            let discountDecimal = (originalPrice - offerPriceDecimal) / originalPrice * 100
            return max(1, min(99, Int(truncating: discountDecimal as NSDecimalNumber)))
        }
        return 10
    }

    @MainActor public static func createOfferCode(code: String, discount: Int, type: OfferCode.OfferCodeType, partner: String?) -> OfferCode {
        return OfferCode(code: code, discount: discount, type: type, partner: partner)
    }
}
