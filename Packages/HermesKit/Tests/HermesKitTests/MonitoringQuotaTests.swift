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

    @Test func theBackendFixtureCarriesTheSameQuotaContract() throws {
        let url = try #require(Bundle.module.url(
            forResource: "snapshot-v1", withExtension: "json",
            subdirectory: "Fixtures/MonitoringReview"
        ))
        let snapshot = try MonitoringSnapshot(data: Data(contentsOf: url))
        let quota = try #require(snapshot.quota)
        #expect(quota.balanceUSD == 1234.56789)
        #expect(quota.usedUSD == 2469.13578)
        #expect(quota.state(serverTime: snapshot.snapshotAt, transportIsCurrent: true) == .live)
    }
}
