import Foundation

/// Monitoring covers one window's chat; another visible window may still be reading it.
struct MonitoringReadingDemand {
    private var covered: Set<UUID> = []
    mutating func setCovered(_ value: Bool, window: UUID) {
        if value { covered.insert(window) } else { covered.remove(window) }
    }
    func isReading(visibleWindows: Set<UUID>) -> Bool {
        !visibleWindows.subtracting(covered).isEmpty
    }
}

/// A compose tap on Stats must hand off before the Chats-hosted profile panel opens.
struct MonitoringComposeHandoff {
    private(set) var awaitsChats = false
    mutating func begin() { awaitsChats = true }
    mutating func cancel() { awaitsChats = false }
    mutating func arrived(isChats: Bool) -> Bool {
        let opens = awaitsChats && isChats
        awaitsChats = false
        return opens
    }
}
