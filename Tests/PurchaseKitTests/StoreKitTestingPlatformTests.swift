import XCTest

/// `StoreKitTestingPlatform` 的纯逻辑回归：集成层“空探针”必须在「受影响运行时 ∧ 受影响工具链」
/// 时才跳过，在其它任何组合上判为失败。这些用例不启动 StoreKit、不受 FB22237318 跳过影响，始终执行。
final class StoreKitTestingPlatformTests: XCTestCase {

    private func runtime(_ major: Int, _ minor: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }

    private func toolchain(_ major: Int, _ minor: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }

    // MARK: - outcome：探针拿到商品时一律执行

    func testOutcome_RunsNormallyWhenProbeHasProducts() {
        // 探针拿到商品时，无论运行时/工具链是否受影响，都应正常执行集成断言。
        XCTAssertEqual(
            StoreKitTestingPlatform.outcome(
                probeIsEmpty: false,
                runtimeVersion: runtime(26, 5),
                simulator: true,
                toolchainVersion: toolchain(26, 5)
            ),
            .run
        )
        XCTAssertEqual(
            StoreKitTestingPlatform.outcome(
                probeIsEmpty: false,
                runtimeVersion: runtime(18, 0),
                simulator: true,
                toolchainVersion: toolchain(16, 0)
            ),
            .run
        )
    }

    // MARK: - outcome：空探针的跳过/失败判据

    func testOutcome_SkipsOnlyWhenEmptyProbeOnAffectedRuntimeAndAffectedToolchain() {
        // 受影响运行时（iOS 26.5 模拟器）+ 受影响工具链（< 26.6）：唯一允许跳过的组合。
        XCTAssertEqual(
            StoreKitTestingPlatform.outcome(
                probeIsEmpty: true,
                runtimeVersion: runtime(26, 5),
                simulator: true,
                toolchainVersion: toolchain(26, 5)
            ),
            .skipAffected
        )
        XCTAssertEqual(
            StoreKitTestingPlatform.outcome(
                probeIsEmpty: true,
                runtimeVersion: runtime(26, 5),
                simulator: true,
                toolchainVersion: toolchain(26, 0)
            ),
            .skipAffected
        )
    }

    /// 关键回归（Sprint 3）：iOS 26.5 模拟器运行时 + 已修复工具链（Xcode 26.6+）时，
    /// 空探针必须判为**失败**，而不是跳过——否则 Xcode 26.6 会掩盖本应已修复的空商品回归。
    func testOutcome_FailsWhenRuntimeAffectedButToolchainFixed() {
        XCTAssertEqual(
            StoreKitTestingPlatform.outcome(
                probeIsEmpty: true,
                runtimeVersion: runtime(26, 5),
                simulator: true,
                toolchainVersion: toolchain(26, 6)
            ),
            .failRegression
        )
        XCTAssertEqual(
            StoreKitTestingPlatform.outcome(
                probeIsEmpty: true,
                runtimeVersion: runtime(26, 5),
                simulator: true,
                toolchainVersion: toolchain(27, 0)
            ),
            .failRegression
        )
    }

    /// 非受影响运行时上，无论工具链如何，空探针都判为失败。
    func testOutcome_FailsWhenRuntimeUnaffectedRegardlessOfToolchain() {
        XCTAssertEqual(
            StoreKitTestingPlatform.outcome(
                probeIsEmpty: true,
                runtimeVersion: runtime(18, 0),
                simulator: true,
                toolchainVersion: toolchain(26, 5)
            ),
            .failRegression
        )
        XCTAssertEqual(
            StoreKitTestingPlatform.outcome(
                probeIsEmpty: true,
                runtimeVersion: runtime(26, 4),
                simulator: true,
                toolchainVersion: toolchain(26, 5)
            ),
            .failRegression
        )
        // 真机运行时不受影响：即便工具链是受影响的 26.5，空探针也判失败。
        XCTAssertEqual(
            StoreKitTestingPlatform.outcome(
                probeIsEmpty: true,
                runtimeVersion: runtime(26, 5),
                simulator: false,
                toolchainVersion: toolchain(26, 5)
            ),
            .failRegression
        )
    }

    /// 工具链版本无法探测（nil）时的保守处理：仅在受影响运行时上跳过，其余判失败。
    func testOutcome_SkipsWhenToolchainUnknownOnAffectedRuntime() {
        XCTAssertEqual(
            StoreKitTestingPlatform.outcome(
                probeIsEmpty: true,
                runtimeVersion: runtime(26, 5),
                simulator: true,
                toolchainVersion: nil
            ),
            .skipAffected
        )
    }

    func testOutcome_FailsWhenToolchainUnknownOnUnaffectedRuntime() {
        XCTAssertEqual(
            StoreKitTestingPlatform.outcome(
                probeIsEmpty: true,
                runtimeVersion: runtime(18, 0),
                simulator: true,
                toolchainVersion: nil
            ),
            .failRegression
        )
    }

    // MARK: - 维度纯函数

    func testIsAffectedRuntime() {
        XCTAssertTrue(StoreKitTestingPlatform.isAffectedRuntime(runtime(26, 5), simulator: true))
        XCTAssertFalse(StoreKitTestingPlatform.isAffectedRuntime(runtime(26, 4), simulator: true))
        XCTAssertFalse(StoreKitTestingPlatform.isAffectedRuntime(runtime(26, 6), simulator: true))
        XCTAssertFalse(StoreKitTestingPlatform.isAffectedRuntime(runtime(18, 0), simulator: true))
        // 真机一律不受此模拟器专属缺陷影响。
        XCTAssertFalse(StoreKitTestingPlatform.isAffectedRuntime(runtime(26, 5), simulator: false))
    }

    func testIsAffectedToolchain() {
        // 早于 26.6 的工具链受影响。
        XCTAssertTrue(StoreKitTestingPlatform.isAffectedToolchain(toolchain(26, 5)))
        XCTAssertTrue(StoreKitTestingPlatform.isAffectedToolchain(toolchain(26, 0)))
        XCTAssertTrue(StoreKitTestingPlatform.isAffectedToolchain(toolchain(16, 0)))
        // 26.6 及以后已修复。
        XCTAssertFalse(StoreKitTestingPlatform.isAffectedToolchain(toolchain(26, 6)))
        XCTAssertFalse(StoreKitTestingPlatform.isAffectedToolchain(toolchain(27, 0)))
        // 无法探测时保守视为受影响。
        XCTAssertTrue(StoreKitTestingPlatform.isAffectedToolchain(nil))
    }

    // MARK: - 运行时探测自洽（不启动 StoreKit，始终执行）

    /// 受影响判据必须等于「受影响运行时 ∧ 受影响工具链」的组合——证明跳过同时考虑两个维度，
    /// 而非单一维度或“只要探针为空就跳过”的恒真守卫。
    func testAffectedDetectionReflectsRuntimeAndToolchainComposition() {
        let expected = StoreKitTestingPlatform.isAffectedRuntime(
            StoreKitTestingPlatform.currentRuntimeVersion,
            simulator: StoreKitTestingPlatform.currentIsSimulator
        ) && StoreKitTestingPlatform.isAffectedToolchain(
            StoreKitTestingPlatform.currentToolchainVersion
        )
        XCTAssertEqual(
            StoreKitTestingPlatform.isAffectedByStoreKitConfigPushDefect,
            expected,
            "受影响判据必须由运行时与构建工具链共同决定"
        )
    }

    /// 在受影响的 iOS 26.5 模拟器运行时上，整体判据必须为「受影响」，以保留已记录的本地跳过行为；
    /// 同时证明运行时探测真实读取了 OS 版本。非受影响运行时（CI）上为 no-op。
    func testOnAffectedRuntimeDetectionSkipsAsDocumented() {
        #if targetEnvironment(simulator)
        let onAffectedRuntime = StoreKitTestingPlatform.currentRuntimeVersion.majorVersion == 26
            && StoreKitTestingPlatform.currentRuntimeVersion.minorVersion == 5
        if onAffectedRuntime {
            XCTAssertTrue(
                StoreKitTestingPlatform.isAffectedByStoreKitConfigPushDefect,
                "iOS 26.5 模拟器运行时上应判定为受影响（保留已记录的本地跳过）"
            )
        }
        #endif
    }

    /// 在受影响的 iOS 26.5 模拟器运行时上，构建工具链版本应可被探测到（证明 DTPlatformVersion/
    /// DTSDKName 读取生效），且解析为早于 26.6 的版本。非受影响运行时（CI）上为 no-op。
    func testToolchainDetectionSucceedsOnAffectedRuntime() {
        #if targetEnvironment(simulator)
        let onAffectedRuntime = StoreKitTestingPlatform.currentRuntimeVersion.majorVersion == 26
            && StoreKitTestingPlatform.currentRuntimeVersion.minorVersion == 5
        if onAffectedRuntime {
            let detected = StoreKitTestingPlatform.currentToolchainVersion
            XCTAssertNotNil(
                detected,
                "受影响运行时上应能从构建产物探测到工具链版本（DTPlatformVersion/DTSDKName）"
            )
            if let detected {
                XCTAssertTrue(
                    StoreKitTestingPlatform.isAffectedToolchain(detected),
                    "探测到的工具链版本在受影响运行时应早于 26.6"
                )
            }
        }
        #endif
    }
}
