import Foundation
import Security
import Synchronization
import Testing
@testable import HermesKit

// MARK: - Fixtures

private func snapshotJSON(
    day: String = "2026-11-27", scope: String = "xunxin", schema: Int? = 1,
    snapshotAt: Double = 1_764_200_000, timezone: String = "+08:00",
    extra: String = ""
) -> String {
    let schemaField = schema.map { "\"schema_version\":\($0)," } ?? ""
    return """
    {\(schemaField)"scope":"\(scope)","day":"\(day)","timezone":"\(timezone)",
     "snapshot_at":\(snapshotAt),
     "capabilities":["snapshot","recent","stream"],
     "freshness":{"trace":{"ok":true,"last_success_at":\(snapshotAt - 2)},"probes":{"ok":true,"last_success_at":\(snapshotAt - 5)},"usage":{"ok":true,"last_success_at":\(snapshotAt - 30)}},
     "now":\(snapshotAt),
     "trace":{"ok":true},"failover":{"reachable":true,"tunnels":0},
     "exits":[],"today":{"requests":0,"ok":0,"err":0,"canceled":0},
     "models":{"buckets":8,"bucket_hours":3,"items":[]},
     "inflight":[],"recent":[],"recent_day":{"day":"\(day)","n":0,"upto":0},"events":[]
     \(extra.isEmpty ? "" : ",\(extra)")}
    """
}

private func snapshot(day: String = "2026-11-27", requests: Int = 0, upto: Int = 0) throws -> MonitoringSnapshot {
    let base = snapshotJSON(day: day)
        .replacingOccurrences(of: "\"today\":{\"requests\":0,\"ok\":0,\"err\":0,\"canceled\":0}",
                              with: "\"today\":{\"requests\":\(requests),\"ok\":\(requests),\"err\":0,\"canceled\":0}")
        .replacingOccurrences(of: "\"recent_day\":{\"day\":\"\(day)\",\"n\":0,\"upto\":0}",
                              with: "\"recent_day\":{\"day\":\"\(day)\",\"n\":\(requests),\"upto\":\(upto)}")
    return try MonitoringSnapshot(data: Data(base.utf8))
}

private func flight(_ json: String) throws -> MonitoringFlight {
    MonitoringFlight(try #require(JSONValue.parse(json)))
}

// MARK: - Contract

@Suite("Monitoring contract")
struct MonitoringContractTests {
    @Test func readsTheScopedSnapshot() throws {
        let snapshot = try snapshot(requests: 12, upto: 34)
        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.scope == "xunxin")
        #expect(snapshot.day == "2026-11-27")
        #expect(snapshot.serverTime == 1_764_200_000)
        #expect(snapshot.today.requests == 12)
        #expect(snapshot.recentDay.upto == 34)
    }

    @Test func refusesAPayloadWithoutSchemaOrScope() {
        #expect(throws: MonitoringContractError.legacyPayload) {
            _ = try MonitoringSnapshot(data: Data(#"{"today":{"requests":5}}"#.utf8))
        }
        #expect(throws: MonitoringContractError.legacyPayload) {
            _ = try MonitoringSnapshot(data: Data(snapshotJSON(scope: "", schema: nil).utf8))
        }
    }

    @Test func refusesAnotherScope() {
        #expect(throws: MonitoringContractError.wrongScope("global")) {
            _ = try MonitoringSnapshot(data: Data(snapshotJSON(scope: "global").utf8))
        }
    }

    @Test func refusesANewerSchema() {
        #expect(throws: MonitoringContractError.unsupportedSchema(2)) {
            _ = try MonitoringSnapshot(data: Data(snapshotJSON(schema: 2).utf8))
        }
    }

    @Test func refusesHTML() {
        #expect(throws: MonitoringContractError.notJSON) {
            _ = try MonitoringSnapshot(data: Data("<html>login</html>".utf8))
        }
    }

    /// Upstream can name a provider and a model that aren't Xunxin's; the scoped payload still
    /// belongs to this link, and the row shows what ran instead of assuming a household name.
    @Test func keepsMixedProviderModelNames() throws {
        let row = try flight(#"{"id":"1","done":true,"status":200,"provider":"anthropic","model":"claude-sonnet-4-5","req_model":"gpt-5"}"#)
        #expect(row.displayModel == "claude-sonnet-4-5")
        #expect(row.outcome == .success)
    }

    @Test func a499IsCancelledNotFailed() throws {
        let row = try flight(#"{"id":"2","done":true,"status":499}"#)
        #expect(row.outcome == .cancelled)
    }

    @Test func unknownCostsAndLatenciesStayUnknown() throws {
        let row = try flight(#"{"id":"3","done":true,"status":200,"cost":null,"ms":null,"ttft":null,"tps":null}"#)
        #expect(row.cost == nil)
        #expect(row.milliseconds == nil)
        #expect(row.ttft == nil)
        #expect(row.tps == nil)
        #expect(row.elapsedSeconds(now: nil) == nil)
        #expect(row.speedText == nil)
        #expect(row.computedCacheHitRate == nil)
    }

    @Test func anUnfinishedRequestIsInFlightAndCountsUp() throws {
        let row = try flight(#"{"id":"4","done":false,"start":100,"model":"m"}"#)
        #expect(row.outcome == .inFlight)
        #expect(row.elapsedSeconds(now: 130) == 30)
    }

    @Test func cacheHitRateNeedsInput() {
        var today = MonitoringToday(nil)
        #expect(today.cacheHitRate == nil)
        today = MonitoringToday(JSONValue.parse(#"{"cache_read":50,"in":50,"cache_write":0}"#))
        #expect(today.cacheHitRate == 0.5)
    }

    @Test func aModelAverageNeedsPricedRequests() throws {
        let item = MonitoringModelItem(try #require(JSONValue.parse(#"{"key":"m","cost":1.5,"cost_n":3,"cost_unknown":2}"#)))
        #expect(item.averageCost == 0.5)
        let unpriced = MonitoringModelItem(try #require(JSONValue.parse(#"{"key":"m","cost":null,"cost_n":0}"#)))
        #expect(unpriced.averageCost == nil)
    }

    @Test func readsAGatedRecentPage() throws {
        let json = """
        {"schema_version":1,"scope":"xunxin","timezone":"+08:00","day":"2026-11-27",
         "n_day":10,"n_now":12,"upto":40,"newer":2,"newer_all":2,"total":10,
         "cost_sum":1.25,"cost_n":8,"cost_none":2,"page":1,"size":50,"pages":1,"sort":"new",
         "items":[{"id":"9","done":true,"status":200}]}
        """
        let page = try MonitoringRecentPage(data: Data(json.utf8))
        #expect(page.upto == 40)
        #expect(page.newer == 2)
        #expect(page.total == 10)
        #expect(page.unpricedCount == 2)
        #expect(page.items.first?.outcome == .success)
    }

    @Test func sourceTimesUseTheServerClock() {
        let policy = MonitoringFreshnessPolicy.standard
        let fresh = MonitoringSourceFreshness(JSONValue.parse(#"{"ok":true,"last_success_at":100}"#))
        #expect(policy.state(of: fresh, at: 130, staleAfter: 60) == .live)
        #expect(policy.state(of: fresh, at: 200, staleAfter: 60) == .stale)
        let down = MonitoringSourceFreshness(JSONValue.parse(#"{"ok":false}"#))
        #expect(policy.state(of: down, at: 130, staleAfter: 60) == .down)
        let missing = MonitoringSourceFreshness(nil)
        #expect(policy.state(of: missing, at: 130, staleAfter: 60) == .unknown)
        // A source with no last success and no server clock can't be called live.
        #expect(policy.state(of: MonitoringSourceFreshness(JSONValue.parse(#"{"ok":true}"#)), at: 130, staleAfter: 60) == .unknown)
        #expect(policy.state(of: fresh, at: nil, staleAfter: 60) == .unknown)
    }

    @Test func aSnapshotWithoutFreshnessClaimsNothingLive() throws {
        let bare = try MonitoringSnapshot(data: Data(snapshotJSON(extra: "").replacingOccurrences(
            of: "\"freshness\":{", with: "\"ignored\":{"
        ).utf8))
        // The substitution leaves an unread object behind, so freshness is genuinely absent.
        #expect(bare.freshness == nil)
        #expect(MonitoringFreshnessPolicy.standard.traceState(bare) == .unknown)
        #expect(MonitoringFreshnessPolicy.standard.probesState(bare) == .unknown)
        #expect(MonitoringFreshnessPolicy.standard.usageState(bare) == .unknown)
    }

    @Test func snapshotStalenessHasTwoClocks() {
        let policy = MonitoringFreshnessPolicy.standard
        let received = Date(timeIntervalSince1970: 1_000)
        #expect(!policy.snapshotIsStale(receivedAt: received, now: received.addingTimeInterval(9), isPolling: false))
        #expect(policy.snapshotIsStale(receivedAt: received, now: received.addingTimeInterval(11), isPolling: false))
        #expect(!policy.snapshotIsStale(receivedAt: received, now: received.addingTimeInterval(19), isPolling: true))
        #expect(policy.snapshotIsStale(receivedAt: received, now: received.addingTimeInterval(21), isPolling: true))
    }

    @Test func serverTimesRenderInTheServicesOffset() {
        #expect(MonitoringTime.clock(0, timezone: "+08:00") == "08:00:00")
        #expect(MonitoringTime.dayClock(0, timezone: "+08:00") == "1970-01-01 08:00:00")
        #expect(MonitoringTime.epoch(fromISO: "2026-11-27T10:20:30.123456+08:00") == 1_795_746_030.123)
        #expect(MonitoringTime.epoch(fromISO: "2026-11-27T02:20:30Z") == 1_795_746_030)
    }
}

// MARK: - Queries

@Suite("Monitoring requests query")
struct MonitoringQueryTests {
    @Test func theFirstPageWithNoFiltersFollowsLive() {
        #expect(MonitoringRequestQuery().followsLive)
        #expect(!MonitoringRequestQuery().hasFilters)
        #expect(!MonitoringRequestQuery(search: "gpt").followsLive)
        #expect(!MonitoringRequestQuery(page: 2).followsLive)
        #expect(!MonitoringRequestQuery(sort: .oldest).followsLive)
        #expect(!MonitoringRequestQuery(status: .failed).followsLive)
    }

    @Test func theQueryStringIsScopedAndStable() {
        var query = MonitoringRequestQuery(search: "  deep seek  ", status: .failed, cost: .priced,
                                           minimumCost: 0.25, maximumCost: 2, sort: .costDescending,
                                           page: 2, size: 25, upto: 90, day: "2026-11-27")
        query.search = "  deep seek  "
        let items = query.queryItems
        #expect(items.first == URLQueryItem(name: "scope", value: "xunxin"))
        #expect(items.contains(URLQueryItem(name: "q", value: "deep seek")))
        #expect(items.contains(URLQueryItem(name: "st", value: "err")))
        #expect(items.contains(URLQueryItem(name: "cost", value: "priced")))
        #expect(items.contains(URLQueryItem(name: "cmin", value: "0.25")))
        #expect(items.contains(URLQueryItem(name: "cmax", value: "2")))
        #expect(items.contains(URLQueryItem(name: "sort", value: "cost")))
        #expect(items.contains(URLQueryItem(name: "page", value: "2")))
        #expect(items.contains(URLQueryItem(name: "upto", value: "90")))
    }

    @Test func amountsAreNotLocalized() {
        #expect(MonitoringRequestQuery.number(1) == "1")
        #expect(MonitoringRequestQuery.number(0.25) == "0.25")
        #expect(MonitoringRequestQuery.number(0.000001) == "0.000001")
    }

    @Test func freezeTakesTheServicesGlobalPoint() throws {
        let snapshot = try snapshot(requests: 3, upto: 42)
        let freeze = try #require(MonitoringFreeze(snapshot))
        #expect(freeze.day == "2026-11-27")
        #expect(freeze.upto == 42)
        let query = MonitoringRequestQuery(search: "x").frozen(at: freeze)
        #expect(query.upto == 42)
        #expect(query.day == "2026-11-27")
        #expect(query.page == 1)
    }

    @Test func aSnapshotWithoutAnUptoCannotFreeze() throws {
        let json = snapshotJSON().replacingOccurrences(of: #""recent_day":{"day":"2026-11-27","n":0,"upto":0}"#,
                                                       with: #""recent_day":{"day":"2026-11-27","n":0}"#)
        let bare = try MonitoringSnapshot(data: Data(json.utf8))
        #expect(MonitoringFreeze(bare) == nil)
    }

    @Test func dayRolloverIsExplicit() {
        #expect(MonitoringRollover.check(frozen: "2026-11-27", current: "2026-11-27") == .unchanged)
        #expect(MonitoringRollover.check(frozen: nil, current: "2026-11-28") == .unchanged)
        #expect(MonitoringRollover.check(frozen: "2026-11-27", current: nil) == .unchanged)
        #expect(MonitoringRollover.check(frozen: "2026-11-27", current: "2026-11-28")
            == .rolledOver(previous: "2026-11-27", current: "2026-11-28"))
    }
}

// MARK: - Settings

@Suite("Monitoring settings")
struct MonitoringSettingsTests {
    @Test func aDisabledBlankConnectionIsSaveable() {
        #expect(MonitoringSettingsValidation.problem(.initial, typedToken: nil, hasStoredToken: false) == nil)
    }

    @Test func anEnabledConnectionNeedsAnAddressAndToken() {
        var settings = MonitoringSettings.initial
        settings.enabled = true
        #expect(MonitoringSettingsValidation.problem(settings, typedToken: nil, hasStoredToken: false)
            == .address(.blank))
        settings.baseURL = "https://monitor.example.com"
        #expect(MonitoringSettingsValidation.problem(settings, typedToken: nil, hasStoredToken: false) == nil)
        settings.auth = .bearer
        #expect(MonitoringSettingsValidation.problem(settings, typedToken: " ", hasStoredToken: false)
            == .tokenMissing)
        #expect(MonitoringSettingsValidation.problem(settings, typedToken: "abc", hasStoredToken: false) == nil)
        #expect(MonitoringSettingsValidation.problem(settings, typedToken: nil, hasStoredToken: true) == nil)
    }

    @Test(arguments: [
        ("ftp://monitor.example.com", MonitoringAddressError.unsupportedScheme("ftp")),
        ("https://user:secret@monitor.example.com", .credentialsInURL),
        ("https://monitor.example.com/?token=1", .queryInURL),
        ("https://monitor.example.com/#x", .fragmentInURL),
        ("https://", .missingHost),
        ("not an address", .malformed),
    ])
    func addressesThatMustNotBeSaved(text: String, expected: MonitoringAddressError) {
        #expect(throws: expected) { _ = try MonitoringAddress.url(from: text) }
    }

    @Test func keepsAPathPrefixAndDropsTheTrailingSlash() throws {
        let url = try MonitoringAddress.url(from: " https://example.com/monitor/ ")
        #expect(url.absoluteString == "https://example.com/monitor")
        #expect(MonitoringAddress.isPlainHTTP("http://127.0.0.1:48081/"))
        #expect(!MonitoringAddress.isPlainHTTP("https://example.com"))
    }

    @Test func aBearerTokenOnlyGoesToItsOwnAddress() throws {
        var settings = MonitoringSettings.initial
        settings.baseURL = "https://example.com/monitor"
        settings.auth = .bearer
        let connection = try MonitoringConnection(settings: settings, token: "secret")
        #expect(connection.token == "secret")
        #expect(connection.endpoint("api/snapshot").absoluteString == "https://example.com/monitor/api/snapshot")
        settings.auth = .none
        #expect(try MonitoringConnection(settings: settings, token: "secret").token == nil)
    }

    @Test func savesAndLoadsWithoutTheTokenInTheFile() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        var settings = MonitoringSettings.initial
        settings.enabled = true
        settings.baseURL = "https://example.com"
        settings.auth = .bearer
        var file = settings
        file.name = "Studio"
        try fixture.store.save(file, token: "token-one")

        let loaded = try fixture.store.load()
        #expect(loaded == file)
        #expect(try fixture.store.storedToken() == "token-one")
        let raw = try String(contentsOf: fixture.store.fileURL, encoding: .utf8)
        #expect(!raw.contains("token-one"))
        #expect(!raw.contains("access-token"))
    }

    /// The plan's save rule: a failed write keeps the old settings and the old token, and throws
    /// so the form can say the save failed.
    @Test func aFailedSaveKeepsThePreviousConfiguration() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        var old = MonitoringSettings.initial
        old.enabled = true
        old.baseURL = "https://old.example.com"
        old.auth = .bearer
        try fixture.store.save(old, token: "old-token")

        var changed = old
        changed.baseURL = "https://new.example.com"
        // A read-only folder can still be read, but the atomic write can't replace its file.
        let folder = fixture.store.fileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        do {
            try fixture.store.save(changed, token: "new-token")
            Issue.record("Saving into a read-only folder should have failed.")
        } catch {
            // Expected: the form reports the failure and the old configuration stays.
        }
        #expect(try fixture.store.load() == old)
        #expect(try fixture.store.storedToken() == "old-token")
    }
}

private struct SettingsFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: "monitoring-\(UUID().uuidString)")
    let keychain: MemoryKeychain
    let store: MonitoringSettingsStore

    init() throws {
        keychain = MemoryKeychain(service: "co.caffeinatedcode.hermes.tests.\(UUID().uuidString)")
        store = MonitoringSettingsStore(
            fileURL: directory.appending(path: "monitoring.json"), keychain: keychain.store
        )
    }

    func cleanUp() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A Keychain answered from a dictionary, so the settings tests never touch a real one.
final class MemoryKeychain: @unchecked Sendable {
    private let values = Mutex<[String: Data]>([:])
    private let service: String

    init(service: String) {
        self.service = service
    }

    var store: KeychainStore {
        KeychainStore(
            service: service, macFallback: .processMemory,
            calls: KeychainStore.Calls(
                copyMatching: { query in
                    guard let data = self.values.withLock({ $0[Self.key(query)] }) else {
                        return (errSecItemNotFound, nil)
                    }
                    return (errSecSuccess, data)
                },
                update: { query, attributes in
                    let key = Self.key(query)
                    guard self.values.withLock({ $0[key] }) != nil else { return errSecItemNotFound }
                    if let data = attributes[kSecValueData as String] as? Data {
                        self.values.withLock { $0[key] = data }
                    }
                    return errSecSuccess
                },
                add: { item in
                    if let data = item[kSecValueData as String] as? Data {
                        self.values.withLock { $0[Self.key(item)] = data }
                    }
                    return errSecSuccess
                },
                delete: { query in
                    let key = Self.key(query)
                    return self.values.withLock { $0.removeValue(forKey: key) != nil } ? errSecSuccess : errSecItemNotFound
                }
            )
        )
    }

    private static func key(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String] ?? "")/\(query[kSecAttrAccount as String] ?? "")"
    }
}

// MARK: - Session

@Suite("Monitoring session", .serialized)
struct MonitoringSessionTests {
    @Test func readsASnapshotThenGoesLive() async throws {
        let stream = AsyncThrowingStream<MonitoringSnapshot, any Error>.makeStream()
        let transport = FakeTransport(
            snapshot: { _ in try snapshot(requests: 1) },
            stream: { _ in stream.stream }
        )
        let recorder = UpdateRecorder()
        let session = MonitoringSession(
            transport: transport,
            configuration: MonitoringSessionConfiguration(connection: try Self.connection()),
            timing: MonitoringTiming(pollInterval: .seconds(1), jitter: 0)
        )
        recorder.watch(session)
        await session.start()
        try await waitUntil { recorder.snapshotCount == 1 }
        stream.continuation.yield(try snapshot(requests: 5))
        try await waitUntil { recorder.snapshotCount == 2 }
        #expect(recorder.states.contains(.live))
        #expect(recorder.lastSnapshot?.today.requests == 5)
        await session.finish()
        recorder.stop()
    }

    @Test func startTwiceNeverOpensTwoStreams() async throws {
        let stream = AsyncThrowingStream<MonitoringSnapshot, any Error>.makeStream()
        let transport = FakeTransport(
            snapshot: { _ in try snapshot() }, stream: { _ in stream.stream }
        )
        let session = MonitoringSession(
            transport: transport, configuration: MonitoringSessionConfiguration(connection: try Self.connection()),
            timing: Self.fastTiming
        )
        await session.start()
        await session.start()
        try await waitUntil { transport.streamCalls > 0 }
        #expect(transport.streamCalls == 1)
        await session.finish()
    }

    @Test func aResponseForAStoppedRunNeverLands() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let transport = FakeTransport(
            snapshot: { call in
                if call == 0 { for await _ in gate.stream { break } }
                return try snapshot(requests: 1)
            },
            stream: { _ in AsyncThrowingStream { $0.finish() } }
        )
        let recorder = UpdateRecorder()
        let session = MonitoringSession(
            transport: transport, configuration: MonitoringSessionConfiguration(connection: try Self.connection()),
            timing: Self.fastTiming
        )
        recorder.watch(session)
        await session.start()
        try await waitUntil { transport.snapshotCalls == 1 }
        await session.stop()
        try await waitUntil { recorder.states.last == .idle }
        gate.continuation.yield(())
        gate.continuation.finish()
        try await Task.sleep(for: .milliseconds(80))
        #expect(recorder.snapshotCount == 0)
        await session.finish()
        recorder.stop()
    }

    @Test func aRestartedSessionOnlyAcceptsItsNewGeneration() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let transport = FakeTransport(
            snapshot: { call in
                if call == 0 {
                    for await _ in gate.stream { break }
                    return try snapshot(day: "2026-11-27", requests: 1)
                }
                return try snapshot(day: "2026-11-28", requests: 2)
            },
            stream: { _ in AsyncThrowingStream { $0.finish() } }
        )
        let recorder = UpdateRecorder()
        let session = MonitoringSession(
            transport: transport, configuration: MonitoringSessionConfiguration(connection: try Self.connection()),
            timing: Self.fastTiming
        )
        recorder.watch(session)
        await session.start()
        try await waitUntil { transport.snapshotCalls == 1 }
        await session.stop()
        await session.start()
        try await waitUntil { recorder.lastSnapshot?.day == "2026-11-28" }
        gate.continuation.yield(())
        gate.continuation.finish()
        try await Task.sleep(for: .milliseconds(80))
        #expect(recorder.snapshots.allSatisfy { $0.day == "2026-11-28" })
        await session.finish()
        recorder.stop()
    }

    @Test func aStreamThatEndsFallsBackToPolling() async throws {
        let transport = FakeTransport(
            snapshot: { _ in try snapshot(requests: 1) },
            stream: { _ in AsyncThrowingStream { $0.finish() } }
        )
        let recorder = UpdateRecorder()
        let session = MonitoringSession(
            transport: transport, configuration: MonitoringSessionConfiguration(connection: try Self.connection()),
            timing: Self.fastTiming
        )
        recorder.watch(session)
        await session.start()
        try await waitUntil { recorder.states.contains { $0.isPolling } }
        try await waitUntil { transport.snapshotCalls >= 2 }
        #expect(recorder.lastSnapshot != nil)
        await session.finish()
        recorder.stop()
    }

    @Test func aSavedPollingConnectionNeverOpensAStream() async throws {
        let transport = FakeTransport(
            snapshot: { _ in try snapshot(requests: 1) },
            stream: { _ in AsyncThrowingStream { $0.finish() } }
        )
        let session = MonitoringSession(
            transport: transport,
            configuration: MonitoringSessionConfiguration(connection: try Self.connection(), allowsStreaming: false),
            timing: Self.fastTiming
        )
        let recorder = UpdateRecorder()
        recorder.watch(session)
        await session.start()
        try await waitUntil { transport.snapshotCalls >= 2 }
        #expect(transport.streamCalls == 0)
        #expect(recorder.states.contains { $0.isPolling })
        await session.finish()
        recorder.stop()
    }

    @Test func anIncompatibleServiceStopsRetrying() async throws {
        let transport = FakeTransport(
            snapshot: { _ in throw MonitoringClientFailure.incompatible(.legacyPayload) },
            stream: { _ in AsyncThrowingStream { $0.finish(throwing: MonitoringClientFailure.incompatible(.legacyPayload)) } }
        )
        let recorder = UpdateRecorder()
        let session = MonitoringSession(
            transport: transport, configuration: MonitoringSessionConfiguration(connection: try Self.connection()),
            timing: Self.fastTiming
        )
        recorder.watch(session)
        await session.start()
        try await waitUntil { recorder.states.contains { if case .incompatible = $0 { true } else { false } } }
        let calls = transport.snapshotCalls
        try await Task.sleep(for: .milliseconds(80))
        #expect(transport.snapshotCalls == calls)
        await session.finish()
        recorder.stop()
    }

    @Test func pollingFailuresBecomeOfflineWithTheLastSnapshotKept() async throws {
        let transport = FakeTransport(
            snapshot: { call in
                if call == 0 { return try snapshot(requests: 7) }
                throw MonitoringClientFailure.unreachable
            },
            stream: { _ in AsyncThrowingStream { $0.finish() } }
        )
        let recorder = UpdateRecorder()
        let session = MonitoringSession(
            transport: transport, configuration: MonitoringSessionConfiguration(connection: try Self.connection()),
            timing: Self.fastTiming
        )
        recorder.watch(session)
        await session.start()
        try await waitUntil { recorder.states.contains { if case .offline = $0 { true } else { false } } }
        #expect(recorder.lastSnapshot?.today.requests == 7)
        await session.finish()
        recorder.stop()
    }

    private static let fastTiming = MonitoringTiming(
        pollInterval: .milliseconds(15), streamRetryEveryPolls: 2,
        initialRetryDelays: [.milliseconds(5)], jitter: 0
    )

    private static func connection() throws -> MonitoringConnection {
        try MonitoringConnection(baseURLString: "https://monitor.test", token: nil)
    }
}

private final class FakeTransport: MonitoringTransport, @unchecked Sendable {
    private let snapshotCounts = Mutex(0)
    private let streams = Mutex(0)
    private let snapshotHandler: @Sendable (Int) async throws -> MonitoringSnapshot
    private let streamHandler: @Sendable (Int) -> AsyncThrowingStream<MonitoringSnapshot, any Error>

    init(
        snapshot: @escaping @Sendable (Int) async throws -> MonitoringSnapshot,
        stream: @escaping @Sendable (Int) -> AsyncThrowingStream<MonitoringSnapshot, any Error>
    ) {
        snapshotHandler = snapshot
        streamHandler = stream
    }

    var snapshotCalls: Int { snapshotCounts.withLock { $0 } }
    var streamCalls: Int { streams.withLock { $0 } }

    func snapshot() async throws -> MonitoringSnapshot {
        let call = snapshotCounts.withLock { value -> Int in
            defer { value += 1 }
            return value
        }
        return try await snapshotHandler(call)
    }

    func recent(_ query: MonitoringRequestQuery) async throws -> MonitoringRecentPage {
        throw MonitoringClientFailure.missingEndpoint(nil)
    }

    nonisolated func snapshots() -> AsyncThrowingStream<MonitoringSnapshot, any Error> {
        let call = streams.withLock { value -> Int in
            defer { value += 1 }
            return value
        }
        return streamHandler(call)
    }
}

private final class UpdateRecorder: @unchecked Sendable {
    private let updates = Mutex<[MonitoringSessionUpdate]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)

    func watch(_ session: MonitoringSession) {
        let task = Task { [weak self] in
            for await update in session.updates {
                self?.updates.withLock { $0.append(update) }
            }
        }
        self.task.withLock { $0 = task }
    }

    func stop() {
        task.withLock { $0?.cancel(); $0 = nil }
    }

    var snapshotCount: Int {
        updates.withLock { $0.filter { if case .snapshot = $0 { true } else { false } }.count }
    }

    var snapshots: [MonitoringSnapshot] {
        updates.withLock {
            $0.compactMap { update in
                if case .snapshot(let snapshot, _) = update { snapshot } else { nil }
            }
        }
    }

    var lastSnapshot: MonitoringSnapshot? { snapshots.last }

    var states: [MonitoringConnectionState] {
        updates.withLock {
            $0.compactMap { update in
                if case .state(let state) = update { state } else { nil }
            }
        }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(3), _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("The condition didn't hold within \(timeout).")
}
