import Foundation
import StoreKit

// MARK: - StoreKit Service Protocol

/// StoreKit 2 服务的抽象层，用于依赖注入和测试
@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
public protocol StoreKitServiceProtocol: Sendable {
    
    // MARK: - Product Operations
    
    /// 获取指定 ID 的产品列表
    func fetchProducts(for identifiers: Set<String>) async throws -> [Product]
    
    // MARK: - Purchase Operations
    
    /// 购买产品
    func purchase(_ product: Product, options: Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult
    
    // MARK: - Transaction Operations
    
    /// 获取当前的权益事务流
    func currentEntitlements() -> CurrentEntitlementsStream
    
    /// 获取事务更新流
    func transactionUpdates() -> TransactionUpdatesStream
    
    /// 同步 App Store 状态
    func sync() async throws
    
    // MARK: - Verification
    
    /// 验证交易
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T
}

// MARK: - Type Aliases for Streams

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
public typealias CurrentEntitlementsStream = AsyncStream<VerificationResult<Transaction>>

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
public typealias TransactionUpdatesStream = AsyncStream<VerificationResult<Transaction>>

// MARK: - Real Implementation

/// StoreKit 2 的真实实现
@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
public final class RealStoreKitService: StoreKitServiceProtocol {
    
    public init() {}
    
    public func fetchProducts(for identifiers: Set<String>) async throws -> [Product] {
        return try await Product.products(for: identifiers)
    }
    
    public func purchase(_ product: Product, options: Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult {
        if options.isEmpty {
            return try await product.purchase()
        } else {
            return try await product.purchase(options: options)
        }
    }
    
    public func currentEntitlements() -> CurrentEntitlementsStream {
        return AsyncStream { continuation in
            let producer = Task {
                for await result in Transaction.currentEntitlements {
                    if Task.isCancelled { break }
                    continuation.yield(result)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }
    
    public func transactionUpdates() -> TransactionUpdatesStream {
        return AsyncStream { continuation in
            let producer = Task {
                for await result in Transaction.updates {
                    if Task.isCancelled { break }
                    continuation.yield(result)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }
    
    public func sync() async throws {
        try await AppStore.sync()
    }
    
    public func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
}
