import CodexBarCore
import Foundation
import Testing

struct CodexResetAnnouncementParserTests {
    let parser = CodexResetAnnouncementParser()

    // MARK: - Completed reset (past tense)

    @Test
    func `completed reset past tense I evening`() {
        let result = self.parser.parse("I reset usage limits this evening")
        #expect(result == .completed(confidence: 1.0))
    }

    @Test
    func `completed reset usage limits have been reset`() {
        let result = self.parser.parse("usage limits have been reset")
        #expect(result == .completed(confidence: 1.0))
    }

    @Test
    func `completed reset limits are back to normal`() {
        let result = self.parser.parse("limits are back to normal")
        #expect(result == .completed(confidence: 1.0))
    }

    @Test
    func `completed reset with contraction`() {
        let result = self.parser.parse("i've reset usage limits")
        #expect(result == .completed(confidence: 1.0))
    }

    @Test
    func `completed reset with full stop`() {
        let result = self.parser.parse("I reset usage limits.")
        #expect(result == .completed(confidence: 1.0))
    }

    // MARK: - Upcoming reset (future / present-progressive)

    @Test
    func `upcoming reset will reset this evening`() {
        let result = self.parser.parse("I will reset usage limits this evening")
        #expect(result == .upcoming(confidence: 0.85))
    }

    @Test
    func `upcoming reset i will reset`() {
        let result = self.parser.parse("I will reset usage limits")
        #expect(result == .upcoming(confidence: 0.85))
    }

    @Test
    func `upcoming reset contraction`() {
        let result = self.parser.parse("I'll reset usage limits")
        #expect(result == .upcoming(confidence: 0.85))
    }

    @Test
    func `upcoming reset i plan to reset`() {
        let result = self.parser.parse("I plan to reset usage limits tomorrow")
        #expect(result == .upcoming(confidence: 0.85))
    }

    @Test
    func `upcoming reset present progressive`() {
        let result = self.parser.parse("I'm resetting usage limits now")
        #expect(result == .upcoming(confidence: 0.85))
    }

    @Test
    func `upcoming reset present participle`() {
        let result = self.parser.parse("Resetting usage limits as we speak")
        #expect(result == .upcoming(confidence: 0.85))
    }

    // MARK: - Ambiguous reset (waiver language)

    @Test
    func `ambiguous reset waived usage consumption`() {
        let result = self.parser.parse("waived usage consumption")
        #expect(result == .ambiguous(confidence: 0.5))
    }

    @Test
    func `ambiguous reset limits are waived`() {
        let result = self.parser.parse("limits are waived")
        #expect(result == .ambiguous(confidence: 0.5))
    }

    @Test
    func `ambiguous reset usage limits are waived`() {
        let result = self.parser.parse("usage limits are waived")
        #expect(result == .ambiguous(confidence: 0.5))
    }

    // MARK: - False positives: password / auth resets

    @Test
    func `false positive password reset`() {
        #expect(self.parser.parse("I will reset my password") == .none)
        #expect(self.parser.parse("Please reset your password") == .none)
        #expect(self.parser.parse("I forgot my password reset") == .none)
        #expect(self.parser.parse("DM me to reset your password") == .none)
    }

    @Test
    func `false positive token refresh`() {
        #expect(self.parser.parse("I will reset my API token") == .none)
        #expect(self.parser.parse("Please reset your session token") == .none)
    }

    @Test
    func `false positive settings reset`() {
        #expect(self.parser.parse("Reset your settings") == .none)
        #expect(self.parser.parse("I will reset settings to default") == .none)
        #expect(self.parser.parse("Reset the app settings") == .none)
    }

    // MARK: - False positives: rate limit changes

    @Test
    func `false positive rate limit increase`() {
        #expect(self.parser.parse("We increased the rate limits") == .none)
        #expect(self.parser.parse("Rate limits are higher now") == .none)
        #expect(self.parser.parse("Limits have been increased") == .none)
    }

    @Test
    func `false positive rate limit decrease`() {
        #expect(self.parser.parse("We decreased the rate limits") == .none)
        #expect(self.parser.parse("Limits have been lowered") == .none)
    }

    @Test
    func `false positive limit changes without reset`() {
        #expect(self.parser.parse("usage limits changed") == .none)
        #expect(self.parser.parse("usage limits are different now") == .none)
    }

    // MARK: - False positives: system / cache resets

    @Test
    func `false positive cache reset`() {
        #expect(self.parser.parse("I will reset my cache") == .none)
        #expect(self.parser.parse("Reset cache to free up space") == .none)
    }

    @Test
    func `false positive system reset`() {
        #expect(self.parser.parse("System reset needed") == .none)
        #expect(self.parser.parse("The server will reset tonight") == .none)
    }

    // MARK: - False positives: usage without reset

    @Test
    func `false positive usage high no reset`() {
        #expect(self.parser.parse("My usage is very high today") == .none)
        #expect(self.parser.parse("Codex usage is at 90%") == .none)
        #expect(self.parser.parse("I'm hitting usage limits") == .none)
    }

    @Test
    func `false positive ordinary tweet`() {
        #expect(self.parser.parse("Codex is great for coding tasks today") == .none)
        #expect(self.parser.parse("Just shipped a new feature to production!") == .none)
        #expect(self.parser.parse("Twitter is broken again") == .none)
    }

    // MARK: - False positives: other reset-like phrases

    @Test
    func `false positive server restart`() {
        #expect(self.parser.parse("Server will reset at midnight") == .none)
        #expect(self.parser.parse("Systems are resetting overnight") == .none)
    }

    @Test
    func `false positive generic reset`() {
        #expect(self.parser.parse("I'll reset everything") == .none)
        #expect(self.parser.parse("Let's reset and start fresh") == .none)
    }

    // MARK: - Announcements collection

    @Test
    func `announcements parses multiple texts`() {
        let texts = [
            "I will reset usage limits",
            "usage limits have been reset",
            "Codex is great",
        ]
        let results = self.parser.announcements(
            from: texts,
            sourceName: "thsottiaux",
            sourceURL: "https://twitter.com/thsottiaux")
        #expect(results.count == 2)
        #expect(results[0].status == .upcoming)
        #expect(results[1].status == .completed)
    }

    @Test
    func `announcements retains source info`() {
        let texts = ["I will reset usage limits"]
        let results = self.parser.announcements(
            from: texts,
            sourceName: "thsottiaux",
            sourceURL: "https://twitter.com/thsottiaux/status/123")
        #expect(results.count == 1)
        #expect(results[0].sourceName == "thsottiaux")
        #expect(results[0].sourceURL == "https://twitter.com/thsottiaux/status/123")
    }

    @Test
    func `announcements does not retain raw text`() {
        let texts = ["I will reset usage limits"]
        let results = self.parser.announcements(from: texts, sourceName: "thsottiaux", sourceURL: nil)
        #expect(results.count == 1)
        // rawText is intentionally absent from CodexResetAnnouncement to avoid persisting
        // arbitrary external content. The model has no rawText property.
    }

    // MARK: - Timestamp determinism

    @Test
    func `announcements batch shares same observed at`() {
        // All announcements in a single batch share the same observedAt.
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let texts = [
            "I will reset usage limits",
            "usage limits have been reset",
            "Codex is great",
        ]
        let results = self.parser.announcements(
            from: texts,
            sourceName: "thsottiaux",
            sourceURL: nil,
            observedAt: fixedDate)
        #expect(results.count == 2)
        #expect(results[0].observedAt == fixedDate)
        #expect(results[1].observedAt == fixedDate)
    }

    @Test
    func `announcements fixed observed at is stable`() {
        // With a fixed observedAt, repeated calls produce equatable results.
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let texts = ["I will reset usage limits", "usage limits have been reset"]
        let results1 = self.parser.announcements(
            from: texts,
            sourceName: "thsottiaux",
            sourceURL: nil,
            observedAt: fixedDate)
        let results2 = self.parser.announcements(
            from: texts,
            sourceName: "thsottiaux",
            sourceURL: nil,
            observedAt: fixedDate)
        #expect(results1 == results2)
    }

    // MARK: - Multi-occurrence scanning

    @Test
    func `multi occurrence invalid boundary followed by valid`() {
        // "xreset usage limits" fails boundary check but "I reset usage limits" is valid.
        let result = self.parser.parse("xreset usage limits but I reset usage limits")
        #expect(result == .completed(confidence: 1.0))
    }

    @Test
    func `multi occurrence concatenated prefix then valid upcoming`() {
        // "theResetUsageLimits" is concatenated (no spaces) but "I will reset usage limits" is valid.
        let result = self.parser.parse("theResetUsageLimits event fired, then I will reset usage limits")
        #expect(result == .upcoming(confidence: 0.85))
    }

    @Test
    func `multi occurrence concatenated still rejected`() {
        // Pure concatenated text with no valid occurrence should not match.
        #expect(self.parser.parse("theResetUsageLimits event fired") == .none)
        #expect(self.parser.parse("predefined usage limit template") == .none)
    }

    // MARK: - No quota mutation (pure parser guarantee)

    @Test
    func `parser does not mutate quota`() {
        let result1 = self.parser.parse("I will reset usage limits")
        let result2 = self.parser.parse("usage limits have been reset")
        let result3 = self.parser.parse("limits are back to normal")

        #expect(result1 == .upcoming(confidence: 0.85))
        #expect(result2 == .completed(confidence: 1.0))
        #expect(result3 == .completed(confidence: 1.0))

        // Calling again proves determinism / no hidden state mutation
        #expect(self.parser.parse("I will reset usage limits") == .upcoming(confidence: 0.85))
        #expect(self.parser.parse("usage limits have been reset") == .completed(confidence: 1.0))
    }

    // MARK: - No network dependency

    @Test
    func `parser does not require network`() {
        let samples: [(String, CodexResetAnnouncementParser.ParseResult)] = [
            ("I will reset usage limits", .upcoming(confidence: 0.85)),
            ("usage limits have been reset", .completed(confidence: 1.0)),
            ("limits are back to normal", .completed(confidence: 1.0)),
            ("waived usage consumption", .ambiguous(confidence: 0.5)),
            ("Codex is great today", .none),
            ("Reset your password", .none),
        ]
        for (text, expected) in samples {
            #expect(self.parser.parse(text) == expected)
        }
    }

    // MARK: - Edge cases

    @Test
    func `edge case empty string`() {
        #expect(self.parser.parse("") == .none)
    }

    @Test
    func `edge case case insensitive`() {
        #expect(self.parser.parse("I WILL RESET USAGE LIMITS") == .upcoming(confidence: 0.85))
        #expect(self.parser.parse("USAGE LIMITS HAVE BEEN RESET") == .completed(confidence: 1.0))
        #expect(self.parser.parse("Waived Usage Consumption") == .ambiguous(confidence: 0.5))
    }

    @Test
    func `edge case with extra whitespace`() {
        #expect(self.parser.parse("  I will reset usage limits  ") == .upcoming(confidence: 0.85))
        #expect(self.parser.parse("\tI will reset usage limits\t") == .upcoming(confidence: 0.85))
    }

    @Test
    func `edge case multiple reset phrases in one tweet`() {
        // Completed takes priority (first in evaluation order)
        let result = self.parser.parse("I will reset usage limits and limits are back to normal")
        #expect(result == .completed(confidence: 1.0))
    }

    @Test
    func `edge case substring isolation`() {
        #expect(self.parser.parse("theResetUsageLimits event fired") == .none)
        #expect(self.parser.parse("predefined usage limit template") == .none)
    }
}
