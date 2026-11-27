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

    /// The quota's own freshness, bounded again by this receipt: a quota value can never stay
    /// "live" while the transport or the snapshot receipt has gone stale.
    var quotaState: MonitoringSourceState {
        guard let quota = snapshot.quota else { return .unknown }
        return quota.state(serverTime: agedSnapshot.serverTime, transportIsCurrent: transportIsCurrent)
    }
    var relayState: MonitoringSourceState {
        guard let reachable = snapshot.failover.reachable else { return .unknown }
        return reachable ? qualify(.live) : .down
    }

    /// The account's real spend today and the average of the window's complete days before it.
    /// A missing value stays `—`: the card never turns an unknown into a zero.
    var quotaTodaySpendText: String {
        MonitoringFormat.signedDollars(snapshot.quota?.today?.usedUSD)
    }

    var quotaAverageDailyText: String {
        MonitoringFormat.signedDollars(snapshot.quota?.avgDailyUSD ?? snapshot.quota?.forecast?.avgDailyUSD)
    }

    /// The service's own projection, stated with its basis and its uncertainty. Without one the
    /// card says so — unless the usage read itself failed, where "no spend" would be a claim the
    /// app can't make; the failure line says it instead.
    var quotaForecastText: String? {
        if let forecast = snapshot.quota?.forecast,
           let days = forecast.daysLeft,
           let emptyAt = forecast.projectedEmptyAt {
            let day = MonitoringFormat.monthDay(emptyAt, timezone: snapshot.timezone)
            return statsString("At the last 7 days' pace, about \(MonitoringFormat.days(days)) days until the balance runs out (around \(day)).")
        }
        guard snapshot.quota?.usageErrorKind == nil else { return nil }
        return statsString("No spend in the last 7 days, so there's no forecast.")
    }

    /// The balance's path, or nil when the service sent no history: the card draws no block at
    /// all rather than an empty frame.
    var quotaTrend: MonitoringQuotaTrendSummary? {
        MonitoringQuotaTrendSummary(snapshot.quota?.trend)
    }

    /// The service's depletion day as a calendar date, or nil when it named no readable day.
    var quotaDepletionText: String? {
        guard let day = snapshot.quota?.trend?.depletionDay,
              let text = MonitoringFormat.monthDay(day: day, timezone: snapshot.timezone) else { return nil }
        return statsString("Projected to run out on \(text)")
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
