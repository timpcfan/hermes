import Foundation
import HermesKit
import HermesPush
import Testing

/// The chat row's pure parts (BRIEF ios-tab-layout): the four states, the subtitle and the
/// fallback avatar. The row itself is a view; everything that can be decided without one is here.
@Suite("Chat row presentation")
struct ChatRowPresentationTests {
    @Test func everyActivityLineBecomesOneOfTheFourRowStates() {
        let running: [ActivityLine] = [
            .starting, .thinking, .writing("hello"),
            .tool(symbol: "terminal", title: "Running a command", progress: nil),
            .helpers(2), .routine("Daily digest"), .sending(gateway: "studio"),
        ]
        for line in running {
            #expect(line.chatRowState == .running, "\(line)")
        }
        #expect(ActivityLine.waiting(.approval).chatRowState == .needsYou)
        #expect(ActivityLine.waiting(.question).chatRowState == .needsYou)
        #expect(ActivityLine.waiting(.key).chatRowState == .needsYou)
        #expect(ActivityLine.failed("API Error: safeguards flagged this message").chatRowState
                == .failed(reason: "API Error: safeguards flagged this message"))
    }

    @Test func anIdleChatIsDoneOnlyWhileUnreadThenSaysWhenItEnded() {
        let ended = Date(timeIntervalSince1970: 1_800_000_000)
        let active = ended.addingTimeInterval(-600)
        #expect(ChatRowState(line: nil, isWaiting: false, isUnread: true, endedAt: ended, lastActive: active) == .done)
        #expect(ChatRowState(line: nil, isWaiting: false, isUnread: false, endedAt: ended, lastActive: active) == .ended(at: ended))
        // Hermes without `ended_at`: the last activity is when it ended.
        #expect(ChatRowState(line: nil, isWaiting: false, isUnread: false, endedAt: nil, lastActive: active) == .ended(at: active))
        #expect(ChatRowState(line: nil, isWaiting: false, isUnread: false, endedAt: nil, lastActive: nil) == .ended(at: nil))
    }

    @Test func runningNeedsYouAndFailedDontDependOnTheUnreadMark() {
        for unread in [true, false] {
            #expect(ChatRowState(line: nil, isWaiting: true, isUnread: unread, endedAt: nil, lastActive: nil) == .running)
            #expect(ChatRowState(line: .thinking, isWaiting: false, isUnread: unread, endedAt: nil, lastActive: nil) == .running)
            #expect(ChatRowState(line: .waiting(.approval), isWaiting: false, isUnread: unread, endedAt: nil, lastActive: nil) == .needsYou)
            #expect(ChatRowState(line: .failed("Timed out"), isWaiting: false, isUnread: unread, endedAt: nil, lastActive: nil)
                    == .failed(reason: "Timed out"))
        }
        // A message still going out is running even when the chat's last turn says it is waiting.
        #expect(ChatRowState(line: .waiting(.question), isWaiting: true, isUnread: false, endedAt: nil, lastActive: nil) == .running)
    }

    @Test func endedTimeSaysHowLongAgoInOneShortUnit() {
        let minute: TimeInterval = 60, hour: TimeInterval = 3600, day: TimeInterval = 86_400
        #expect(ChatRowAgo.text(-30) == "now")
        #expect(ChatRowAgo.text(0) == "now")
        #expect(ChatRowAgo.text(59.9) == "now")
        #expect(ChatRowAgo.text(minute) == "1m")
        #expect(ChatRowAgo.text(59 * minute + 59) == "59m")
        #expect(ChatRowAgo.text(2 * hour) == "2h")
        #expect(ChatRowAgo.text(day - 1) == "23h")
        #expect(ChatRowAgo.text(day) == "1d")
        #expect(ChatRowAgo.text(3 * day + 5 * hour) == "3d")
        #expect(ChatRowAgo.text(7 * day) == "1w")
        #expect(ChatRowAgo.text(29 * day) == "4w")
        #expect(ChatRowAgo.text(30 * day) == "1mo")
        #expect(ChatRowAgo.text(364 * day) == "12mo")
        #expect(ChatRowAgo.text(365 * day) == "1y")
        #expect(ChatRowAgo.text(800 * day) == "2y")
    }

    @Test func endedTimeRedrawsExactlyWhenItsWordsChange() {
        let day: TimeInterval = 86_400
        let ages: [TimeInterval] = [-5, 0, 30, 59.5, 60, 61, 3599, 3600, 7300, day - 1, day, 2.5 * day, 6.9 * day,
                                    7 * day, 20 * day, 29.5 * day, 30 * day, 200 * day, 364.5 * day, 365 * day, 1000 * day]
        for age in ages {
            let next = ChatRowAgo.nextChange(after: age)
            #expect(next > age, "\(age)")
            #expect(ChatRowAgo.text(next - 0.5) == ChatRowAgo.text(age), "\(age)")
            #expect(ChatRowAgo.text(next) != ChatRowAgo.text(age), "\(age)")
        }
    }

    @Test func subtitleIsPlatformProfileAndProjectWhenThereIsOne() {
        #expect(ChatRowSubtitle.text(source: "telegram", profile: "money", project: nil) == "telegram · money")
        #expect(ChatRowSubtitle.text(source: "desktop", profile: "paimon", project: "IB-Robot") == "desktop · paimon · IB-Robot")
        #expect(ChatRowSubtitle.text(source: nil, profile: "paimon", project: nil) == "app · paimon")
        #expect(ChatRowSubtitle.text(source: "slack", profile: "work", project: nil) == "slack · work")
        // Empty pieces are left out, never drawn as a stray separator.
        #expect(ChatRowSubtitle.text(source: "discord", profile: "", project: "  ") == "discord")
        #expect(ChatRowSubtitle.text(source: "", profile: nil, project: nil) == "app")
    }

    @Test func modelLineIsTheShortModelName() {
        #expect(ChatRowSubtitle.modelLine(model: "xunxin-default/qwen4-max") == "qwen4-max")
        #expect(ChatRowSubtitle.modelLine(model: "anthropic/claude-sonnet-4.6") == "claude-sonnet-4.6")
    }

    @Test func modelLineIsAbsentWithoutAModel() {
        #expect(ChatRowSubtitle.modelLine(model: nil) == nil)
        #expect(ChatRowSubtitle.modelLine(model: "") == nil)
        #expect(ChatRowSubtitle.modelLine(model: "   ") == nil)
        #expect(ChatRowSubtitle.modelLine(model: "provider/") == "provider")
    }

    @Test func modelLineCutsALongNameAtItsLimit() {
        let short = String(repeating: "a", count: ChatRowSubtitle.modelNameLimit)
        #expect(ChatRowSubtitle.modelLine(model: "provider/\(short)") == short)
        let long = String(repeating: "b", count: ChatRowSubtitle.modelNameLimit + 12)
        let cut = ChatRowSubtitle.modelLine(model: "provider/\(long)")
        #expect(cut == String(repeating: "b", count: ChatRowSubtitle.modelNameLimit) + "…")
        // A model id's provider is dropped before the cut, so its own length never costs a letter.
        let nested = ChatRowSubtitle.modelLine(model: "provider/family/\(long)")
        #expect(nested == String(repeating: "b", count: ChatRowSubtitle.modelNameLimit) + "…")
    }

    @Test func platformsUseTheWordsTheRowsUse() {
        #expect(ChatRowSubtitle.platformName(nil) == "app")
        #expect(ChatRowSubtitle.platformName("api_server") == "app")
        #expect(ChatRowSubtitle.platformName("hermes_app") == "app")
        #expect(ChatRowSubtitle.platformName("desktop") == "desktop")
        #expect(ChatRowSubtitle.platformName("cli") == "terminal")
        #expect(ChatRowSubtitle.platformName("tui") == "terminal")
        #expect(ChatRowSubtitle.platformName("acp") == "editor")
        #expect(ChatRowSubtitle.platformName("cron") == "scheduled")
        #expect(ChatRowSubtitle.platformName("Telegram") == "telegram")
        #expect(ChatRowSubtitle.platformName("slack") == "slack")
    }

    @Test func runningDurationStaysShort() {
        #expect(ChatRowDuration.short(-5) == "0s")
        #expect(ChatRowDuration.short(0) == "0s")
        #expect(ChatRowDuration.short(45) == "45s")
        #expect(ChatRowDuration.short(59.6) == "1m")
        #expect(ChatRowDuration.short(60) == "1m")
        #expect(ChatRowDuration.short(239) == "3m")
        #expect(ChatRowDuration.short(3600) == "1h")
        #expect(ChatRowDuration.short(3900) == "1h 5m")
        #expect(ChatRowDuration.short(7325) == "2h 2m")
    }

    @Test func monogramIsTheFirstLetterUppercased() {
        #expect(ProfileMonogram.initial("paimon") == "P")
        #expect(ProfileMonogram.initial(" work ") == "W")
        #expect(ProfileMonogram.initial("éclair") == "É")
        #expect(ProfileMonogram.initial("") == "?")
        #expect(ProfileMonogram.initial("   ") == "?")
    }

    @Test func monogramColorIsStableAndTheDefaultProfileKeepsItsViolet() {
        #expect(ProfileMonogram.color(for: "paimon") == ProfileMonogram.color(for: "paimon"))
        #expect(ProfileMonogram.color(for: "paimon") != ProfileMonogram.color(for: "money"))
        // The same rule the faces use: the primary profile's untouched face is the violet squircle.
        #expect(ProfileMonogram.color(for: "default") == .defaultViolet)
        let color = ProfileMonogram.color(for: "work")
        #expect((0...1).contains(color.red) && (0...1).contains(color.green) && (0...1).contains(color.blue))
    }
}
