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

    @Test func subtitleIsPlatformProfileAndProjectWhenThereIsOne() {
        #expect(ChatRowSubtitle.text(source: "telegram", profile: "money", project: nil) == "telegram · money")
        #expect(ChatRowSubtitle.text(source: "desktop", profile: "paimon", project: "IB-Robot") == "desktop · paimon · IB-Robot")
        #expect(ChatRowSubtitle.text(source: nil, profile: "paimon", project: nil) == "app · paimon")
        #expect(ChatRowSubtitle.text(source: "slack", profile: "work", project: nil) == "slack · work")
        // Empty pieces are left out, never drawn as a stray separator.
        #expect(ChatRowSubtitle.text(source: "discord", profile: "", project: "  ") == "discord")
        #expect(ChatRowSubtitle.text(source: "", profile: nil, project: nil) == "app")
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
