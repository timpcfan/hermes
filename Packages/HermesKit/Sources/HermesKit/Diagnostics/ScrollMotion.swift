#if DEBUG
import Foundation

/// Debug builds only: how the open chat's content moved on screen between frames
/// (`-HERMES_SCROLL_PROBE`, docs/development.md, Performance check), from the rows' tops in the
/// content and the scroll offset: a row's place on screen is its top less the offset, so a chat
/// that moves its offset to keep what's shown still (an earlier page coming in above) reads as no
/// motion. Each sample follows the first row on screen at the sample before, while that row is
/// still there.
public struct ScrollMotion: Equatable, Sendable {
    /// A move on screen bigger than this in one frame is a jump: a fast fling is about 8000 pt a
    /// second, 133 pt a frame at 60 Hz.
    public static let teleport: Double = 400

    public private(set) var samples = 0
    /// Every frame's move added up, in points.
    public private(set) var moved: Double = 0
    /// The biggest move between two samples.
    public private(set) var largestStep: Double = 0
    /// Moves bigger than `teleport` that nothing asked for, while the chat was held: the content
    /// jumped. A jump to the end by design isn't one, and neither is a scroll run's own step.
    public private(set) var teleports = 0
    /// Frames in which a scroll run's own step was bigger than `teleport`: a frame came so late
    /// that the run's speed carried the chat that far at once (3000 pt a second covers 400 pt in
    /// 133 ms). A hitch the reader sees, but not the content jumping: it's compared with the build
    /// before rather than held to zero.
    public private(set) var longSteps = 0
    /// The biggest gap between where a row went and where it should have: while a scroll run
    /// drives the chat, by the run's own step; otherwise nowhere.
    public private(set) var largestDrift: Double = 0
    /// Samples `largestDrift` was read over: frames where the chat was meant to stand still or
    /// move only by the run's step.
    public private(set) var checked = 0

    /// The row followed, and where it was on screen.
    private var anchor: Anchor?

    private struct Anchor: Equatable, Sendable {
        let key: String
        let screen: Double
    }

    public init() {}

    /// One frame: the rows' tops in the content, the content's top edge on screen (`visibleTop`,
    /// in content points: the offset plus the inset over it), the offset, and how far the scroll
    /// run moved the offset since the last sample (`stepped`, 0 when nothing drove it). `held`
    /// says the chat should stay put but for the run's step, so the frame counts toward the drift:
    /// false while it moves by design (a sent message gliding up, the chat following its end).
    public mutating func add(rows: [String: Double], visibleTop: Double, offset: Double, stepped: Double, held: Bool) {
        samples += 1
        if let anchor, let top = rows[anchor.key] {
            let step = (top - offset) - anchor.screen
            moved += abs(step)
            largestStep = max(largestStep, abs(step))
            if held {
                checked += 1
                // The run moving the offset by `stepped` moves the rows by the opposite: what's
                // left is the content moving by itself.
                let unasked = abs(step + stepped)
                if unasked > Self.teleport { teleports += 1 }
                if abs(stepped) > Self.teleport { longSteps += 1 }
                largestDrift = max(largestDrift, unasked)
            }
        }
        anchor = Self.first(in: rows, at: visibleTop).map { Anchor(key: $0.key, screen: $0.top - offset) }
    }

    /// Forgets the row followed: the chat changed (another one opened), so the next sample starts
    /// afresh rather than reading the change as a move.
    public mutating func restart() {
        anchor = nil
    }

    /// A new span, still following the same row.
    public mutating func clearCounts() {
        let anchor = anchor
        self = ScrollMotion()
        self.anchor = anchor
    }

    /// The row holding the content's top edge: the lowest top at or above it, else the highest row.
    static func first(in rows: [String: Double], at visibleTop: Double) -> (key: String, top: Double)? {
        var best: (key: String, top: Double)?
        var highest: (key: String, top: Double)?
        for (key, top) in rows {
            if top <= visibleTop, top > best?.top ?? -.infinity { best = (key, top) }
            if top < highest?.top ?? .infinity { highest = (key, top) }
        }
        return best ?? highest
    }

    /// The log line, `key=value` pairs: what `perf_run.py` parses. `fromEnd` is how far the
    /// chat's end was below the bottom of what's visible at the mark.
    public func line(fromEnd: Double?) -> String {
        String(format: "SCROLLSPAN samples=%d moved_pt=%.1f largest_step_pt=%.1f teleports=%d long_steps=%d checked=%d largest_drift_pt=%.2f",
               samples, moved, largestStep, teleports, longSteps, checked, largestDrift)
            + (fromEnd.map { String(format: " from_end_pt=%.1f", $0) } ?? "")
    }
}
#endif
