import Foundation
import XCTest
import PurchaseKit

/// 锁定 PurchaseKit 自带的隐私清单（PrivacyInfo.xcprivacy）。
///
/// 公开 Swift Package 使用 UserDefaults（Required Reason API）必须在 SDK 自身提供
/// `PrivacyInfo.xcprivacy` 并由 `Package.swift` 显式声明为 target 资源——不能依赖宿主 app
/// 的 privacy manifest。这些测试以 `PropertyListSerialization` 解析真实清单结构，严格断言
/// Apple 事实边界（不跟踪、不收集数据、仅 UserDefaults + CA92.1），并验证 `Package.swift`
/// 确实把该文件声明为被 `.process` 的 target 资源，避免「文件存在却未打包」。
final class PrivacyManifestTests: XCTestCase {

    // MARK: - Helpers

    private func repoRoot() throws -> URL {
        // Tests/PurchaseKitTests/PrivacyManifestTests.swift → repo root
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 用 PropertyListSerialization 解析源清单，返回顶层字典；解析失败即 fail-fast。
    private func parsedPrivacyInfo() throws -> [String: Any] {
        let url = try repoRoot()
            .appendingPathComponent("Sources/PurchaseKit/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let parsed = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        )
        guard let dictionary = parsed as? [String: Any] else {
            XCTFail("PrivacyInfo.xcprivacy 顶层必须是字典，实际：\(type(of: parsed))")
            return [:]
        }
        return dictionary
    }

    // MARK: - 清单事实断言

    /// 严格断言四项隐私事实：不跟踪、tracking domains 为空、不收集任何数据类型、
    /// 仅声明 UserDefaults 一个 Required Reason API category 且 reason 为 CA92.1。
    func testPrivacyManifestDeclaresSafeUserDefaultsUsage() throws {
        let info = try parsedPrivacyInfo()

        // 1) 不跟踪。
        let tracking = info["NSPrivacyTracking"]
        XCTAssertEqual(
            tracking as? Bool, false,
            "PurchaseKit 不跟踪用户：NSPrivacyTracking 必须为 false，实际：\(String(describing: tracking))"
        )

        // 2) 无 tracking domains。
        let trackingDomains = info["NSPrivacyTrackingDomains"] as? [Any] ?? ["<missing-or-wrong-type>"]
        XCTAssertTrue(
            trackingDomains.isEmpty,
            "PurchaseKit 不连接 tracking domains：NSPrivacyTrackingDomains 必须为空数组"
        )

        // 3) 不收集任何数据类型。
        let collectedTypes = info["NSPrivacyCollectedDataTypes"] as? [Any] ?? ["<missing-or-wrong-type>"]
        XCTAssertTrue(
            collectedTypes.isEmpty,
            "PurchaseKit 不收集数据：NSPrivacyCollectedDataTypes 必须为空数组"
        )

        // 4) 仅声明 UserDefaults 一个 Required Reason API，且 reason 为 CA92.1。
        let accessedAPIs = info["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        XCTAssertFalse(
            accessedAPIs.isEmpty,
            "PurchaseKit 使用 UserDefaults，必须在 NSPrivacyAccessedAPITypes 声明该 Required Reason API"
        )

        // 每个 entry 必须形如 { type, reasons[] }。
        let typedEntries = accessedAPIs.map { entry -> (type: String, reasons: [String]) in
            let type = entry["NSPrivacyAccessedAPIType"] as? String ?? ""
            let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
            return (type, reasons)
        }

        let declaredTypes = Set(typedEntries.map(\.type))
        XCTAssertEqual(
            declaredTypes, ["NSPrivacyAccessedAPICategoryUserDefaults"],
            "PurchaseKit 仅使用 UserDefaults 一个 Required Reason API，实际声明：\(declaredTypes.sorted())"
        )

        let userDefaultsEntry = try XCTUnwrap(
            typedEntries.first { $0.type == "NSPrivacyAccessedAPICategoryUserDefaults" },
            "未找到 NSPrivacyAccessedAPICategoryUserDefaults 声明"
        )
        XCTAssertEqual(
            userDefaultsEntry.reasons, ["CA92.1"],
            "UserDefaults 必须仅声明 CA92.1（访问同一 app 自身的信息），实际：\(userDefaultsEntry.reasons)"
        )
    }

    /// 清单本身必须是合法的 property list（结构可被 PropertyListSerialization 解析）。
    /// 与上一个测试互补：防止清单被改成语法破损或类型错乱的结构。
    func testPrivacyManifestIsParseablePropertyList() throws {
        let url = try repoRoot()
            .appendingPathComponent("Sources/PurchaseKit/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        XCTAssertNoThrow(
            try PropertyListSerialization.propertyList(from: data, options: [], format: &format),
            "PrivacyInfo.xcprivacy 必须是可被 PropertyListSerialization 解析的合法 plist"
        )
    }

    // MARK: - Package.swift 声明断言

    /// `Package.swift` 必须把 `PrivacyInfo.xcprivacy` 显式声明为 PurchaseKit target 的
    /// `.process` 资源——防止「清单文件存在、却未被 SPM 打包进库 bundle」的回归。
    /// 不能用 `.copy`：xcprivacy 是已知 plist 类型，应让 SPM `.process` 正确处理。
    func testPackageSwiftDeclaresPrivacyInfoAsProcessedResource() throws {
        let url = try repoRoot().appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains(".process(\"PrivacyInfo.xcprivacy\")"),
            "Package.swift 必须在 PurchaseKit target 中以 .process(\"PrivacyInfo.xcprivacy\") 声明该清单为资源"
        )
        XCTAssertFalse(
            manifest.contains(".copy(\"PrivacyInfo.xcprivacy\")"),
            "PrivacyInfo.xcprivacy 必须用 .process（已知 plist 类型）声明，不得用 .copy"
        )
    }
}
