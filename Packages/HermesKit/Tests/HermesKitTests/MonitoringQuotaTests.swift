import Foundation
import Testing
@testable import HermesKit

private func quotaSnapshot(_ quota: String? = nil) throws -> MonitoringSnapshot {
    let extra = quota.map { ",\"quota\":\($0)" } ?? ""
    let json = """
    {"schema_version":1,"scope":"xunxin","day":"2026-11-27","timezone":"+08:00",
     "snapshot_at":200,"capabilities":[],"now":200,
     "trace":{},"failover":{},"exits":[],
     "today":{"requests":0,"ok":0,"err":0,"canceled":0},
     "models":{"items":[]},"inflight":[],"recent":[],
     "recent_day":{"day":"2026-11-27","n":0},"events":[]\(extra)}
    """
    return try MonitoringSnapshot(data: Data(json.utf8))
}

private func quotaJSON(
    balance: String = "1234.56789", used: String = "2469.13578",
    updated: String = "100", attempted: String = "100", ok: String = "true",
    stale: String = "false", error: String = "null"
) -> String {
    """
    {"source":"xunxin_account","scope":"account","currency":"USD",
     "balance_usd":\(balance),"used_usd":\(used),
     "updated_at":\(updated),"last_attempt_at":\(attempted),
     "ok":\(ok),"stale":\(stale),"error":\(error),
     "refresh_seconds":60,"stale_after_seconds":180}
    """
}

private func quotaValue(_ fields: [String: JSONValue]) -> JSONValue {
    .object(fields)
}

/// The same scoped snapshot, with a quota object this test can shape field by field.
private func quotaSnapshot(fields: [String: Any]) throws -> MonitoringSnapshot {
    let root: [String: Any] = [
        "schema_version": 1, "scope": "xunxin", "day": "2026-11-27", "timezone": "+08:00",
        "snapshot_at": 200, "capabilities": [String](), "now": 200,
        "trace": [String: Any](), "failover": [String: Any](), "exits": [Any](),
        "today": ["requests": 0, "ok": 0, "err": 0, "canceled": 0],
        "models": ["items": [Any]()], "inflight": [Any](), "recent": [Any](),
        "recent_day": ["day": "2026-11-27", "n": 0], "events": [Any](),
        "quota": fields,
    ]
    return try MonitoringSnapshot(data: try JSONSerialization.data(withJSONObject: root))
}

private func quotaFields(_ extra: [String: Any] = [:]) -> [String: Any] {
    var fields: [String: Any] = [
        "source": "xunxin_account", "scope": "account", "currency": "USD",
        "balance_usd": 128.402, "used_usd": 2332.507,
        "updated_at": 100, "last_attempt_at": 100,
        "ok": true, "stale": false, "error": NSNull(),
        "refresh_seconds": 60, "stale_after_seconds": 180,
    ]
    for (key, value) in extra { fields[key] = value }
    return fields
}

private func trendFields(_ extra: [String: Any] = [:]) -> [String: Any] {
    var fields: [String: Any] = [
        "window_days": 7,
        "topup_detected": false,
        "points": [
            ["day": "2026-11-25", "balance_usd": 150.0, "spent_usd": 10.0],
            ["day": "2026-11-26", "balance_usd": 140.0, "spent_usd": 10.0],
            ["day": "2026-11-27", "balance_usd": 128.402, "spent_usd": 11.598],
        ],
        "projection": [
            ["day": "2026-11-28", "balance_usd": 118.5],
            ["day": "2026-11-29", "balance_usd": 108.6],
        ],
        "depletion_day": "2026-12-10",
    ]
    for (key, value) in extra { fields[key] = value }
    return fields
}

@Suite("Monitoring quota")
struct MonitoringQuotaTests {
    @Test func anOlderSnapshotWithoutQuotaStillDecodes() throws {
        let snapshot = try quotaSnapshot()
        #expect(snapshot.quota == nil)
    }

    @Test func malformedQuotaIsUnknownButKeepsTheSnapshot() throws {
        for value in ["null", "[]", "\"quota\"", "{}",
                      #"{"source":"elsewhere","scope":"account","currency":"USD"}"#,
                      #"{"source":"xunxin_account","scope":"global","currency":"USD"}"#,
                      #"{"source":"xunxin_account","scope":"account","currency":"EUR"}"#] {
            let snapshot = try quotaSnapshot(value)
            #expect(snapshot.quota == nil, "\(value)")
        }
    }

    @Test func amountsMustBeStrictFiniteNumbers() throws {
        let base: [String: JSONValue] = [
            "source": .string("xunxin_account"), "scope": .string("account"),
            "currency": .string("USD"), "ok": .bool(true), "stale": .bool(false),
            "updated_at": .number(100), "last_attempt_at": .number(100),
            "refresh_seconds": .number(60), "stale_after_seconds": .number(180),
        ]
        for invalid: JSONValue in [.bool(true), .string("1"), .array([]), .object([:]),
                                   .number(.nan), .number(.infinity), .number(-.infinity)] {
            var fields = base
            fields["balance_usd"] = invalid
            fields["used_usd"] = .number(10)
            let quota = MonitoringQuota(quotaValue(fields))
            #expect(quota?.balanceUSD == nil, "\(invalid)")
            #expect(quota?.usedUSD == 10)
            #expect(quota?.hasValues == true)
        }
        for valid in [0.0, -3.5, 617_283_945.0 / 500_000.0] {
            var fields = base
            fields["balance_usd"] = .number(valid)
            fields["used_usd"] = .number(valid)
            let quota = MonitoringQuota(quotaValue(fields))
            #expect(quota?.balanceUSD == valid)
            #expect(quota?.usedUSD == valid)
        }
    }

    @Test func aSuccessWithoutBothAmountsIsNeverLive() throws {
        let absent = try #require(try quotaSnapshot(quotaJSON(
            balance: "null", used: "null", ok: "true", stale: "false"
        )).quota)
        #expect(!absent.hasValues)
        #expect(absent.state(serverTime: 200, transportIsCurrent: true) == .unknown)

        // One valid amount still can't prove a complete account reading.
        let partial = try #require(try quotaSnapshot(quotaJSON(
            balance: "10", used: "null", ok: "true", stale: "false"
        )).quota)
        #expect(partial.hasValues)
        #expect(!partial.hasCompleteValues)
        #expect(partial.state(serverTime: 200, transportIsCurrent: true) == .unknown)
        #expect(partial.state(serverTime: 200, transportIsCurrent: false) == .stale)

        // Booleans and strings are not amounts even when the service says success.
        for (badBalance, badUsed) in [("true", "false"), ("\"10\"", "\"20\""),
                                      ("[]", "{}")] {
            let malformed = try #require(try quotaSnapshot(quotaJSON(
                balance: badBalance, used: badUsed, ok: "true", stale: "false"
            )).quota)
            #expect(!malformed.hasValues)
            #expect(malformed.state(serverTime: 200, transportIsCurrent: true) == .unknown)
        }
    }

    @Test func readsTheBackendQuota() throws {
        let snapshot = try quotaSnapshot(quotaJSON())
        let quota = try #require(snapshot.quota)
        #expect(quota.source == "xunxin_account")
        #expect(quota.scope == "account")
        #expect(quota.currency == "USD")
        #expect(quota.balanceUSD == 1234.56789)
        #expect(quota.usedUSD == 2469.13578)
        #expect(quota.updatedAt == 100)
        #expect(quota.lastAttemptAt == 100)
        #expect(quota.ok == true)
        #expect(quota.stale == false)
        #expect(quota.refreshSeconds == 60)
        #expect(quota.staleAfterSeconds == 180)
        #expect(quota.errorKind == nil)
    }

    @Test func allowedErrorsMapAndUnknownCodesStayGeneric() throws {
        let codes: [(String, MonitoringQuotaError)] = [
            ("not_configured", .notConfigured), ("auth_failed", .authFailed),
            ("timeout", .timeout), ("unavailable", .unavailable),
            ("invalid_response", .invalidResponse),
        ]
        for (raw, kind) in codes {
            let quota = try #require(try quotaSnapshot(quotaJSON(
                balance: "null", used: "null", updated: "null", attempted: "150",
                ok: "false", stale: "true", error: "\"\(raw)\""
            )).quota)
            #expect(quota.errorKind == kind)
        }
        let unknown = try quotaSnapshot(quotaJSON(
            balance: "null", used: "null", updated: "null", attempted: "150",
            ok: "false", stale: "true", error: "\"upstream said secret\""
        )).quota
        #expect(unknown?.errorKind == nil)
    }

    @Test func liveNeedsSuccessFreshnessAgeAndACurrentTransport() throws {
        let quota = try #require(try quotaSnapshot(quotaJSON()).quota)
        #expect(quota.state(serverTime: 200, transportIsCurrent: true) == .live)
        // The contract's boundary: 180 s old is still current, one tick more is not.
        #expect(quota.state(serverTime: 280, transportIsCurrent: true) == .live)
        #expect(quota.state(serverTime: 280.001, transportIsCurrent: true) == .stale)
        // A dropped transport or an aged receipt can never leave the quota claiming live.
        #expect(quota.state(serverTime: 200, transportIsCurrent: false) == .stale)
        // Without the service clock the app can't prove the age.
        #expect(quota.state(serverTime: nil, transportIsCurrent: true) == .unknown)
    }

    @Test func failuresStaleValuesAndFirstFailuresAreDistinct() throws {
        let failedWithValues = try #require(try quotaSnapshot(quotaJSON(
            updated: "100", attempted: "160", ok: "false", stale: "true",
            error: "\"timeout\""
        )).quota)
        #expect(failedWithValues.state(serverTime: 200, transportIsCurrent: true) == .stale)

        let firstFailure = try #require(try quotaSnapshot(quotaJSON(
            balance: "null", used: "null", updated: "null", attempted: "160",
            ok: "false", stale: "true", error: "\"auth_failed\""
        )).quota)
        #expect(!firstFailure.hasValues)
        #expect(firstFailure.state(serverTime: 200, transportIsCurrent: true) == .down)
        #expect(firstFailure.state(serverTime: 200, transportIsCurrent: false) == .unknown)

        let neverAttempted = try #require(try quotaSnapshot(quotaJSON(
            balance: "null", used: "null", updated: "null", attempted: "null",
            ok: "null", stale: "true", error: "null"
        )).quota)
        #expect(neverAttempted.state(serverTime: 200, transportIsCurrent: true) == .unknown)
    }

    @Test func aServiceStaleFlagWinsEvenWhenTheAgeLooksFresh() throws {
        let quota = try #require(try quotaSnapshot(quotaJSON(
            ok: "true", stale: "true"
        )).quota)
        #expect(quota.state(serverTime: 200, transportIsCurrent: true) == .stale)
    }

    @Test func missingThresholdsFallBackToSixtyAndOneEighty() throws {
        let json = """
        {"source":"xunxin_account","scope":"account","currency":"USD",
         "balance_usd":1,"used_usd":2,"updated_at":100,"last_attempt_at":100,
         "ok":true,"stale":false,"error":null}
        """
        let quota = try #require(try quotaSnapshot(json).quota)
        #expect(quota.refreshSeconds == 60)
        #expect(quota.staleAfterSeconds == 180)
        #expect(quota.state(serverTime: 250, transportIsCurrent: true) == .live)
        #expect(quota.state(serverTime: 281, transportIsCurrent: true) == .stale)
    }

    // MARK: Today, the 7-day pace and the trend

    @Test func readsTodayTheAverageAndTheForecast() throws {
        let snapshot = try quotaSnapshot(fields: quotaFields([
            "today": ["day": "2026-11-28", "used_usd": 12.34, "tokens": 123_456,
                      "requests": 78, "updated_at": 179_580_000.0],
            "avg_daily_usd": 9.87,
            "forecast": ["window_days": 7, "avg_daily_usd": 9.87,
                         "days_left": 240.7, "projected_empty_at": 179_600_000.0],
        ]))
        let quota = try #require(snapshot.quota)
        #expect(quota.today?.day == "2026-11-28")
        #expect(quota.today?.usedUSD == 12.34)
        #expect(quota.today?.tokens == 123_456)
        #expect(quota.today?.requests == 78)
        #expect(quota.today?.updatedAt == 179_580_000)
        #expect(quota.avgDailyUSD == 9.87)
        #expect(quota.forecast?.windowDays == 7)
        #expect(quota.forecast?.avgDailyUSD == 9.87)
        #expect(quota.forecast?.daysLeft == 240.7)
        #expect(quota.forecast?.projectedEmptyAt == 179_600_000)
        #expect(quota.usageError == nil)
        #expect(quota.hasUsageReport)
        // The balance keeps its own older fields and freshness.
        #expect(quota.balanceUSD == 128.402)
        #expect(quota.usedUSD == 2332.507)
        #expect(quota.state(serverTime: 200, transportIsCurrent: true) == .live)
    }

    @Test func missingUsageFieldsStayUnknownAndNeverZero() throws {
        // A service older than the usage fields: nothing appears, and the balance is unchanged.
        let older = try #require(try quotaSnapshot(fields: quotaFields()).quota)
        #expect(older.today == nil)
        #expect(older.avgDailyUSD == nil)
        #expect(older.forecast == nil)
        #expect(older.trend == nil)
        #expect(older.usageError == nil)
        #expect(!older.hasUsageReport)
        #expect(older.state(serverTime: 200, transportIsCurrent: true) == .live)

        // A service that reports the fields as null says "no reading", not "zero".
        let silent = try #require(try quotaSnapshot(fields: quotaFields([
            "usage_error": NSNull(), "today": NSNull(),
            "avg_daily_usd": NSNull(), "forecast": NSNull(),
        ])).quota)
        #expect(silent.today == nil)
        #expect(silent.avgDailyUSD == nil)
        #expect(silent.forecast == nil)
        #expect(!silent.hasUsageReport)

        // A partial today keeps only the values it can prove.
        let partial = try #require(try quotaSnapshot(fields: quotaFields([
            "today": ["day": "2026-11-28"],
        ])).quota)
        #expect(partial.today?.day == "2026-11-28")
        #expect(partial.today?.usedUSD == nil)
        #expect(partial.today?.tokens == nil)
        #expect(partial.today?.requests == nil)
        #expect(partial.today?.updatedAt == nil)
        #expect(partial.hasUsageReport)
    }

    @Test func malformedUsageValuesAreUnknownWithoutFailingTheSnapshot() throws {
        for today: Any in ["12.34", [Any](), 42, true] {
            let quota = try #require(try quotaSnapshot(fields: quotaFields(["today": today])).quota)
            #expect(quota.today == nil, "\(today)")
        }
        for average: Any in ["9.87", [Any](), ["usd": 9.87], true] {
            let quota = try #require(try quotaSnapshot(fields: quotaFields(["avg_daily_usd": average])).quota)
            #expect(quota.avgDailyUSD == nil, "\(average)")
        }
        // Wrong types inside an object leave each field unknown rather than a made-up value.
        let mixed = try #require(try quotaSnapshot(fields: quotaFields([
            "usage_error": 42,
            "today": ["day": 20_261_128, "used_usd": "12.34", "tokens": true,
                      "requests": "78", "updated_at": 0],
            "forecast": ["window_days": 7.5, "avg_daily_usd": "9.87",
                         "days_left": -1, "projected_empty_at": 0],
        ])).quota)
        #expect(mixed.usageError == nil)
        #expect(mixed.today?.day == nil)
        #expect(mixed.today?.usedUSD == nil)
        #expect(mixed.today?.tokens == nil)
        #expect(mixed.today?.requests == nil)
        #expect(mixed.today?.updatedAt == nil)
        #expect(mixed.forecast?.windowDays == nil)
        #expect(mixed.forecast?.avgDailyUSD == nil)
        #expect(mixed.forecast?.daysLeft == nil)
        #expect(mixed.forecast?.projectedEmptyAt == nil)
        // The objects exist, so the card shows `—` instead of hiding the block.
        #expect(mixed.hasUsageReport)

        // Non-finite amounts can't arrive as JSON, but the reader still refuses them.
        let raw: [String: JSONValue] = [
            "source": .string("xunxin_account"), "scope": .string("account"),
            "currency": .string("USD"), "ok": .bool(true), "stale": .bool(false),
            "updated_at": .number(100), "avg_daily_usd": .number(.nan),
            "today": .object(["used_usd": .number(.infinity)]),
            "forecast": .object(["days_left": .number(.infinity)]),
        ]
        let nonFinite = try #require(MonitoringQuota(quotaValue(raw)))
        #expect(nonFinite.avgDailyUSD == nil)
        #expect(nonFinite.today?.usedUSD == nil)
        #expect(nonFinite.forecast?.daysLeft == nil)
    }

    @Test func usageErrorsAreTypedAndKeepTheLastReading() throws {
        let codes: [(String, MonitoringQuotaError)] = [
            ("not_configured", .notConfigured), ("auth_failed", .authFailed),
            ("timeout", .timeout), ("unavailable", .unavailable),
            ("invalid_response", .invalidResponse),
        ]
        for (raw, kind) in codes {
            let quota = try #require(try quotaSnapshot(fields: quotaFields([
                "usage_error": raw,
                "today": ["used_usd": 12.34],
                "avg_daily_usd": 9.87,
                "forecast": ["days_left": 2.5, "projected_empty_at": 300],
            ])).quota)
            #expect(quota.usageErrorKind == kind)
            #expect(quota.today?.usedUSD == 12.34)
            #expect(quota.forecast?.daysLeft == 2.5)
            // A failed usage read never makes the balance stale on its own.
            #expect(quota.state(serverTime: 200, transportIsCurrent: true) == .live)
        }
        let unknown = try #require(try quotaSnapshot(fields: quotaFields([
            "usage_error": "upstream said secret",
        ])).quota)
        #expect(unknown.usageError == "upstream said secret")
        #expect(unknown.usageErrorKind == nil)
    }

    @Test func aStaleBalanceStillKeepsTodayAndTheForecast() throws {
        let quota = try #require(try quotaSnapshot(fields: quotaFields([
            "ok": false, "stale": true, "error": "timeout",
            "usage_error": "timeout",
            "today": ["day": "2026-11-28", "used_usd": 12.34, "updated_at": 150],
            "avg_daily_usd": 9.87,
            "forecast": ["window_days": 7, "avg_daily_usd": 9.87,
                         "days_left": 240.7, "projected_empty_at": 179_600_000],
        ])).quota)
        #expect(quota.state(serverTime: 200, transportIsCurrent: true) == .stale)
        #expect(quota.today?.usedUSD == 12.34)
        #expect(quota.avgDailyUSD == 9.87)
        #expect(quota.forecast?.daysLeft == 240.7)
        #expect(quota.usageErrorKind == .timeout)
    }

    @Test func readsTheBalanceTrendAndItsProjection() throws {
        let quota = try #require(try quotaSnapshot(fields: quotaFields(["trend": trendFields()])).quota)
        let trend = try #require(quota.trend)
        #expect(trend.windowDays == 7)
        #expect(!trend.topupDetected)
        #expect(trend.points.count == 3)
        #expect(trend.points[2].day == "2026-11-27")
        #expect(trend.points[2].balanceUSD == 128.402)
        #expect(trend.points[2].spentUSD == 11.598)
        #expect(trend.projection.count == 2)
        #expect(trend.projection[0].spentUSD == nil)
        #expect(trend.depletionDay == "2026-12-10")

        // What the card draws: oldest first, projection after the history, end marked.
        let summary = try #require(MonitoringQuotaTrendSummary(quota.trend))
        #expect(summary.points.map(\.day) == ["2026-11-25", "2026-11-26", "2026-11-27"])
        #expect(summary.hasProjection)
        #expect(summary.marksDepletion)
        #expect(!summary.showsTopupNote)
        #expect(summary.peakBalanceUSD == 150)
        #expect(summary.chartPoints.count == 5)
        #expect(summary.chartPoints.last?.day == "2026-11-29")
    }

    @Test func theSummaryDrawsTheOldestDayFirst() throws {
        let unsorted = trendFields(["points": [
            ["day": "2026-11-27", "balance_usd": 128.0],
            ["day": "2026-11-25", "balance_usd": 150.0],
        ]])
        let quota = try #require(try quotaSnapshot(fields: quotaFields(["trend": unsorted])).quota)
        let summary = try #require(MonitoringQuotaTrendSummary(quota.trend))
        #expect(summary.points.map(\.balanceUSD) == [150, 128])
    }

    @Test func aMissingTrendDrawsNothing() throws {
        let quota = try #require(try quotaSnapshot(fields: quotaFields()).quota)
        #expect(quota.trend == nil)
        #expect(MonitoringQuotaTrendSummary(quota.trend) == nil)

        // No history is still nothing to draw: the card keeps no frame.
        let empty = try #require(try quotaSnapshot(fields: quotaFields(["trend": [String: Any]()])).quota)
        #expect(empty.trend != nil)
        #expect(empty.trend?.points.isEmpty == true)
        #expect(MonitoringQuotaTrendSummary(empty.trend) == nil)

        // A malformed trend is unknown rather than fatal.
        for value: Any in ["trend", [Any](), 7, true] {
            let malformed = try #require(try quotaSnapshot(fields: quotaFields(["trend": value])).quota)
            #expect(malformed.trend == nil, "\(value)")
        }

        // Wrong types inside the object leave it empty, never guessed.
        let wrongTypes = try #require(try quotaSnapshot(fields: quotaFields([
            "trend": ["window_days": "7", "topup_detected": "yes",
                      "points": "nope", "projection": ["x"], "depletion_day": 20_261_210],
        ])).quota)
        #expect(wrongTypes.trend?.windowDays == nil)
        #expect(wrongTypes.trend?.topupDetected == false)
        #expect(wrongTypes.trend?.points.isEmpty == true)
        #expect(wrongTypes.trend?.projection.isEmpty == true)
        #expect(wrongTypes.trend?.depletionDay == nil)
        #expect(MonitoringQuotaTrendSummary(wrongTypes.trend) == nil)
    }

    @Test func malformedTrendPointsAreDroppedNotGuessed() throws {
        let quota = try #require(try quotaSnapshot(fields: quotaFields([
            "trend": [
                "points": [
                    ["day": "2026-11-27", "balance_usd": 128.0],
                    ["day": "2026-11-26", "balance_usd": "140"],
                    ["balance_usd": 150.0],
                    ["day": 42, "balance_usd": 160.0],
                    ["day": "2026-11-25", "balance_usd": 150.0, "spent_usd": "12"],
                ],
            ],
        ])).quota)
        let trend = try #require(quota.trend)
        #expect(trend.points.count == 2)
        #expect(trend.points.map(\.day) == ["2026-11-27", "2026-11-25"])
        #expect(trend.points[1].spentUSD == nil)
        let summary = try #require(MonitoringQuotaTrendSummary(quota.trend))
        #expect(summary.points.map(\.day) == ["2026-11-25", "2026-11-27"])
        #expect(!summary.hasProjection)
        #expect(!summary.marksDepletion)
    }

    @Test func anEmptyProjectionLeavesOnlyTheHistoryLine() throws {
        let quota = try #require(try quotaSnapshot(fields: quotaFields([
            "trend": trendFields(["projection": [Any](), "depletion_day": "2026-12-10"]),
        ])).quota)
        let summary = try #require(MonitoringQuotaTrendSummary(quota.trend))
        #expect(!summary.hasProjection)
        // No curve end exists to mark, even though the service named a day.
        #expect(!summary.marksDepletion)
        #expect(summary.points.count == 3)
    }

    @Test func aSingleRecordedDayStillHasAChart() throws {
        let quota = try #require(try quotaSnapshot(fields: quotaFields([
            "trend": trendFields([
                "points": [["day": "2026-11-27", "balance_usd": 128.402]],
                "projection": [Any](),
                "depletion_day": NSNull(),
            ]),
        ])).quota)
        let summary = try #require(MonitoringQuotaTrendSummary(quota.trend))
        #expect(summary.points.count == 1)
        #expect(!summary.hasProjection)
        #expect(!summary.marksDepletion)
        #expect(summary.peakBalanceUSD == 128.402)
        #expect(summary.chartPoints.count == 1)
    }

    @Test func withoutADepletionDayThereIsNoMarker() throws {
        let quota = try #require(try quotaSnapshot(fields: quotaFields([
            "trend": trendFields(["depletion_day": NSNull()]),
        ])).quota)
        let summary = try #require(MonitoringQuotaTrendSummary(quota.trend))
        #expect(summary.hasProjection)
        #expect(summary.depletionDay == nil)
        #expect(!summary.marksDepletion)
    }

    @Test func aTopUpIsNamedInTheSummary() throws {
        let quota = try #require(try quotaSnapshot(fields: quotaFields([
            "trend": trendFields(["topup_detected": true]),
        ])).quota)
        let summary = try #require(MonitoringQuotaTrendSummary(quota.trend))
        #expect(summary.topupDetected)
        #expect(summary.showsTopupNote)
    }

    @Test func theBackendFixtureCarriesTheSameQuotaContract() throws {
        let url = try #require(Bundle.module.url(
            forResource: "snapshot-v1", withExtension: "json",
            subdirectory: "Fixtures/MonitoringReview"
        ))
        let snapshot = try MonitoringSnapshot(data: Data(contentsOf: url))
        let quota = try #require(snapshot.quota)
        #expect(quota.balanceUSD == 1234.56789)
        #expect(quota.usedUSD == 2469.13578)
        #expect(quota.today?.usedUSD == 12.34)
        #expect(quota.avgDailyUSD == 9.87)
        #expect(quota.forecast?.daysLeft == 12.9)
        #expect(quota.trend?.points.count == 7)
        #expect(quota.trend?.projection.count == 3)
        let trend = try #require(MonitoringQuotaTrendSummary(quota.trend))
        #expect(trend.marksDepletion)
        #expect(trend.points.last?.balanceUSD == quota.balanceUSD)
        #expect(quota.state(serverTime: snapshot.snapshotAt, transportIsCurrent: true) == .live)
    }
}
