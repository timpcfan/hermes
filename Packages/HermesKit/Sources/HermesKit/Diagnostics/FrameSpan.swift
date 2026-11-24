#if DEBUG
import Foundation

/// Debug builds only: what the main thread did between two marks of the frame log
/// (`-HERMES_FRAME_LOG`, docs/development.md, Performance check), from the display link's ticks:
/// how much of the span it was busy, how many frames took longer than the screen gives one, and how
/// many refreshes went by without a new frame. The frame log prints one `FRAMESPAN` line per span,
/// and the performance run (`Tools/mock-hermes/matrix/perf_run.py`) reads those lines rather than
/// every frame.
public struct FrameSpan: Equatable, Sendable {
    /// Display-link intervals counted.
    public private(set) var frames = 0
    /// Frames whose main-thread work took longer than the refresh period: that frame was late.
    public private(set) var overBudget = 0
    /// Refreshes that passed with no tick: the main thread was still busy when they came.
    public private(set) var missed = 0
    /// The longest interval between two ticks, in milliseconds.
    public private(set) var longest: Double = 0
    /// The shortest refresh period seen, in milliseconds: the screen's rate (60 Hz in a simulator).
    public private(set) var refresh: Double = 0

    public init() {}

    /// One display-link tick: `interval` since the last one, the main thread's CPU time over it, and
    /// the period the screen refreshes at, all in milliseconds.
    public mutating func add(interval: Double, cpu: Double, refresh period: Double) {
        guard interval > 0, period > 0 else { return }
        frames += 1
        if cpu > period { overBudget += 1 }
        // A late tick covers every refresh that went by meanwhile; a little jitter rounds away.
        missed += max(0, Int((interval / period).rounded()) - 1)
        longest = max(longest, interval)
        refresh = refresh == 0 ? period : min(refresh, period)
    }

    /// The span closed at a mark, `wall` and `cpu` milliseconds after the last one (the main
    /// thread's CPU time between the two marks, ticks or not).
    public func summary(wall: Double, cpu: Double) -> Summary {
        Summary(wall: wall, cpu: cpu, frames: frames, overBudget: overBudget, missed: missed, longest: longest, refresh: refresh)
    }

    public struct Summary: Equatable, Sendable {
        public var wall: Double
        public var cpu: Double
        public var frames: Int
        public var overBudget: Int
        public var missed: Int
        public var longest: Double
        public var refresh: Double

        /// The main thread's CPU time over the wall time, in percent. CPU time, unlike wall time,
        /// isn't stretched by a busy machine.
        public var cpuPercent: Double { wall > 0 ? 100 * cpu / wall : 0 }
        /// Late frames out of all frames, in percent.
        public var overBudgetPercent: Double { frames > 0 ? 100 * Double(overBudget) / Double(frames) : 0 }
        /// Missed refreshes out of all the refreshes the span had, in percent.
        public var droppedPercent: Double { frames + missed > 0 ? 100 * Double(missed) / Double(frames + missed) : 0 }

        /// The log line, `key=value` pairs then the two marks: what `perf_run.py` parses.
        public func line(from start: String, to end: String) -> String {
            String(format: "FRAMESPAN wall_ms=%.1f cpu_ms=%.1f cpu_pct=%.2f frames=%d over_budget=%d over_budget_pct=%.2f missed=%d dropped_pct=%.2f longest_ms=%.1f refresh_ms=%.2f",
                   wall, cpu, cpuPercent, frames, overBudget, overBudgetPercent, missed, droppedPercent, longest, refresh)
                + " from=\"\(Self.quoted(start))\" to=\"\(Self.quoted(end))\""
        }

        /// A mark's words with no quote to end the field early.
        private static func quoted(_ event: String) -> String {
            event.replacingOccurrences(of: "\"", with: "'")
        }
    }
}
#endif
