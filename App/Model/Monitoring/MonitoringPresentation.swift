import Foundation
import HermesKit

/// Claims made from a retained snapshot also age while its transport is quiet. Receipt age is
/// elapsed time, not a comparison between the service clock and the device's timezone/clock.
struct MonitoringPresentation {
    let snapshot: MonitoringSnapshot
    let receivedAt: Date?
    let now: Date
    let state: MonitoringConnectionState
    var receiptAge: TimeInterval? = nil

    private var age: TimeInterval {
        if let receiptAge { return max(0, receiptAge) }
        return receivedAt.map { max(0, now.timeIntervalSince($0)) } ?? .infinity
    }

    private var agedSnapshot: MonitoringSnapshot {
        var result = snapshot
        if let serverTime = snapshot.serverTime, age.isFinite {
            result.snapshotAt = serverTime + age
        }
        return result
    }

    private var transportIsCurrent: Bool {
        guard state.isLive || state.isPolling else { return false }
        let policy = MonitoringFreshnessPolicy.standard
        return age <= (state.isPolling ? policy.pollingStaleAfter : policy.snapshotStaleAfter)
    }

    private func qualify(_ source: MonitoringSourceState) -> MonitoringSourceState {
        source == .live && !transportIsCurrent ? .stale : source
    }

    var traceState: MonitoringSourceState { qualify(MonitoringFreshnessPolicy.standard.traceState(agedSnapshot)) }
    var probesState: MonitoringSourceState { qualify(MonitoringFreshnessPolicy.standard.probesState(agedSnapshot)) }
    var usageState: MonitoringSourceState { qualify(MonitoringFreshnessPolicy.standard.usageState(agedSnapshot)) }
    var relayState: MonitoringSourceState {
        guard let reachable = snapshot.failover.reachable else { return .unknown }
        return reachable ? qualify(.live) : .down
    }

    var canClaimNoInflight: Bool { traceState == .live && snapshot.hasKnownInflight && snapshot.inflight.isEmpty }

    func exitState(_ exit: MonitoringExit) -> MonitoringSourceState {
        guard probesState == .live else { return probesState }
        switch exit.ok {
        case true: return .live
        case false: return .down
        case nil: return .unknown
        }
    }

    func reachability(_ exit: MonitoringExit) -> String {
        guard probesState == .live else {
            switch probesState {
            case .down: return statsString("Probe source unavailable · cached result")
            case .stale: return statsString("Probe source stale · cached result")
            case .unknown: return statsString("Probe freshness unknown · cached result")
            case .live: break
            }
            return statsString("Unknown")
        }
        switch exit.ok {
        case true: return statsString("Reachable")
        case false: return statsString("Unreachable")
        case nil: return statsString("Unknown")
        }
    }

    var recent: [MonitoringFlight] { Array(snapshot.recent.suffix(3).reversed()) }
}

extension MonitoringFlight {
    var statsStart: Double? {
        guard let start, start.isFinite, start >= 0 else { return nil }
        return start
    }
    var statsExit: String {
        exit.map { statsString("via \($0) (inferred)") } ?? statsString("Exit unknown")
    }
}

extension MonitoringExit {
    var statsLatestProbe: String? {
        guard let sample = history.last else { return nil }
        if let milliseconds = sample.milliseconds {
            return statsString("latest \(MonitoringFormat.milliseconds(milliseconds))")
        }
        return statsString("Latest probe failed")
    }
}
