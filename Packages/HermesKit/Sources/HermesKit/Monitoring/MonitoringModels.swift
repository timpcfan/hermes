import Foundation

/// The scoped monitoring contract (`_brief/INTERFACES.md`, "Monitoring contract v1"): one
/// snapshot of a Xunxin-only view of the monitor service, its source freshness, today's
/// aggregates, the exits' probes, in-flight requests, the day's recent rows and the link's
/// events.
///
/// Every value a person sees is typed here before it reaches a view, and unknown or missing
/// values stay `nil`: the contract says unknown is JSON null and never a made-up zero. Fields the
/// app doesn't read are ignored, so a newer service can add to the payload.
public struct MonitoringSnapshot: Sendable, Equatable {
    public static let scope = "xunxin"
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var scope: String
    /// The service's business day, `YYYY-MM-DD`.
    public var day: String
    /// The service's UTC offset, `±HH:MM`, used for every server time shown.
    public var timezone: String
    public var snapshotAt: Double?
    public var capabilities: [String]
    public var freshness: MonitoringFreshness?
    public var now: Double?
    public var trace: MonitoringTrace
    public var failover: MonitoringFailover
    public var exits: [MonitoringExit]
    public var today: MonitoringToday
    public var models: MonitoringModels
    public var pricing: MonitoringPricing?
    /// The whole Xunxin account's live balance, when the service sends one. A missing or
    /// malformed object is unknown; it never fails the snapshot that carries it.
    public var quota: MonitoringQuota?
    /// `null` is an unavailable measurement, not a measured empty list.
    public var hasKnownInflight: Bool
    public var inflight: [MonitoringFlight]
    public var recent: [MonitoringFlight]
    public var recentDay: MonitoringRecentDay
    public var events: [MonitoringEvent]

    public init(data: Data) throws {
        guard let root = JSONValue.parse(data), root.objectFields != nil else {
            throw MonitoringContractError.notJSON
        }
        guard let schema = root["schema_version"]?.strictMonitoringInteger else {
            // A server that ignores `scope` answers the website's global payload, which has no
            // schema: never show it as Xunxin's.
            throw MonitoringContractError.legacyPayload
        }
        guard schema == Self.schemaVersion else {
            throw MonitoringContractError.unsupportedSchema(schema)
        }
        guard let scope = root["scope"]?.stringValue else {
            throw MonitoringContractError.legacyPayload
        }
        guard scope == Self.scope else {
            throw MonitoringContractError.wrongScope(scope)
        }
        try validateMonitoringMetadata(root)
        for key in ["trace", "failover", "today", "models", "recent_day"] {
            try requireMonitoringObject(root[key], key)
        }
        for key in ["exits", "recent", "events"] { try requireMonitoringArray(root[key], key) }
        try requireMonitoringArray(root["inflight"], "inflight", nullable: true)
        guard root["snapshot_at"]?.finiteMonitoringNumber != nil else {
            throw MonitoringContractError.malformed("snapshot_at")
        }
        guard case .array(let capabilities) = root["capabilities"],
              capabilities.allSatisfy({ $0.stringValue != nil }) else {
            throw MonitoringContractError.malformed("capabilities")
        }
        for key in ["requests", "ok", "err", "canceled"] {
            try requireMonitoringCount(root["today"]?[key], "today.\(key)")
        }
        try requireMonitoringCount(root["recent_day"]?["n"], "recent_day.n")
        try requireMonitoringArray(root["models"]?["items"], "models.items")
        self.schemaVersion = schema
        self.scope = scope
        day = root["day"]?.stringValue ?? ""
        timezone = root["timezone"]?.stringValue ?? "+00:00"
        snapshotAt = root["snapshot_at"]?.doubleValue
        self.capabilities = root["capabilities"]?.arrayElements.compactMap(\.stringValue) ?? []
        freshness = root["freshness"].flatMap(MonitoringFreshness.init)
        now = root["now"]?.doubleValue
        trace = MonitoringTrace(root["trace"])
        failover = MonitoringFailover(root["failover"])
        exits = root["exits"]?.arrayElements.map(MonitoringExit.init) ?? []
        today = MonitoringToday(root["today"])
        models = MonitoringModels(root["models"])
        pricing = root["pricing"].flatMap(MonitoringPricing.init)
        quota = MonitoringQuota(root["quota"])
        if case .array = root["inflight"] { hasKnownInflight = true } else { hasKnownInflight = false }
        inflight = root["inflight"]?.arrayElements.map(MonitoringFlight.init) ?? []
        recent = root["recent"]?.arrayElements.map(MonitoringFlight.init) ?? []
        recentDay = MonitoringRecentDay(root["recent_day"])
        events = root["events"]?.arrayElements.map(MonitoringEvent.init) ?? []
    }

    /// The server time a snapshot's ages are measured from: `snapshot_at`, else `now`, else nil.
    public var serverTime: Double? { snapshotAt ?? now }
}

/// What the client refuses and why. Each case is a person-facing sentence, because the settings
/// screen shows it as the test's answer.
public enum MonitoringContractError: Error, Equatable, Sendable, LocalizedError {
    /// The address answered with something that isn't JSON at all (HTML, a proxy's page).
    case notJSON
    /// A monitor service older than the scoped contract: no `schema_version` or no `scope`.
    case legacyPayload
    case unsupportedSchema(Int)
    case wrongScope(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .notJSON:
            "That address answered, but not with monitoring data."
        case .legacyPayload:
            "This monitor service doesn't support Xunxin-only statistics. Update the monitor service."
        case .unsupportedSchema(let version):
            "This monitor service speaks contract \(version), which this app doesn't know. Update Hermes or the monitor service."
        case .wrongScope(let scope):
            "That service answered for “\(scope)”, not the Xunxin scope. The app won't show global statistics as Xunxin's."
        case .malformed(let detail):
            "The monitor service answered in a way this app doesn't understand (\(detail))."
        }
    }
}

/// The three collectors' health (`freshness`). A source is only live while its last success is
/// recent; `ok == false` is down, and a missing source is unknown, never live.
public struct MonitoringFreshness: Sendable, Equatable {
    public var trace: MonitoringSourceFreshness
    public var probes: MonitoringSourceFreshness
    public var usage: MonitoringSourceFreshness

    public init(_ value: JSONValue?) {
        trace = MonitoringSourceFreshness(value?["trace"])
        probes = MonitoringSourceFreshness(value?["probes"])
        usage = MonitoringSourceFreshness(value?["usage"])
    }
}

public struct MonitoringSourceFreshness: Sendable, Equatable {
    /// True succeeded, false failed, nil not attempted (or the field is missing).
    public var ok: Bool?
    public var lastSuccessAt: Double?
    public var lastAttemptAt: Double?
    public var error: String?

    public init(_ value: JSONValue?) {
        ok = value?["ok"]?.boolValue
        lastSuccessAt = value?["last_success_at"]?.doubleValue
        lastAttemptAt = value?["last_attempt_at"]?.doubleValue
        error = value?["error"]?.stringValue
    }
}

public struct MonitoringTrace: Sendable, Equatable {
    public var ok: Bool?
    public var error: String?

    public init(_ value: JSONValue?) {
        ok = value?["ok"]?.boolValue
        error = value?["err"]?.stringValue
    }
}

public struct MonitoringFailover: Sendable, Equatable {
    public var reachable: Bool?
    public var lastUsed: String?
    public var tunnels: Int?

    public init(_ value: JSONValue?) {
        reachable = value?["reachable"]?.boolValue
        lastUsed = value?["last_used"]?.stringValue ?? value?["lastUsed"]?.stringValue
        tunnels = value?["tunnels"]?.integerValue
    }
}

public struct MonitoringProbeSample: Sendable, Equatable, Identifiable {
    /// Epoch seconds when the probe ran.
    public var at: Double
    /// The probe's latency, or nil when it failed.
    public var milliseconds: Double?

    public var id: Double { at }

    public init(at: Double, milliseconds: Double?) {
        self.at = at
        self.milliseconds = milliseconds
    }

    init(_ value: JSONValue) {
        // The baseline writes `[epoch, ms|null]`; an object is tolerated for a newer service.
        if let pair = value.arrayElements.first, value.arrayElements.count >= 2 {
            at = pair.doubleValue ?? 0
            milliseconds = value.arrayElements[1].doubleValue
        } else {
            at = value["at"]?.doubleValue ?? value["t"]?.doubleValue ?? 0
            milliseconds = value["ms"]?.doubleValue
        }
    }
}

public struct MonitoringExit: Sendable, Equatable, Identifiable {
    public var name: String
    public var role: String
    public var egress: String?
    public var host: String?
    public var address: String?
    /// The last probe: true reachable, false not, nil unknown.
    public var ok: Bool?
    public var milliseconds: Double?
    public var consecutiveFailures: Int?
    public var lastChange: Double?
    public var tunnels: Int?
    /// Requests the exit carried today, inferred from the tunnel log.
    public var servedToday: Int
    public var history: [MonitoringProbeSample]

    public var id: String { name }

    public init(_ value: JSONValue) {
        name = value["name"]?.stringValue ?? "?"
        role = value["role"]?.stringValue ?? ""
        egress = value["egress"]?.stringValue
        host = value["host"]?.stringValue
        address = value["addr"]?.stringValue
        ok = value["ok"]?.boolValue
        milliseconds = value["ms"]?.doubleValue
        consecutiveFailures = value["consec_fail"]?.integerValue
        lastChange = value["last_change"]?.doubleValue
        tunnels = value["tunnels"]?.integerValue
        servedToday = value["served_today"]?.integerValue ?? 0
        history = value["hist"]?.arrayElements.map(MonitoringProbeSample.init) ?? []
    }

    /// The newest probe sample that has a latency.
    public var latestSample: MonitoringProbeSample? { history.last { $0.milliseconds != nil } }
}

public struct MonitoringToday: Sendable, Equatable {
    public var requests: Int
    public var ok: Int
    public var error: Int
    public var canceled: Int
    public var failovers: Int
    public var inputTokens: Double?
    public var outputTokens: Double?
    public var cacheRead: Double?
    public var cacheWrite: Double?
    public var reasoning: Double?
    public var cost: Double?
    public var pricedRequests: Int
    public var unknownCosts: Int
    /// Median first token, milliseconds, over successful measurable requests.
    public var ttftP50: Double?
    public var tpsP50: Double?
    public var tpsSamples: Int

    public init(_ value: JSONValue?) {
        requests = value?["requests"]?.integerValue ?? 0
        ok = value?["ok"]?.integerValue ?? 0
        error = value?["err"]?.integerValue ?? 0
        canceled = value?["canceled"]?.integerValue ?? 0
        failovers = value?["failovers"]?.integerValue ?? 0
        inputTokens = value?["in"]?.doubleValue
        outputTokens = value?["out"]?.doubleValue
        cacheRead = value?["cache_read"]?.doubleValue
        cacheWrite = value?["cache_write"]?.doubleValue
        reasoning = value?["reasoning"]?.doubleValue
        cost = value?["cost"]?.doubleValue
        pricedRequests = value?["cost_n"]?.integerValue ?? 0
        unknownCosts = value?["cost_miss"]?.integerValue ?? value?["cost_unknown"]?.integerValue ?? 0
        ttftP50 = value?["ttft_p50"]?.doubleValue
        tpsP50 = value?["tps_p50"]?.doubleValue
        tpsSamples = value?["tps_n"]?.integerValue ?? 0
    }

    /// `cache_read / (uncached input + cache_read + cache_write)`. Nil when nothing was read:
    /// a day with no measurable input isn't a 0% cache hit.
    public var cacheHitRate: Double? {
        let read = cacheRead ?? 0
        let total = (inputTokens ?? 0) + read + (cacheWrite ?? 0)
        guard total > 0 else { return nil }
        return read / total
    }
}

public struct MonitoringModels: Sendable, Equatable {
    public var bucketCount: Int
    /// The width of each bucket in hours, as sent by the service.
    public var bucketHours: Int
    public var items: [MonitoringModelItem]

    public init(_ value: JSONValue?) {
        bucketCount = value?["buckets"]?.integerValue ?? 8
        bucketHours = value?["bucket_hours"]?.integerValue ?? 3
        items = value?["items"]?.arrayElements.map(MonitoringModelItem.init) ?? []
    }
}

public struct MonitoringModelItem: Sendable, Equatable, Identifiable {
    public var key: String
    public var name: String
    public var requests: Int
    public var ok: Int
    public var error: Int
    public var canceled: Int
    public var cost: Double?
    public var pricedRequests: Int
    public var unknownCosts: Int
    public var ttftP50: Double?
    public var ttftP90: Double?
    public var tpsP50: Double?
    public var tpsP90: Double?
    public var cacheHitRate: Double?
    public var buckets: [MonitoringModelBucket]

    public var id: String { key }

    public init(_ value: JSONValue) {
        key = value["key"]?.stringValue ?? value["name"]?.stringValue ?? "?"
        name = value["name"]?.stringValue ?? key
        requests = value["n"]?.integerValue ?? 0
        ok = value["ok"]?.integerValue ?? 0
        error = value["err"]?.integerValue ?? 0
        canceled = value["cxl"]?.integerValue ?? value["canceled"]?.integerValue ?? 0
        cost = value["cost"]?.doubleValue
        pricedRequests = value["cost_n"]?.integerValue ?? 0
        unknownCosts = value["cost_unknown"]?.integerValue ?? value["cost_miss"]?.integerValue ?? 0
        ttftP50 = value["ttft"]?.doubleValue ?? value["ttft_p50"]?.doubleValue
        ttftP90 = firstNumber(value, ["ttft_p90", "p90_ttft", "ttftP90"])
        tpsP50 = value["tps"]?.doubleValue ?? value["tps_p50"]?.doubleValue
        tpsP90 = firstNumber(value, ["tps_p90", "p90_tps", "tpsP90"])
        cacheHitRate = value["hit"]?.doubleValue
        buckets = value["buckets"]?.arrayElements.map(MonitoringModelBucket.init) ?? []
    }

    /// The day's estimated cost divided by the requests it could price, or nil when none could.
    public var averageCost: Double? {
        guard let cost, pricedRequests > 0 else { return nil }
        return cost / Double(pricedRequests)
    }
}

public struct MonitoringModelBucket: Sendable, Equatable, Identifiable {
    /// The bucket's first hour: 0, 3, 6 … 21.
    public var hour: Int
    public var requests: Int
    public var ok: Int
    public var error: Int
    public var canceled: Int
    public var cost: Double?
    public var pricedRequests: Int
    public var ttftP50: Double?
    public var ttftP90: Double?
    public var tpsP50: Double?
    public var tpsP90: Double?

    public var id: Int { hour }

    public init(_ value: JSONValue) {
        hour = value["h"]?.integerValue ?? value["hour"]?.integerValue ?? 0
        requests = value["n"]?.integerValue ?? 0
        ok = value["ok"]?.integerValue ?? 0
        error = value["err"]?.integerValue ?? 0
        canceled = value["cxl"]?.integerValue ?? value["canceled"]?.integerValue ?? 0
        cost = value["cost"]?.doubleValue
        pricedRequests = value["cost_n"]?.integerValue ?? 0
        ttftP50 = value["ttft"]?.doubleValue ?? value["ttft_p50"]?.doubleValue
        ttftP90 = firstNumber(value, ["ttft_p90", "p90_ttft", "ttftP90"])
        tpsP50 = value["tps"]?.doubleValue ?? value["tps_p50"]?.doubleValue
        tpsP90 = firstNumber(value, ["tps_p90", "p90_tps", "tpsP90"])
    }

    /// `00–03`, in the service's business day.
    public var label: String {
        String(format: "%02d–%02d", hour, (hour + 3) % 24)
    }

    public var hasSamples: Bool { requests > 0 }
}

public struct MonitoringPricing: Sendable, Equatable {
    /// Epoch seconds of the last pricing update; nil when unavailable.
    public var at: Double?
    public var error: String?
    public var models: Int

    public init(_ value: JSONValue) {
        at = value["at"]?.doubleValue
        error = value["err"]?.stringValue
        models = value["n"]?.integerValue ?? 0
    }
}

/// The account's real deducted balance (`quota` on either snapshot). Amounts are strict JSON
/// numbers: a boolean, string, NaN or infinity is unknown, never a balance. A missing or
/// malformed object reads as nil so an older payload still decodes.
public struct MonitoringQuota: Sendable, Equatable {
    public var source: String
    public var scope: String
    public var currency: String
    public var balanceUSD: Double?
    public var usedUSD: Double?
    /// Epoch seconds of the last successful read.
    public var updatedAt: Double?
    /// Epoch seconds of the last attempt, successful or not.
    public var lastAttemptAt: Double?
    /// The last attempt's outcome: true succeeded, false failed, nil not attempted.
    public var ok: Bool?
    /// True when the service says the last success is too old, a read failed, or it didn't say.
    public var stale: Bool
    public var errorCode: String?
    public var refreshSeconds: Int
    public var staleAfterSeconds: Double

    /// Nil unless this is the Xunxin account object the app understands.
    public init?(_ value: JSONValue?) {
        guard let value, value.objectFields != nil,
              value["source"]?.stringValue == "xunxin_account",
              value["scope"]?.stringValue == "account",
              value["currency"]?.stringValue == "USD" else { return nil }
        source = "xunxin_account"
        scope = "account"
        currency = "USD"
        balanceUSD = value["balance_usd"]?.finiteMonitoringNumber
        usedUSD = value["used_usd"]?.finiteMonitoringNumber
        updatedAt = value["updated_at"]?.finiteMonitoringNumber.flatMap { $0 > 0 ? $0 : nil }
        lastAttemptAt = value["last_attempt_at"]?.finiteMonitoringNumber.flatMap { $0 > 0 ? $0 : nil }
        ok = value["ok"]?.boolValue
        stale = value["stale"]?.boolValue ?? true
        errorCode = value["error"]?.stringValue
        let refresh = value["refresh_seconds"]?.strictMonitoringInteger
        refreshSeconds = refresh.map { max(1, $0) } ?? 60
        let after = value["stale_after_seconds"]?.finiteMonitoringNumber
        staleAfterSeconds = after.map { $0 > 0 ? $0 : 180 } ?? 180
    }

    public var errorKind: MonitoringQuotaError? {
        errorCode.flatMap(MonitoringQuotaError.init(rawValue:))
    }

    public var hasValues: Bool { balanceUSD != nil || usedUSD != nil }

    /// What the overview may claim. A successful value is live only while it is the service's
    /// own `stale == false`, has a success time within the service's threshold, and the app's
    /// transport still carries a current receipt.
    public func state(serverTime: Double?, transportIsCurrent: Bool) -> MonitoringSourceState {
        guard transportIsCurrent else { return hasValues ? .stale : .unknown }
        guard ok == true, let updatedAt else {
            if hasValues { return .stale }
            return ok == false ? .down : .unknown
        }
        guard let serverTime else { return .unknown }
        let age = max(0, serverTime - updatedAt)
        if stale || age > staleAfterSeconds { return .stale }
        return .live
    }
}

public enum MonitoringQuotaError: String, Sendable, Equatable {
    case notConfigured = "not_configured"
    case authFailed = "auth_failed"
    case timeout
    case unavailable
    case invalidResponse = "invalid_response"
}

/// One request: in flight, or finished and in the day's list. The baseline's field names are
/// kept; `nil` is unknown, never zero.
public struct MonitoringFlight: Sendable, Equatable, Identifiable {
    public var id: String
    /// `trace` for an in-flight request, `usage` for a finished one.
    public var source: String?
    /// The ISO time the request ended (or its trace's last update).
    public var time: String?
    public var start: Double?
    public var end: Double?
    public var agent: String?
    public var agentRaw: String?
    public var provider: String?
    public var providerName: String?
    public var requestedModel: String?
    public var model: String?
    public var servedModel: String?
    public var effort: String?
    public var stop: String?
    public var done: Bool
    public var status: Int?
    public var ok: Bool?
    public var error: String?
    public var milliseconds: Double?
    public var ttft: Double?
    /// Uncached input tokens.
    public var inputTokens: Double?
    public var outputTokens: Double?
    public var cacheRead: Double?
    public var cacheWrite: Double?
    public var reasoning: Double?
    public var cacheHitRate: Double?
    public var cost: Double?
    public var costMode: String?
    public var costParts: MonitoringCostParts?
    public var tps: Double?
    public var tpsFloor: Bool
    public var tpsNow: Double?
    public var tpsLive: Bool
    public var answering: Bool
    public var exit: String?
    public var detour: [String]

    public init(_ value: JSONValue) {
        id = value["id"]?.stringValue ?? value["id"]?.doubleValue.flatMap { number in
            guard number.rounded(.towardZero) == number, let id = Int64(checking: number) else { return nil }
            return String(id)
        } ?? "?"
        source = value["src"]?.stringValue
        time = value["t"]?.stringValue
        start = value["start"]?.doubleValue
        end = value["end"]?.doubleValue
        agent = value["agent"]?.stringValue
        agentRaw = value["agent_raw"]?.stringValue
        provider = value["provider"]?.stringValue
        providerName = value["pname"]?.stringValue
        requestedModel = value["req_model"]?.stringValue
        model = value["model"]?.stringValue
        servedModel = value["served"]?.stringValue
        effort = value["effort"]?.stringValue
        stop = value["stop"]?.stringValue
        done = value["done"]?.boolValue ?? (value["end"] != nil)
        status = value["status"]?.integerValue
        ok = value["ok"]?.boolValue
        error = value["err"]?.stringValue
        milliseconds = value["ms"]?.doubleValue
        ttft = value["ttft"]?.doubleValue
        inputTokens = value["in"]?.doubleValue
        outputTokens = value["out"]?.doubleValue
        cacheRead = value["cache"]?.doubleValue ?? value["cache_read"]?.doubleValue
        cacheWrite = value["cache_write"]?.doubleValue
        reasoning = value["reasoning"]?.doubleValue
        cacheHitRate = value["hit"]?.doubleValue
        cost = value["cost"]?.doubleValue
        costMode = value["cost_mode"]?.stringValue
        costParts = value["cost_parts"].flatMap(MonitoringCostParts.init)
        tps = value["tps"]?.doubleValue
        tpsFloor = value["tps_floor"]?.boolValue ?? false
        tpsNow = value["tps_now"]?.doubleValue
        tpsLive = value["tps_live"]?.boolValue ?? false
        answering = value["answering"]?.boolValue ?? false
        exit = value["exit"]?.stringValue
        detour = value["detour"]?.arrayElements.compactMap(\.stringValue) ?? []
    }

    /// A finished request's outcome: 499 is the caller cancelling, separately from a failure.
    public var outcome: MonitoringRequestOutcome {
        if !done { return .inFlight }
        switch status {
        case 499: return .cancelled
        case 200: return .success
        case .some(let status) where status >= 400: return .failed
        case .some: return ok == true ? .success : .failed
        case nil: return ok == true ? .success : (ok == false ? .failed : .unknown)
        }
    }

    /// The model the request actually ran on, else the one asked for.
    public var displayModel: String { model ?? requestedModel ?? servedModel ?? "—" }

    /// How long the request ran, in seconds: the finished total, or from its start to `now` while
    /// it's still in flight.
    public func elapsedSeconds(now: Double?) -> Double? {
        if let milliseconds { return milliseconds / 1000 }
        guard let start, let now, now >= start else { return nil }
        return now - start
    }

    /// Whether the body speed is a measured value or a floor (`≥`).
    public var speedText: String? {
        guard let tps else { return nil }
        let number = tps.formatted(.number.precision(.fractionLength(1)))
        return tpsFloor ? "≥\(number)" : number
    }

    /// The cache read share of everything the model was sent.
    public var computedCacheHitRate: Double? {
        if let cacheHitRate { return cacheHitRate }
        let read = cacheRead ?? 0
        let total = (inputTokens ?? 0) + read + (cacheWrite ?? 0)
        guard total > 0 else { return nil }
        return read / total
    }
}

public struct MonitoringCostParts: Sendable, Equatable {
    public var input: Double?
    public var output: Double?
    public var cacheRead: Double?
    public var cacheWrite: Double?

    public init(_ value: JSONValue) {
        input = value["in"]?.doubleValue
        output = value["out"]?.doubleValue
        cacheRead = value["cache_read"]?.doubleValue
        cacheWrite = value["cache_write"]?.doubleValue
    }
}

public enum MonitoringRequestOutcome: String, Sendable, Equatable {
    case success, failed, cancelled, inFlight, unknown
}

public struct MonitoringRecentDay: Sendable, Equatable {
    public var day: String?
    /// The number of scoped completed rows now.
    public var count: Int
    /// The global append-position high-water mark; stable while other traffic arrives.
    public var upto: Int?

    public init(_ value: JSONValue?) {
        day = value?["day"]?.stringValue
        count = value?["n"]?.integerValue ?? 0
        upto = value?["upto"]?.integerValue
    }
}

public struct MonitoringEvent: Sendable, Equatable, Identifiable {
    public var kind: String
    /// Epoch seconds, from `epoch` or the event's ISO `t`.
    public var at: Double?
    public var timeText: String
    public var exit: String?
    public var message: String

    public var id: String { "\(at ?? 0)-\(kind)-\(message)" }

    public init(_ value: JSONValue) {
        kind = value["kind"]?.stringValue ?? "event"
        timeText = value["t"]?.stringValue ?? ""
        at = value["epoch"]?.doubleValue ?? MonitoringTime.epoch(fromISO: timeText)
        exit = value["exit"]?.stringValue
        message = value["msg"]?.stringValue ?? ""
    }
}

/// One page of the day's completed requests, scoped before filtering, sorting and paging
/// (`GET /api/recent?scope=xunxin`). The scoped metadata is repeated on the root.
public struct MonitoringRecentPage: Sendable, Equatable {
    public var schemaVersion: Int
    public var scope: String
    public var timezone: String
    public var day: String
    /// Scoped rows within the frozen point.
    public var dayCount: Int
    /// The scoped rows now.
    public var nowCount: Int
    public var upto: Int
    /// Scope-eligible rows after the frozen point that match the filters.
    public var newer: Int
    public var newerAll: Int
    public var total: Int
    public var costSum: Double?
    public var pricedCount: Int
    public var unpricedCount: Int
    public var dayCost: Double?
    public var page: Int
    public var size: Int
    public var pages: Int
    public var sort: String
    public var items: [MonitoringFlight]
    public var milliseconds: Double?

    public init(data: Data) throws {
        guard let root = JSONValue.parse(data), root.objectFields != nil else {
            throw MonitoringContractError.notJSON
        }
        guard let schema = root["schema_version"]?.strictMonitoringInteger else {
            throw MonitoringContractError.legacyPayload
        }
        guard schema == MonitoringSnapshot.schemaVersion else {
            throw MonitoringContractError.unsupportedSchema(schema)
        }
        guard let scope = root["scope"]?.stringValue else {
            throw MonitoringContractError.legacyPayload
        }
        guard scope == MonitoringSnapshot.scope else {
            throw MonitoringContractError.wrongScope(scope)
        }
        try validateMonitoringMetadata(root)
        for key in ["n_day", "n_now", "upto", "newer", "newer_all", "total", "cost_n", "cost_none", "page", "size", "pages"] {
            try requireMonitoringCount(root[key], key)
        }
        guard let page = root["page"]?.strictMonitoringInteger, page >= 1,
              let size = root["size"]?.strictMonitoringInteger, (1...200).contains(size),
              root["sort"]?.stringValue != nil else {
            throw MonitoringContractError.malformed("pagination")
        }
        try requireMonitoringArray(root["items"], "items")
        schemaVersion = schema
        self.scope = scope
        timezone = root["timezone"]?.stringValue ?? "+00:00"
        day = root["day"]?.stringValue ?? ""
        dayCount = root["n_day"]?.integerValue ?? 0
        nowCount = root["n_now"]?.integerValue ?? 0
        upto = root["upto"]?.integerValue ?? 0
        newer = root["newer"]?.integerValue ?? 0
        newerAll = root["newer_all"]?.integerValue ?? 0
        total = root["total"]?.integerValue ?? 0
        costSum = root["cost_sum"]?.doubleValue
        pricedCount = root["cost_n"]?.integerValue ?? 0
        unpricedCount = root["cost_none"]?.integerValue ?? 0
        dayCost = root["day_cost"]?.doubleValue
        self.page = root["page"]?.integerValue ?? 1
        self.size = root["size"]?.integerValue ?? 0
        pages = root["pages"]?.integerValue ?? 1
        sort = root["sort"]?.stringValue ?? "new"
        items = root["items"]?.arrayElements.map(MonitoringFlight.init) ?? []
        milliseconds = root["ms"]?.doubleValue
    }
}

// MARK: - Required endpoint structure

private func validateMonitoringMetadata(_ root: JSONValue) throws {
    guard root["error"] == nil || root["error"] == .null else {
        throw MonitoringContractError.malformed("error envelope")
    }
    guard let day = root["day"]?.stringValue, day.utf8.count == 10,
          day.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil else {
        throw MonitoringContractError.malformed("day")
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .gmt
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: day), formatter.string(from: date) == day else {
        throw MonitoringContractError.malformed("day")
    }
    guard let timezone = root["timezone"]?.stringValue, MonitoringTime.offsetSeconds(timezone) != nil else {
        throw MonitoringContractError.malformed("timezone")
    }
}

private func requireMonitoringObject(_ value: JSONValue?, _ field: String) throws {
    guard value?.objectFields != nil else { throw MonitoringContractError.malformed(field) }
}

private func requireMonitoringArray(_ value: JSONValue?, _ field: String, nullable: Bool = false) throws {
    if nullable, value == .null { return }
    guard case .array(let elements) = value, elements.allSatisfy({ $0.objectFields != nil }) else {
        throw MonitoringContractError.malformed(field)
    }
}

private func requireMonitoringCount(_ value: JSONValue?, _ field: String) throws {
    guard let count = value?.strictMonitoringInteger, count >= 0 else {
        throw MonitoringContractError.malformed(field)
    }
}

// MARK: - Tolerant JSON reading

extension JSONValue {
    var strictMonitoringInteger: Int? {
        guard case .number(let value) = self, value.rounded(.towardZero) == value else { return nil }
        return Int(checking: value)
    }

    var finiteMonitoringNumber: Double? {
        guard case .number(let value) = self, value.isFinite else { return nil }
        return value
    }

    var objectFields: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    var arrayElements: [JSONValue] {
        if case .array(let value) = self { value } else { [] }
    }

    /// A count or token tally. Values the service sends as strings are read too; non-finite and
    /// out-of-range numbers stay nil rather than stopping the app (`JSONValue.truncatedIntValue`).
    var integerValue: Int? { truncatedIntValue }
}

/// The first present numeric key, for a field a newer service renamed.
private func firstNumber(_ value: JSONValue, _ keys: [String]) -> Double? {
    for key in keys {
        if let number = value[key]?.doubleValue { return number }
    }
    return nil
}
