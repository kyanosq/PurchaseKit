import Foundation

public enum PurchaseCatalogError: Error, Equatable {
    case missingSubscriptionMapping(SubscriptionType)
    case missingLifetimeMapping(LifetimePurchase)
}

public struct PurchaseCatalog: Sendable {
    public let subscriptionIDs: [SubscriptionType: String]
    public let lifetimeIDs: [LifetimePurchase: String]

    public init(subscriptionIDs: [SubscriptionType: String], lifetimeIDs: [LifetimePurchase: String]) {
        self.subscriptionIDs = subscriptionIDs
        self.lifetimeIDs = lifetimeIDs
    }

    public var allProductIDs: Set<String> {
        Set(subscriptionIDs.values).union(lifetimeIDs.values)
    }

    public func productID(for type: SubscriptionType) throws -> String {
        guard let id = subscriptionIDs[type] else {
            throw PurchaseCatalogError.missingSubscriptionMapping(type)
        }
        return id
    }

    public func productID(for type: LifetimePurchase) throws -> String {
        guard let id = lifetimeIDs[type] else {
            throw PurchaseCatalogError.missingLifetimeMapping(type)
        }
        return id
    }

    public func lifetimeProductIDs() -> [String] {
        Array(lifetimeIDs.values)
    }

    public func availableSubscriptions(in productIDs: Set<String>) throws -> [SubscriptionType] {
        try SubscriptionType.allCases.filter { productIDs.contains(try productID(for: $0)) }
    }

    public func availableLifetimePurchases(in productIDs: Set<String>) throws -> [LifetimePurchase] {
        try LifetimePurchase.allCases.filter { productIDs.contains(try productID(for: $0)) }
    }
}

public extension SubscriptionType {
    static func from(productID: String, catalog: PurchaseCatalog) -> SubscriptionType? {
        Self.allCases.first { catalog.subscriptionIDs[$0] == productID }
    }
}

public extension LifetimePurchase {
    static func from(productID: String, catalog: PurchaseCatalog) -> LifetimePurchase? {
        Self.allCases.first { catalog.lifetimeIDs[$0] == productID }
    }
}
