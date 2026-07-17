import Foundation
import Testing
@testable import CodexBarCore

/// Regression test for GitHub issue #2200: CookieHeaderCache test override races.
///
/// The previous implementation used `nonisolated(unsafe)` statics for
/// `displayStalenessIntervalOverride` and `displayUnavailableRetryIntervalOverride`,
/// which were written from tests and read from `loadForDisplay` paths. Under parallel
/// Swift Testing these accesses race. This test stresses the new `@TaskLocal` seam.
struct Issue2200CookieHeaderCacheRaceTests {

    @Test
    func `taskLocal display overrides do not data race`() async {
        let iterations = 5_000

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<iterations {
                    try? CookieHeaderCache.withDisplayStalenessIntervalOverrideForTesting(0.05) {
                        _ = CookieHeaderCache.currentDisplayIntervalsForTesting()
                    }
                }
            }

            group.addTask {
                for _ in 0..<iterations {
                    try? CookieHeaderCache.withDisplayUnavailableRetryIntervalOverrideForTesting(0.05) {
                        _ = CookieHeaderCache.currentDisplayIntervalsForTesting()
                    }
                }
            }

            group.addTask {
                for _ in 0..<(iterations * 4) {
                    _ = CookieHeaderCache.currentDisplayIntervalsForTesting()
                }
            }

            group.addTask {
                for _ in 0..<(iterations * 4) {
                    _ = CookieHeaderCache.currentDisplayIntervalsForTesting()
                }
            }

            await group.waitForAll()
        }
    }
}
