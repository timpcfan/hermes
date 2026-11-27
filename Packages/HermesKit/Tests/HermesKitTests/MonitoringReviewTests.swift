import Foundation
import Security
import Synchronization
import Testing
@testable import HermesKit

private func reviewFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/MonitoringReview"))
    return try Data(contentsOf: url)
}

private func reviewObject(_ name: String = "snapshot-v1") throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: reviewFixture(name)) as? [String: Any])
}

private func reviewData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func reviewSnapshot(at: Double = 100, day: String = "2026-11-27") throws -> MonitoringSnapshot {
    var object = try reviewObject()
    object["snapshot_at"] = at
    object["day"] = day
    return try MonitoringSnapshot(data: reviewData(object))
}

@Suite("Monitoring review contract")
struct MonitoringReviewContractTests {
    @Test func actualBackendFieldsArePreserved() throws {
        let snapshot = try MonitoringSnapshot(data: reviewFixture("snapshot-v1"))
        let model = try #require(snapshot.models.items.first { $0.key == "fixture-http-a" })
        #expect(model.canceled == 1)
        #expect(model.buckets.first?.canceled == 1)
        #expect(model.buckets.first?.hour == 9)
        #expect(model.buckets.first?.label == "09–12")
        #expect(String(describing: snapshot.models.bucketHours) == "3")
        #expect(String(describing: snapshot.pricing?.at) == "Optional(1795735859.834854)")
        let recent = try MonitoringRecentPage(data: reviewFixture("recent-v1"))
        #expect(recent.total == 8)
        #expect(recent.items.count == 5)
    }

    @Test func distinctNonemptyWireBucketsKeepTheirHoursAndIdentity() throws {
        // The server's h/i/cxl shape, with an additional nonempty business-hour bucket.
        let value = try #require(JSONValue.parse(#"{"key":"synthetic","buckets":[{"i":1,"h":3,"n":2,"cxl":1},{"i":3,"h":9,"n":4,"cxl":0}]}"#))
        let buckets = MonitoringModelItem(value).buckets
        #expect(buckets.map(\.hour) == [3, 9])
        #expect(Set(buckets.map(\.id)).count == 2)
        #expect(buckets.map(\.requests) == [2, 4])
    }

    @Test func nullTunnelsAreDifferentFromMeasuredZero() throws {
        let unknown = MonitoringExit(try #require(JSONValue.parse(#"{"name":"synthetic","tunnels":null}"#)))
        let zero = MonitoringExit(try #require(JSONValue.parse(#"{"name":"synthetic","tunnels":0}"#)))
        #expect(unknown.tunnels == nil)
        #expect(zero.tunnels == 0)
    }

    @Test func rejectsFractionalStringAndBooleanSchemas() throws {
        for invalid: Any in [1.5, "1", true] {
            var snapshot = try reviewObject()
            snapshot["schema_version"] = invalid
            #expect(throws: MonitoringContractError.self) { _ = try MonitoringSnapshot(data: reviewData(snapshot)) }
            var recent = try reviewObject("recent-v1")
            recent["schema_version"] = invalid
            #expect(throws: MonitoringContractError.self) { _ = try MonitoringRecentPage(data: reviewData(recent)) }
        }
    }

    @Test func rejectsErrorEnvelopesAndIncompleteEndpointStructures() throws {
        let error = Data(#"{"schema_version":1,"scope":"xunxin","error":"not ready"}"#.utf8)
        #expect(throws: MonitoringContractError.self) { _ = try MonitoringSnapshot(data: error) }
        #expect(throws: MonitoringContractError.self) { _ = try MonitoringRecentPage(data: error) }
        for key in ["day", "timezone", "snapshot_at", "today", "models", "exits", "recent", "recent_day", "inflight", "events"] {
            var object = try reviewObject()
            object.removeValue(forKey: key)
            #expect(throws: MonitoringContractError.self) { _ = try MonitoringSnapshot(data: reviewData(object)) }
        }
        for key in ["day", "timezone", "n_day", "n_now", "upto", "page", "size", "pages", "total", "items"] {
            var object = try reviewObject("recent-v1")
            object.removeValue(forKey: key)
            #expect(throws: MonitoringContractError.self) { _ = try MonitoringRecentPage(data: reviewData(object)) }
        }
        var wrongType = try reviewObject()
        wrongType["today"] = []
        #expect(throws: MonitoringContractError.self) { _ = try MonitoringSnapshot(data: reviewData(wrongType)) }
        wrongType = try reviewObject("recent-v1")
        wrongType["items"] = [:]
        #expect(throws: MonitoringContractError.self) { _ = try MonitoringRecentPage(data: reviewData(wrongType)) }
    }

    @Test func acceptsDocumentedNullsAndUnknownExtensions() throws {
        var object = try reviewObject()
        object["extension_field"] = ["future": true]
        object["inflight"] = NSNull()
        object["pricing"] = ["at": NSNull(), "err": "unavailable", "n": 0]
        object["trace"] = ["ok": NSNull(), "err": NSNull()]
        let snapshot = try MonitoringSnapshot(data: reviewData(object))
        #expect(snapshot.trace.ok == nil)
        #expect(snapshot.pricing?.at == nil)
        var recent = try reviewObject("recent-v1")
        recent["day_cost"] = NSNull()
        recent["extension_field"] = true
        #expect(try MonitoringRecentPage(data: reviewData(recent)).dayCost == nil)
    }

    @Test func rejectsInvalidOffsetSyntaxAndRange() throws {
        for offset in ["+8:00", "+08:60", "+24:00", "+14:01", "+08", "+08:00:00", " +08:00", "−08:00"] {
            #expect(MonitoringTime.timeZone(offset: offset).secondsFromGMT() == 0)
            var object = try reviewObject()
            object["timezone"] = offset
            #expect(throws: MonitoringContractError.self) { _ = try MonitoringSnapshot(data: reviewData(object)) }
        }
        #expect(MonitoringTime.timeZone(offset: "-03:30").secondsFromGMT() == -12_600)
        #expect(MonitoringTime.timeZone(offset: "+14:00").secondsFromGMT() == 50_400)
    }
}

@Suite("Monitoring review transport", .serialized)
struct MonitoringReviewTransportTests {
    @Test func monitorDelegateDoesNotConsultGatewayCredentials() async throws {
        let session = MonitoringClient.makeSession()
        defer { session.invalidateAndCancel() }
        #expect(!(session.delegate is SameOriginRedirects))
        let url = try #require(URL(string: "https://isolated-monitor.test/monitor"))
        let gateway = UUID()
        GatewayAccessRegistry.shared.set(.init(method: .serviceToken, headers: ["X-Synthetic-Secret": "chat-only"], cookies: ["synthetic": "chat-only"], clientCertificate: URLCredential(user: "synthetic", password: "chat-only", persistence: .none)), for: gateway, at: [url])
        defer { GatewayAccessRegistry.shared.forget(gateway) }
        let delegate = try #require(session.delegate as? any URLSessionTaskDelegate)
        let task = session.dataTask(with: url)
        let space = URLProtectionSpace(host: "isolated-monitor.test", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodClientCertificate)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: ReviewChallengeSender())
        let answer = await withCheckedContinuation { continuation in
            delegate.urlSession?(session, task: task, didReceive: challenge) { disposition, credential in
                continuation.resume(returning: (disposition, credential))
            }
        }
        #expect(answer.0 != .useCredential)
        #expect(answer.1 == nil)
        #expect(GatewayAccessRegistry.shared.recentChallenge(at: url) == nil)
        let original = URLRequest(url: url)
        for destination in ["https://isolated-monitor.test/new", "http://isolated-monitor.test/new", "https://elsewhere.test/new", "https://isolated-monitor.test:8443/new", "https://user:synthetic@isolated-monitor.test/new"] {
            let to = try #require(URL(string: destination))
            var redirected = URLRequest(url: to)
            redirected.setValue("chat-only", forHTTPHeaderField: "Cookie")
            redirected.setValue("chat-only", forHTTPHeaderField: "X-Synthetic-Secret")
            let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
            let result: URLRequest? = await withCheckedContinuation { continuation in
                delegate.urlSession?(session, task: session.dataTask(with: original), willPerformHTTPRedirection: response, newRequest: redirected, completionHandler: { continuation.resume(returning: $0) })
            }
            if destination == "https://isolated-monitor.test/new" {
                #expect(result != nil)
                #expect(result?.value(forHTTPHeaderField: "Cookie") == nil)
                #expect(result?.value(forHTTPHeaderField: "X-Synthetic-Secret") == nil)
            } else { #expect(result == nil) }
        }
        let upgradeTask = session.dataTask(with: URL(string: "http://isolated-monitor.test/monitor")!)
        let response = HTTPURLResponse(url: upgradeTask.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let upgrade: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession?(session, task: upgradeTask, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url), completionHandler: { continuation.resume(returning: $0) })
        }
        #expect(upgrade == nil)
    }

    @Test func pingOnlyConnectionCheckTimesOutAndStopsTheConsumer() async throws {
        let fixture = try ReviewHTTPFixture(mode: .ping)
        defer { fixture.close() }
        let clock = ContinuousClock()
        let start = clock.now
        let result = await fixture.client.check(timeout: .milliseconds(40))
        #expect(start.duration(to: clock.now) < .milliseconds(250))
        #expect(result.snapshot.state == .ok)
        #expect(result.recent.state == .ok)
        #expect(result.stream.state == .timedOut)
        try await reviewWait(timeout: .milliseconds(100)) { fixture.active == 0 }
        #expect(fixture.active == 0)
    }

    @Test func successfulHandshakeAndCancelledChecksLeaveNoStream() async throws {
        let fixture = try ReviewHTTPFixture(mode: .snapshot)
        defer { fixture.close() }
        let result = await fixture.client.check(timeout: .milliseconds(100))
        #expect(result.stream.state == .ok)
        try await reviewWait(timeout: .milliseconds(100)) { fixture.active == 0 }
        #expect(fixture.active == 0)
        let ping = try ReviewHTTPFixture(mode: .ping)
        defer { ping.close() }
        let check = Task { await ping.client.check(timeout: .seconds(2)) }
        try await reviewWait { ping.active > 0 }
        let clock = ContinuousClock()
        let start = clock.now
        check.cancel()
        _ = await check.value
        #expect(start.duration(to: clock.now) < .milliseconds(250))
        try await reviewWait(timeout: .milliseconds(100)) { ping.active == 0 }
        #expect(ping.active == 0)
    }

    @Test func errorEnvelopesCannotPassAnyConnectionCheckStep() async throws {
        let fixture = try ReviewHTTPFixture(mode: .envelope)
        defer { fixture.close() }
        let result = await fixture.client.check(timeout: .milliseconds(100))
        #expect(result.snapshot.state == .failed)
        #expect(result.recent.state == .failed)
        #expect(result.stream.state == .failed)
        try await reviewWait(timeout: .milliseconds(100)) { fixture.active == 0 }
        #expect(fixture.active == 0)
    }

    @Test func rapidStopStartDoesNotLeaveAnOldStreamActive() async throws {
        let fixture = try ReviewHTTPFixture(mode: .ping)
        defer { fixture.close() }
        let session = MonitoringSession(transport: fixture.client,
            configuration: .init(connection: await fixture.client.connection))
        for _ in 0..<5 {
            await session.start()
            try await reviewWait { fixture.activeStreams.withLock { $0 } > 0 }
            await session.stop()
        }
        await session.finish()
        try await reviewWait(timeout: .milliseconds(100)) { fixture.active == 0 }
        #expect(fixture.maximumStreams.withLock { $0 } == 1)
        #expect(fixture.active == 0)
    }

    @Test func runtimeWatchdogClosesRealPingStreamBeforePollingAndRetry() async throws {
        let fixture = try ReviewHTTPFixture(mode: .ping)
        defer { fixture.close() }
        let session = MonitoringSession(transport: fixture.client,
            configuration: .init(connection: await fixture.client.connection),
            timing: .init(pollInterval: .milliseconds(25), streamRetryEveryPolls: 2,
                          initialRetryDelays: [.milliseconds(1)], jitter: 0))
        let recorder = ReviewRecorder(session)
        await session.start()
        try await reviewWait { recorder.states.contains { $0.isPolling } && fixture.streamStarts.withLock { $0 } >= 2 }
        #expect(recorder.states.contains { $0.isPolling })
        #expect(fixture.streamStarts.withLock { $0 } >= 2)
        #expect(fixture.maximumStreams.withLock { $0 } == 1)
        await session.finish()
        try await reviewWait(timeout: .milliseconds(100)) { fixture.active == 0 }
        #expect(fixture.active == 0)
        recorder.stop()
    }

    @Test func sameOriginRedirectKeepsOnlyMonitorOwnedBearer() async throws {
        let session = MonitoringClient.makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try #require(session.delegate as? any URLSessionTaskDelegate)
        let url = URL(string: "https://synthetic.invalid/monitor")!
        var original = URLRequest(url: url)
        original.setValue("Bearer synthetic-monitor", forHTTPHeaderField: "Authorization")
        original.setValue("application/json", forHTTPHeaderField: "Accept")
        var next = URLRequest(url: url.appending(path: "next"))
        next.setValue("Bearer synthetic-chat", forHTTPHeaderField: "Authorization")
        next.setValue("synthetic-chat", forHTTPHeaderField: "Cookie")
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let result: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession?(session, task: session.dataTask(with: original), willPerformHTTPRedirection: response,
                                 newRequest: next, completionHandler: { continuation.resume(returning: $0) })
        }
        #expect(result?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-monitor")
        #expect(result?.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func stalledSnapshotAndRecentChecksAreBounded() async throws {
        let fixture = try ReviewHTTPFixture(mode: .stall)
        defer { fixture.close() }
        let clock = ContinuousClock()
        let start = clock.now
        let result = await fixture.client.check(timeout: .milliseconds(40))
        #expect(start.duration(to: clock.now) < .milliseconds(250))
        #expect(result.snapshot.state == .timedOut)
        #expect(result.recent.state == .timedOut)
        #expect(result.stream.state == .timedOut)
        try await reviewWait(timeout: .milliseconds(100)) { fixture.active == 0 }
        #expect(fixture.active == 0)
    }
}

private final class ReviewChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private final class ReviewHTTPFixture: @unchecked Sendable {
    enum Mode: Sendable { case ping, snapshot, stall, envelope }
    let mode: Mode
    let snapshotData: Data
    let recentData: Data
    let counts = Mutex(0)
    let maximumStreams = Mutex(0)
    let activeStreams = Mutex(0)
    let streamStarts = Mutex(0)
    let session: URLSession
    let client: MonitoringClient
    let host: String
    init(mode: Mode) throws {
        self.mode = mode
        snapshotData = mode == .envelope ? Data(#"{"schema_version":1,"scope":"xunxin","error":"not ready"}"#.utf8) : try reviewFixture("snapshot-v1")
        recentData = mode == .envelope ? snapshotData : try reviewFixture("recent-v1")
        host = "fixture-\(UUID().uuidString.lowercased()).invalid"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewURLProtocol.self]
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
        client = MonitoringClient(connection: try MonitoringConnection(baseURLString: "https://\(host)", token: nil), session: session)
        ReviewURLProtocol.fixtures.withLock { $0[host] = self }
    }
    var active: Int { counts.withLock { $0 } }
    func close() {
        session.invalidateAndCancel()
        _ = ReviewURLProtocol.fixtures.withLock { $0.removeValue(forKey: host) }
    }
}

private final class ReviewURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = Mutex<[String: ReviewHTTPFixture]>([:])
    private let state = Mutex<(Task<Void, Never>?, ReviewHTTPFixture?)>((nil, nil))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixtures.withLock({ $0[request.url?.host ?? ""] }), let url = request.url else { return }
        fixture.counts.withLock { $0 += 1 }
        state.withLock { $0.1 = fixture }
        let stream = url.path.hasSuffix("/stream")
        if stream {
            let active = fixture.activeStreams.withLock { $0 += 1; return $0 }
            fixture.maximumStreams.withLock { $0 = max($0, active) }
            fixture.streamStarts.withLock { $0 += 1 }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": stream ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        if fixture.mode != .stall, !stream {
            client?.urlProtocol(self, didLoad: url.path.hasSuffix("/recent") ? fixture.recentData : fixture.snapshotData)
            client?.urlProtocolDidFinishLoading(self)
            complete()
            return
        }
        let task = Task { @Sendable [self, fixture, stream] in
            if stream, fixture.mode == .snapshot || fixture.mode == .envelope {
                client?.urlProtocol(self, didLoad: Data("event: snapshot\ndata: \(String(decoding: fixture.snapshotData, as: UTF8.self).components(separatedBy: .newlines).joined())\n\n".utf8))
            }
            // A finite safety cap makes a broken baseline fail an assertion, never hang CI.
            for _ in 0..<80 {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                if fixture.mode != .stall { client?.urlProtocol(self, didLoad: Data(": ping\n\n".utf8)) }
            }
            client?.urlProtocolDidFinishLoading(self)
            complete()
        }
        state.withLock { $0.0 = task }
    }
    override func stopLoading() {
        state.withLock { $0.0?.cancel(); $0.0 = nil }
        complete()
    }
    private func complete() {
        let fixture = state.withLock { value -> ReviewHTTPFixture? in
            defer { value.1 = nil }
            return value.1
        }
        fixture?.counts.withLock { $0 -= 1 }
        if request.url?.path.hasSuffix("/stream") == true { fixture?.activeStreams.withLock { $0 -= 1 } }
    }
}

@Suite("Monitoring review persistence", .serialized)
struct MonitoringReviewPersistenceTests {
    @Test func unreadableOldTokenAbortsBeforeAnyWrite() throws {
        let fixture = try ReviewSettingsFixture()
        defer { fixture.close() }
        fixture.memory.failure.withLock { $0 = .read }
        #expect(throws: (any Error).self) { try fixture.store.save(fixture.changed, token: "synthetic-new") }
        fixture.memory.failure.withLock { $0 = .none }
        #expect(try fixture.store.load() == fixture.old)
        #expect(try fixture.store.storedToken() == "synthetic-old")
        #expect(fixture.memory.secretWrites.withLock { $0 } == 1)
    }

    @Test func failedCredentialStagePreservesOldConfiguration() throws {
        let fixture = try ReviewSettingsFixture()
        defer { fixture.close() }
        fixture.memory.failure.withLock { $0 = .write }
        #expect(throws: (any Error).self) { try fixture.store.save(fixture.changed, token: "synthetic-new") }
        fixture.memory.failure.withLock { $0 = .none }
        #expect(try fixture.store.load() == fixture.old)
        #expect(try fixture.store.storedToken() == "synthetic-old")
    }

    @Test func failedCommitAndFailedCompensationNeverReplaceOldEffectiveToken() throws {
        let fixture = try ReviewSettingsFixture()
        defer { fixture.close() }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        fixture.memory.failure.withLock { $0 = .compensation }
        var failure: (any Error)?
        do { try fixture.store.save(fixture.changed, token: "synthetic-new") }
        catch { failure = error }
        #expect(failure != nil)
        #expect(String(describing: failure).lowercased().contains("cleanup"))
        fixture.memory.failure.withLock { $0 = .none }
        #expect(try fixture.store.load() == fixture.old)
        #expect(try fixture.store.storedToken() == "synthetic-old")
    }

    @Test func failureAfterStagingKeepsOldEffectiveTokenAndReportsCleanupFailure() throws {
        for fault in [ReviewKeychain.Failure.afterWrite, .afterWriteCleanup] {
            let fixture = try ReviewSettingsFixture()
            defer { fixture.close() }
            fixture.memory.failure.withLock { $0 = fault }
            var failure: (any Error)?
            do { try fixture.store.save(fixture.changed, token: "synthetic-new") }
            catch { failure = error }
            #expect(failure != nil)
            if fault == .afterWriteCleanup {
                #expect(String(describing: failure).lowercased().contains("cleanup"))
            } else {
                #expect(fixture.memory.values.withLock { $0.count } == 1)
            }
            fixture.memory.failure.withLock { $0 = .none }
            #expect(try fixture.store.load() == fixture.old)
            #expect(try fixture.store.storedToken() == "synthetic-old")
        }
    }

    @Test func legacySettingsAndAtomicCredentialReferencesRoundTrip() throws {
        let fixture = try ReviewSettingsFixture()
        defer { fixture.close() }
        #expect(try fixture.store.load() == fixture.old)
        #expect(try fixture.store.storedToken() == "synthetic-old")
        try fixture.store.save(fixture.changed, token: "synthetic-new")
        let reopened = MonitoringSettingsStore(fileURL: fixture.store.fileURL, keychain: fixture.memory.store)
        #expect(try reopened.load() == fixture.changed)
        #expect(try reopened.storedToken() == "synthetic-new")
        try reopened.save(fixture.old, token: nil)
        #expect(try reopened.storedToken() == "synthetic-new")
        let raw = try String(contentsOf: reopened.fileURL, encoding: .utf8)
        #expect(!raw.contains("synthetic-old"))
        #expect(!raw.contains("synthetic-new"))
    }
}

private struct ReviewSettingsFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: "monitoring-review-\(UUID())")
    let memory = ReviewKeychain()
    let old = MonitoringSettings(enabled: true, name: "Synthetic", baseURL: "https://old.invalid", auth: .bearer)
    var changed: MonitoringSettings { MonitoringSettings(enabled: true, name: "Changed", baseURL: "https://new.invalid", auth: .bearer) }
    let store: MonitoringSettingsStore
    init() throws {
        store = MonitoringSettingsStore(fileURL: directory.appending(path: "settings.json"), keychain: memory.store)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: store.fileURL)
        try memory.store.setString("synthetic-old", for: MonitoringSettingsStore.tokenAccount)
    }
    func close() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ReviewKeychain: @unchecked Sendable {
    enum Failure { case none, read, write, compensation, afterWrite, afterWriteCleanup }
    let failure = Mutex(Failure.none)
    let values = Mutex<[String: Data]>([:])
    let secretWrites = Mutex(0)
    let service = "synthetic.monitoring.\(UUID())"
    var store: KeychainStore {
        KeychainStore(service: service, macFallback: .processMemory, calls: .init(
            copyMatching: { query in
                if self.failure.withLock({ $0 == .read }) { return (errSecAuthFailed, nil) }
                guard let value = self.values.withLock({ $0[self.account(query)] }) else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, value)
            },
            update: { query, attrs in
                guard let data = attrs[kSecValueData as String] as? Data else { return errSecSuccess }
                if self.failure.withLock({ $0 == .write || $0 == .compensation && self.secretWrites.withLock { $0 >= 2 } }) { return errSecAuthFailed }
                return self.values.withLock {
                    guard $0[self.account(query)] != nil else { return errSecItemNotFound }
                    $0[self.account(query)] = data
                    self.secretWrites.withLock { $0 += 1 }
                    if self.failure.withLock({ $0 == .afterWrite || $0 == .afterWriteCleanup }) { return errSecAuthFailed }
                    return errSecSuccess
                }
            },
            add: { query in
                if self.failure.withLock({ $0 == .write }) { return errSecAuthFailed }
                self.values.withLock { $0[self.account(query)] = query[kSecValueData as String] as? Data }
                self.secretWrites.withLock { $0 += 1 }
                if self.failure.withLock({ $0 == .afterWrite || $0 == .afterWriteCleanup }) { return errSecAuthFailed }
                return errSecSuccess
            },
            delete: { query in
                if self.failure.withLock({ $0 == .compensation || $0 == .afterWriteCleanup }) { return errSecAuthFailed }
                _ = self.values.withLock { $0.removeValue(forKey: self.account(query)) }
                return errSecSuccess
            }
        ))
    }
    private func account(_ query: [String: Any]) -> String { query[kSecAttrAccount as String] as? String ?? "" }
}

@Suite("Monitoring review session", .serialized)
struct MonitoringReviewSessionTests {
    @Test func silentOrStaleStreamsFallBackWithOnlyOneActiveConsumer() async throws {
        for stale in [false, true] {
            let transport = ReviewTransport()
            transport.staleStream = stale
            let session = try makeSession(transport)
            let recorder = ReviewRecorder(session)
            await session.start()
            try await reviewWait { recorder.states.contains { $0.isPolling } && transport.calls.withLock { $0 } > 1 }
            #expect(recorder.states.contains { $0.isPolling })
            #expect(transport.calls.withLock { $0 } > 1)
            #expect(transport.maximumActive.withLock { $0 } == 1)
            await session.finish()
            try await reviewWait { transport.active.withLock { $0 } == 0 }
            #expect(transport.active.withLock { $0 } == 0)
            recorder.stop()
        }
    }

    @Test func successfulPollRestoresPollingAfterOffline() async throws {
        let transport = ReviewTransport()
        transport.handler = { call in
            if call == 1 || call == 2 { throw MonitoringClientFailure.unreachable }
            return try reviewSnapshot(at: Double(100 + call))
        }
        let session = try makeSession(transport, streaming: false)
        let recorder = ReviewRecorder(session)
        await session.start()
        try await reviewWait {
            let states = recorder.states
            guard let offline = states.firstIndex(where: { if case .offline = $0 { true } else { false } }) else { return false }
            return states.dropFirst(offline + 1).contains { $0.isPolling }
        }
        let states = recorder.states
        let offline = try #require(states.firstIndex { if case .offline = $0 { true } else { false } })
        #expect(states.dropFirst(offline + 1).contains { $0.isPolling })
        #expect(states.last?.isPolling == true)
        await session.finish()
        recorder.stop()
    }

    @Test func lateRefreshCannotRollBackANewerStreamBusinessDay() async throws {
        let transport = ReviewTransport()
        let gate = ReviewGate()
        transport.handler = { call in
            if call == 1 { await gate.wait(); return try reviewSnapshot(at: 99) }
            return try reviewSnapshot(at: 100)
        }
        let session = try makeSession(transport, pollInterval: .seconds(1))
        let recorder = ReviewRecorder(session)
        await session.start()
        try await reviewWait { transport.streams.withLock { !$0.isEmpty } }
        await session.refresh()
        try await reviewWait { transport.calls.withLock { $0 } == 2 }
        transport.yield(try reviewSnapshot(at: 101, day: "2026-11-28"))
        try await reviewWait { recorder.snapshots.last?.day == "2026-11-28" }
        await gate.release()
        try await Task.sleep(for: .milliseconds(15))
        #expect(recorder.snapshots.last?.day == "2026-11-28")
        #expect(recorder.snapshots.last?.snapshotAt == 101)
        await session.finish()
        recorder.stop()
    }

    @Test func replacedRefreshCannotPublishEvenANewerTimestamp() async throws {
        let transport = ReviewTransport()
        let gate = ReviewGate()
        transport.handler = { call in
            if call == 1 { await gate.wait(); return try reviewSnapshot(at: 999) }
            return try reviewSnapshot(at: Double(100 + call))
        }
        let session = try makeSession(transport, pollInterval: .seconds(1))
        let recorder = ReviewRecorder(session)
        await session.start()
        try await reviewWait { transport.streams.withLock { !$0.isEmpty } }
        await session.refresh()
        try await reviewWait { transport.calls.withLock { $0 } == 2 }
        await session.refresh()
        try await reviewWait { recorder.snapshots.last?.snapshotAt == 102 }
        await gate.release()
        try await Task.sleep(for: .milliseconds(15))
        #expect(!recorder.snapshots.contains { $0.snapshotAt == 999 })
        await session.finish()
        recorder.stop()
    }

    @Test func incompatibleInitialSnapshotDoesNotOpenAStream() async throws {
        let transport = ReviewTransport()
        transport.handler = { _ in throw MonitoringClientFailure.incompatible(.legacyPayload) }
        let session = try makeSession(transport)
        await session.start()
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.streams.withLock { $0.isEmpty })
        await session.finish()
    }

    private func makeSession(_ transport: ReviewTransport, streaming: Bool = true, pollInterval: Duration = .milliseconds(10)) throws -> MonitoringSession {
        MonitoringSession(transport: transport,
            configuration: .init(connection: try MonitoringConnection(baseURLString: "https://synthetic.invalid", token: nil), allowsStreaming: streaming),
            timing: .init(pollInterval: pollInterval, streamRetryEveryPolls: 2, initialRetryDelays: [.milliseconds(1)], jitter: 0))
    }
}

private actor ReviewGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class ReviewTransport: MonitoringTransport, @unchecked Sendable {
    let calls = Mutex(0)
    let active = Mutex(0)
    let maximumActive = Mutex(0)
    let streams = Mutex<[AsyncThrowingStream<MonitoringSnapshot, any Error>.Continuation]>([])
    var staleStream = false
    var handler: @Sendable (Int) async throws -> MonitoringSnapshot = { call in try reviewSnapshot(at: Double(100 + call)) }
    func snapshot() async throws -> MonitoringSnapshot {
        let call = calls.withLock { value in defer { value += 1 }; return value }
        return try await handler(call)
    }
    func recent(_ query: MonitoringRequestQuery) async throws -> MonitoringRecentPage { try MonitoringRecentPage(data: reviewFixture("recent-v1")) }
    func snapshots() -> AsyncThrowingStream<MonitoringSnapshot, any Error> {
        let stream = AsyncThrowingStream<MonitoringSnapshot, any Error>.makeStream()
        let count = active.withLock { $0 += 1; return $0 }
        maximumActive.withLock { $0 = max($0, count) }
        streams.withLock { $0.append(stream.continuation) }
        let stale = staleStream
        let producer = Task {
            if stale {
                for _ in 0..<100 {
                    if Task.isCancelled { return }
                    stream.continuation.yield(try! reviewSnapshot(at: 1))
                    do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                }
            }
        }
        stream.continuation.onTermination = { [self] _ in
            producer.cancel()
            active.withLock { $0 -= 1 }
        }
        return stream.stream
    }
    func yield(_ snapshot: MonitoringSnapshot) { streams.withLock { $0.last }?.yield(snapshot) }
}

private final class ReviewRecorder: @unchecked Sendable {
    let values = Mutex<[MonitoringSessionUpdate]>([])
    private var task: Task<Void, Never>?
    init(_ session: MonitoringSession) {
        task = Task { [weak self] in
            for await update in session.updates { self?.values.withLock { $0.append(update) } }
        }
    }
    var snapshots: [MonitoringSnapshot] { values.withLock { $0.compactMap { if case .snapshot(let snapshot, _) = $0 { snapshot } else { nil } } } }
    var states: [MonitoringConnectionState] { values.withLock { $0.compactMap { if case .state(let state) = $0 { state } else { nil } } } }
    func stop() { task?.cancel() }
}

private func reviewWait(timeout: Duration = .seconds(2), _ condition: @escaping @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock()
    let end = clock.now + timeout
    while clock.now < end {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Synthetic condition did not become true")
}
