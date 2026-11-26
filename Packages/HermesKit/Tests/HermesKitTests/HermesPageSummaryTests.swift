import Foundation
import Testing
@testable import HermesKit

@Suite("Settings: Skills and Tasks summaries")
struct HermesPageSummaryTests {
    let home = URL(string: "http://127.0.0.1:18642")!
    let other = URL(string: "http://127.0.0.1:18643")!

    @Test func skillsCountWhatTheGatewayListed() {
        var catalog = SkillCatalog()
        catalog.received((1...104).map { Skill(name: "skill-\($0)") }, from: home)
        #expect(HermesPageSummary.skills(catalog, from: home, isLoading: false, isOnline: true) == "104 skills")
        catalog.received([Skill(name: "arxiv")], from: home)
        #expect(HermesPageSummary.skills(catalog, from: home, isLoading: false, isOnline: true) == "1 skill")
        catalog.received([], from: home)
        #expect(HermesPageSummary.skills(catalog, from: home, isLoading: false, isOnline: true) == "No skills")
    }

    @Test func skillsSayWhyThereIsNoCountYet() {
        let unread = SkillCatalog()
        #expect(HermesPageSummary.skills(unread, from: home, isLoading: true, isOnline: true) == "Loading…")
        // Online and not asked yet: the row's read is on its way.
        #expect(HermesPageSummary.skills(unread, from: home, isLoading: false, isOnline: true) == "Loading…")
        #expect(HermesPageSummary.skills(unread, from: home, isLoading: false, isOnline: false) == "Not connected")
        var failed = SkillCatalog()
        failed.failed(.invalidResponse("refused"), from: home)
        #expect(HermesPageSummary.skills(failed, from: home, isLoading: false, isOnline: true) == "Couldn't list skills")
    }

    @Test func skillsKeepTheirCountThroughAReloadOrTheGatewayGoingAway() {
        var catalog = SkillCatalog()
        catalog.received([Skill(name: "github-pr"), Skill(name: "arxiv")], from: home)
        #expect(HermesPageSummary.skills(catalog, from: home, isLoading: true, isOnline: true) == "2 skills")
        #expect(HermesPageSummary.skills(catalog, from: home, isLoading: false, isOnline: false) == "2 skills")
        catalog.failed(.invalidResponse("refused"), from: home)
        #expect(HermesPageSummary.skills(catalog, from: home, isLoading: false, isOnline: true) == "2 skills")
        // Another address for the gateway counts its own list, not this one.
        #expect(HermesPageSummary.skills(catalog, from: other, isLoading: false, isOnline: true) == "Loading…")
    }

    @Test func tasksCountEveryTaskAndTheOnesNotPaused() {
        let jobs = (1...5).map { job("t\($0)") }
        var paused = jobs
        paused[0].state = "paused"
        paused[1].enabled = false
        paused[2].state = "paused"
        #expect(HermesPageSummary.tasks(jobs, failed: false, isOnline: true) == "5 tasks · 5 active")
        #expect(HermesPageSummary.tasks(paused, failed: false, isOnline: true) == "5 tasks · 2 active")
        #expect(HermesPageSummary.tasks([jobs[0]], failed: false, isOnline: true) == "1 task · 1 active")
        #expect(HermesPageSummary.tasks([paused[1]], failed: false, isOnline: true) == "1 task · all paused")
        #expect(HermesPageSummary.tasks([], failed: false, isOnline: true) == "No tasks")
        // A list read before stays counted when a later read fails or the gateway goes away.
        #expect(HermesPageSummary.tasks(paused, failed: true, isOnline: false) == "5 tasks · 2 active")
    }

    @Test func tasksSayWhyThereIsNoCountYet() {
        #expect(HermesPageSummary.tasks(nil, failed: false, isOnline: true) == "Loading…")
        #expect(HermesPageSummary.tasks(nil, failed: true, isOnline: true) == "Couldn't load tasks")
        #expect(HermesPageSummary.tasks(nil, failed: false, isOnline: false) == "Not connected")
        #expect(HermesPageSummary.tasks(nil, failed: true, isOnline: false) == "Not connected")
    }

    private func job(_ id: String) -> CronJob {
        CronJob(making: NewCronJob(name: id, schedule: "every day at 07:30", prompt: "Check"), id: id)
    }
}
