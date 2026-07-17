import Foundation
import Testing
@testable import CodexBarCore

/// Regression test for GitHub issue #2200: KeychainAccessGate override data race.
///
/// `KeychainAccessGate.overrideValue` used to be a `nonisolated(unsafe)` static read and
/// written from multiple concurrent paths. This test stresses the synchronized seam.
struct Issue2200KeychainAccessGateRaceTests {

    @Test
    func `concurrent isDisabled reads and writes do not data race`() async {
        let iterations = 10_000

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for toggle in [true, false, true, false] {
                    for _ in 0..<iterations {
                        KeychainAccessGate.isDisabled = toggle
                    }
                }
            }

            group.addTask {
                for _ in 0..<(iterations * 2) {
                    KeychainAccessGate.resetOverrideForTesting()
                }
            }

            group.addTask {
                for _ in 0..<(iterations * 4) {
                    _ = KeychainAccessGate.isDisabled
                }
            }

            group.addTask {
                for _ in 0..<(iterations * 4) {
                    _ = KeychainAccessGate.isDisabled
                }
            }

            await group.waitForAll()
        }
    }
}
