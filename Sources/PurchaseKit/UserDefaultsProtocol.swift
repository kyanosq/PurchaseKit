import Foundation
import os

public protocol UserDefaultsProtocol {
    func set(_ value: Any?, forKey defaultName: String)
    func object(forKey defaultName: String) -> Any?
    func bool(forKey defaultName: String) -> Bool
    func integer(forKey defaultName: String) -> Int
    func double(forKey defaultName: String) -> Double
    func string(forKey defaultName: String) -> String?
    func stringArray(forKey defaultName: String) -> [String]?
    func data(forKey defaultName: String) -> Data?
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: UserDefaultsProtocol {}

public extension UserDefaultsProtocol {
    func setCodable<T: Codable>(_ value: T?, forKey key: String) {
        guard let value else {
            removeObject(forKey: key)
            return
        }
        do {
            set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Logger(subsystem: "PurchaseKit", category: "Persistence")
                .error("Failed to encode cached value for key \(key, privacy: .private)")
        }
    }

    func codable<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Logger(subsystem: "PurchaseKit", category: "Persistence")
                .warning("Failed to decode cached value for key \(key, privacy: .private)")
            return nil
        }
    }
}
