import Foundation

/// When each chat came back to the top of the inbox's Main region (`docs/inbox.md` §2a): the
/// moment the app saw it start waiting on the person, stop with an error, or finish. Kept per
/// gateway on the device, so a cold launch keeps the order; only chats still listed are kept.
///
/// It records only what it saw change. The first look at a gateway's chats is the baseline: a chat
/// already waiting or stopped when the app opens returns nothing on its own.
public struct InboxReturns: Equatable, Sendable {
    /// What a chat was doing at the last look.
    public enum Phase: Equatable, Sendable {
        /// A turn runs (sending included).
        case working
        /// The turn waits on the person.
        case needsYou
        /// The last turn stopped with an error.
        case failed
    }

    /// A finish waits this long before the chat returns, so a turn that pauses between tool
    /// calls (and shows as idle for a poll) doesn't bounce out of Working and back.
    public static let finishGrace: TimeInterval = 2

    /// The return time per chat key.
    public private(set) var times: [String: Date]
    /// Chats that left Working without a reason to return at once, by when they left.
    public private(set) var leaving: [String: Date] = [:]
    private var last: [String: Phase] = [:]
    private var hasBaseline = false

    public init(times: [String: Date] = [:]) {
        self.times = times
    }

    /// The next moment a finish's grace runs out, for a timer to call `settle(now:)`.
    public var nextDeadline: Date? {
        leaving.values.min().map { $0.addingTimeInterval(Self.finishGrace) }
    }

    /// A new look at what the chats are doing (chats doing nothing are absent). Returns whether
    /// `times` changed.
    @discardableResult
    public mutating func observe(_ phases: [String: Phase], now: Date) -> Bool {
        defer {
            last = phases
            hasBaseline = true
        }
        guard hasBaseline else { return false }
        var changed = false
        for (key, phase) in phases {
            let before = last[key]
            switch phase {
            case .working:
                // Back at work within the grace: it never left.
                leaving[key] = nil
            case .needsYou:
                if before != .needsYou {
                    leaving[key] = nil
                    changed = mark(key, now) || changed
                }
            case .failed:
                if before == .working || before == .needsYou {
                    leaving[key] = nil
                    changed = mark(key, now) || changed
                }
            }
        }
        for (key, before) in last where phases[key] == nil && (before == .working || before == .needsYou) {
            leaving[key] = now
        }
        return settle(now: now) || changed
    }

    /// Finishes whose grace has run out return now, at the moment they left. Returns whether
    /// `times` changed.
    @discardableResult
    public mutating func settle(now: Date) -> Bool {
        var changed = false
        for (key, left) in leaving where now.timeIntervalSince(left) >= Self.finishGrace {
            leaving[key] = nil
            changed = mark(key, left) || changed
        }
        return changed
    }

    /// Keeps only these chats' times (the ones still listed).
    @discardableResult
    public mutating func prune(keeping keys: Set<String>) -> Bool {
        let kept = times.filter { keys.contains($0.key) }
        guard kept.count != times.count else { return false }
        times = kept
        return true
    }

    /// Un-settled by the person: back at the top of Main now.
    public mutating func returned(_ key: String, at date: Date) {
        _ = mark(key, date)
    }

    private mutating func mark(_ key: String, _ date: Date) -> Bool {
        if let old = times[key], old >= date { return false }
        times[key] = date
        return true
    }

    // MARK: On the device

    /// The times as stored, in seconds since 1970 (a small JSON object).
    public func encoded() -> Data? {
        try? JSONEncoder().encode(times.mapValues(\.timeIntervalSince1970))
    }

    /// What `encoded()` wrote; anything unreadable starts empty.
    public static func decoded(_ data: Data?) -> InboxReturns {
        guard let data, let seconds = try? JSONDecoder().decode([String: Double].self, from: data) else { return InboxReturns() }
        return InboxReturns(times: seconds.mapValues(Date.init(timeIntervalSince1970:)))
    }
}
