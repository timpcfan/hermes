#if DEBUG
import Foundation
import Testing
@testable import HermesKit

/// The frame log's span between two marks and the scroll probe's motion (docs/development.md,
/// Performance check): what the performance run reads and grades.
@Suite("Performance spans: frames, CPU and how the chat moved")
struct PerformanceSpanTests {
    @Test func steadyFramesMissNothing() {
        var span = FrameSpan()
        for _ in 0..<60 { span.add(interval: 16.7, cpu: 2, refresh: 16.67) }
        let summary = span.summary(wall: 1000, cpu: 150)
        #expect(summary.frames == 60)
        #expect(summary.missed == 0)
        #expect(summary.overBudget == 0)
        #expect(summary.cpuPercent == 15)
        #expect(summary.droppedPercent == 0)
        #expect(summary.refresh == 16.67)
    }

    @Test func aLateTickCountsTheRefreshesItCovered() {
        var span = FrameSpan()
        span.add(interval: 16.7, cpu: 3, refresh: 16.67)
        // The main thread held for three refreshes: two went by with no new frame, and the frame
        // itself took longer than one refresh.
        span.add(interval: 50.1, cpu: 40, refresh: 16.67)
        // Jitter just over a period isn't a miss.
        span.add(interval: 20, cpu: 4, refresh: 16.67)
        let summary = span.summary(wall: 86.8, cpu: 47)
        #expect(summary.frames == 3)
        #expect(summary.missed == 2)
        #expect(summary.overBudget == 1)
        #expect(summary.longest == 50.1)
        #expect(summary.droppedPercent == 40)
        #expect(abs(summary.overBudgetPercent - 33.33) < 0.01)
    }

    @Test func aFasterScreenSetsTheBudget() {
        var span = FrameSpan()
        span.add(interval: 8.3, cpu: 10, refresh: 8.33)
        span.add(interval: 16.7, cpu: 1, refresh: 16.67)
        let summary = span.summary(wall: 25, cpu: 11)
        #expect(summary.refresh == 8.33)
        #expect(summary.overBudget == 1)
    }

    @Test func anEmptySpanReadsZero() {
        let summary = FrameSpan().summary(wall: 0, cpu: 0)
        #expect(summary.cpuPercent == 0)
        #expect(summary.overBudgetPercent == 0)
        #expect(summary.droppedPercent == 0)
        // No tick at all: an interval of nothing is ignored.
        var span = FrameSpan()
        span.add(interval: 0, cpu: 1, refresh: 16.67)
        #expect(span.frames == 0)
    }

    @Test func theLineNamesBothMarksWithoutBreakingTheField() {
        var span = FrameSpan()
        span.add(interval: 16.7, cpu: 2, refresh: 16.67)
        let line = span.summary(wall: 16.7, cpu: 2).line(from: "send-here: sending", to: "a \"quoted\" mark")
        #expect(line.hasPrefix("FRAMESPAN wall_ms=16.7 cpu_ms=2.0 cpu_pct=11.98 frames=1 over_budget=0"))
        #expect(line.hasSuffix(" from=\"send-here: sending\" to=\"a 'quoted' mark\""))
    }

    // MARK: Scroll motion

    /// Rows 100 pt tall from the content's top.
    private static func rows(_ keys: ClosedRange<Int>, shift: Double = 0) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: keys.map { ("r\($0)", Double($0) * 100 + shift) })
    }

    @Test func aScrollRunsStepsAreNotDrift() {
        var motion = ScrollMotion()
        var offset = 1000.0
        motion.add(rows: Self.rows(0...30), visibleTop: offset, offset: offset, stepped: 0, held: true)
        for _ in 0..<10 {
            offset -= 50
            motion.add(rows: Self.rows(0...30), visibleTop: offset, offset: offset, stepped: -50, held: true)
        }
        #expect(motion.samples == 11)
        #expect(motion.moved == 500)
        #expect(motion.largestStep == 50)
        #expect(motion.teleports == 0)
        #expect(motion.longSteps == 0)
        #expect(motion.largestDrift == 0)
        #expect(motion.checked == 10)
    }

    @Test func aLateFrameUnderAScrollRunIsALongStepNotAJump() {
        var motion = ScrollMotion()
        motion.add(rows: Self.rows(0...30), visibleTop: 2000, offset: 2000, stepped: 0, held: true)
        // 150 ms late at 3000 pt a second: the run moved the chat 450 pt in one frame, and the
        // rows went exactly as far.
        motion.add(rows: Self.rows(0...30), visibleTop: 1550, offset: 1550, stepped: -450, held: true)
        #expect(motion.largestStep == 450)
        #expect(motion.longSteps == 1)
        #expect(motion.teleports == 0)
        #expect(motion.largestDrift == 0)
    }

    @Test func theContentJumpingUnderAScrollRunIsStillAJump() {
        var motion = ScrollMotion()
        motion.add(rows: Self.rows(0...30), visibleTop: 2000, offset: 2000, stepped: 0, held: true)
        // The run stepped 50 pt up, but the chat moved 700 pt: 650 pt nobody asked for.
        motion.add(rows: Self.rows(0...30), visibleTop: 1300, offset: 1300, stepped: -50, held: true)
        #expect(motion.teleports == 1)
        #expect(motion.longSteps == 0)
        #expect(motion.largestDrift == 650)
        // A late frame and a jump in the same frame: both are counted.
        motion.add(rows: Self.rows(0...30), visibleTop: 300, offset: 300, stepped: -450, held: true)
        #expect(motion.teleports == 2)
        #expect(motion.longSteps == 1)
    }

    @Test func anEarlierPageHeldInPlaceDoesntMove() {
        var motion = ScrollMotion()
        motion.add(rows: Self.rows(10...30), visibleTop: 1200, offset: 1200, stepped: 0, held: true)
        // A page of ten rows comes in above: every row goes 1000 pt down the content, and the chat
        // moves its offset as far, so nothing moves on screen.
        motion.add(rows: Self.rows(0...30).merging(Self.rows(10...30, shift: 1000)) { $1 }, visibleTop: 2200, offset: 2200,
                   stepped: 0, held: true)
        #expect(motion.largestStep == 0)
        #expect(motion.largestDrift == 0)
        #expect(motion.teleports == 0)
    }

    @Test func aPageThatPushesTheRowsDownIsAJump() {
        var motion = ScrollMotion()
        motion.add(rows: Self.rows(10...30), visibleTop: 1200, offset: 1200, stepped: 0, held: true)
        // The same page with the offset left where it was: what was shown drops 1000 pt.
        motion.add(rows: Self.rows(10...30, shift: 1000), visibleTop: 1200, offset: 1200, stepped: 0, held: true)
        #expect(motion.teleports == 1)
        #expect(motion.largestStep == 1000)
        #expect(motion.largestDrift == 1000)
    }

    @Test func movesByDesignCountAsMotionButNotDrift() {
        var motion = ScrollMotion()
        motion.add(rows: Self.rows(0...30), visibleTop: 0, offset: 0, stepped: 0, held: false)
        // A sent message gliding up: 60 pt in a frame, not held.
        motion.add(rows: Self.rows(0...30), visibleTop: 60, offset: 60, stepped: 0, held: false)
        // Sent from far back: the chat goes to its end first, by design.
        motion.add(rows: Self.rows(0...30), visibleTop: 2060, offset: 2060, stepped: 0, held: false)
        #expect(motion.largestStep == 2000)
        #expect(motion.teleports == 0)
        #expect(motion.checked == 0)
        #expect(motion.largestDrift == 0)
    }

    @Test func theFollowedRowGoneStartsAfresh() {
        var motion = ScrollMotion()
        motion.add(rows: ["a": 0, "b": 100], visibleTop: 10, offset: 10, stepped: 0, held: true)
        // "a" dropped out of the window: nothing to compare, the next sample follows "c".
        motion.add(rows: ["c": 5000], visibleTop: 5000, offset: 5000, stepped: 0, held: true)
        #expect(motion.moved == 0)
        #expect(motion.checked == 0)
        motion.add(rows: ["c": 5000], visibleTop: 5003, offset: 5003, stepped: 0, held: true)
        #expect(motion.largestDrift == 3)
    }

    @Test func restartingForgetsTheRowAndClearingKeepsIt() {
        var motion = ScrollMotion()
        motion.add(rows: ["a": 0], visibleTop: 0, offset: 0, stepped: 0, held: true)
        motion.clearCounts()
        #expect(motion.samples == 0)
        motion.add(rows: ["a": 0], visibleTop: 7, offset: 7, stepped: 0, held: true)
        #expect(motion.largestDrift == 7)
        motion.restart()
        motion.add(rows: ["a": 900], visibleTop: 0, offset: 0, stepped: 0, held: true)
        #expect(motion.largestStep == 7)
    }

    @Test func theFirstRowHoldsTheContentsTopEdge() {
        let rows = ["a": 0.0, "b": 100, "c": 250]
        #expect(ScrollMotion.first(in: rows, at: 120)?.key == "b")
        #expect(ScrollMotion.first(in: rows, at: 250)?.key == "c")
        // Above every row (the top padding): the highest one.
        #expect(ScrollMotion.first(in: rows, at: -20)?.key == "a")
        #expect(ScrollMotion.first(in: [:], at: 0) == nil)
    }

    @Test func theScrollLineCarriesTheEndOnlyWhenKnown() {
        var motion = ScrollMotion()
        motion.add(rows: ["a": 0], visibleTop: 0, offset: 0, stepped: 0, held: true)
        #expect(motion.line(fromEnd: 12.04) == "SCROLLSPAN samples=1 moved_pt=0.0 largest_step_pt=0.0 teleports=0 long_steps=0 checked=0 largest_drift_pt=0.00 from_end_pt=12.0")
        #expect(!motion.line(fromEnd: nil).contains("from_end"))
    }
}
#endif
