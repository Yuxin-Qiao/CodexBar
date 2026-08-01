import Foundation
import Testing
@testable import CodexBar

struct SpendActivityLevelsTests {
    @Test
    func `weekday labels follow the selected app language`() {
        let english = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            (1...5).map { SpendActivityWeekday.label(for: $0) }
        }
        let simplifiedChinese = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            (1...5).map { SpendActivityWeekday.label(for: $0) }
        }

        #expect(english == ["Mo", "", "We", "", "Fr"])
        #expect(simplifiedChinese == ["一", "", "三", "", "五"])
    }

    @Test
    func `activity dates follow the selected app language`() {
        let date = Date(timeIntervalSince1970: 1_785_542_400)
        let english = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            SpendActivityDateFormatting.mediumDateString(date)
        }
        let simplifiedChinese = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            SpendActivityDateFormatting.mediumDateString(date)
        }

        #expect(english.contains("Aug"))
        #expect(!english.contains("年"))
        #expect(simplifiedChinese.contains("年"))
    }

    @Test
    func `daily levels stay finite near Int max`() {
        // Token counters can approach Int.max; `value * 4` / `maxValue * 3` would trap while
        // merely rendering the heatmap. The ratio comparison must survive extreme values.
        let values = [0, 1, Int.max / 2, Int.max]
        let levels = SpendActivityLevels.dailyLevels(values)
        // Int.max/2 ÷ Int.max == 0.5 exactly → not > 0.5 → level 2 (ratio > 0.25).
        #expect(levels == [0, 1, 2, 4])
    }

    @Test
    func `daily levels match ratio thresholds`() {
        let levels = SpendActivityLevels.dailyLevels([0, 10, 26, 51, 76, 100])
        // ratio vs max=100: 0→0, 0.1→1, 0.26→2, 0.51→3, 0.76→4, 1.0→4
        #expect(levels == [0, 1, 2, 3, 4, 4])
    }
}
