import Foundation
import StoreKit

/// The verified fields consumed by the delivery/refresh commit. No public construction or authorization API.
@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
struct EntitlementTransaction {
    let productID: String
    let productType: Product.ProductType
    var expirationDate: Date? = nil
    var revocationDate: Date? = nil
    var isUpgraded = false
    var isTrial = false
    var transaction: Transaction? = nil
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
extension VerificationResult where SignedType == Transaction {
    func mapEntitlement() -> Result<EntitlementTransaction, Error> {
        func fields(_ transaction: Transaction) -> EntitlementTransaction {
            EntitlementTransaction(
                productID: transaction.productID, productType: transaction.productType,
                expirationDate: transaction.expirationDate, revocationDate: transaction.revocationDate,
                isUpgraded: transaction.isUpgraded, isTrial: transaction.offerType == .introductory,
                transaction: transaction
            )
        }
        switch self {
        case .verified(let transaction): return .success(fields(transaction))
        case .unverified: return .failure(StoreError.failedVerification)
        }
    }
}
