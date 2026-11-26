import Foundation

/// Talks to the monitor service (`_brief/INTERFACES.md`): a scoped snapshot, a page of the day's
/// requests and the live SSE stream. Every answer is checked for the scoped contract before it is
/// handed back: a service that ignores `scope` answers the website's global payload, and showing
/// that as Xunxin's would be worse than an error.
public actor MonitoringClient {
    public let connection: MonitoringConnection
    private let session: URLSession

    public init(connection: MonitoringConnection, session: URLSession? = nil) {
        self.connection = connection
        self.session = session ?? Self.makeSession()
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        // The token only ever goes to the server it was saved for.
        return URLSession(configuration: configuration, delegate: SameOriginRedirects.shared, delegateQueue: nil)
    }

    // MARK: - Calls

    public func snapshot() async throws -> MonitoringSnapshot {
        let request = makeRequest(path: "api/snapshot", query: [URLQueryItem(name: "scope", value: MonitoringSnapshot.scope)])
        let (data, response) = try await load(request)
        try checkContentType(response, allowing: ["application/json", "text/json"])
        do {
            return try MonitoringSnapshot(data: data)
        } catch let error as MonitoringContractError {
            throw MonitoringClientFailure.incompatible(error)
        }
    }

    public func recent(_ query: MonitoringRequestQuery) async throws -> MonitoringRecentPage {
        let request = makeRequest(path: "api/recent", query: query.queryItems)
        let (data, response) = try await load(request)
        try checkContentType(response, allowing: ["application/json", "text/json"])
        do {
            return try MonitoringRecentPage(data: data)
        } catch let error as MonitoringContractError {
            throw MonitoringClientFailure.incompatible(error)
        }
    }

    /// The scoped snapshot stream. The first frame arrives at once and the service corrects it
    /// about every 3 s; the stream ends when the connection does, and the caller falls back to
    /// polling while it is gone.
    public nonisolated func snapshots() -> AsyncThrowingStream<MonitoringSnapshot, any Error> {
        let request = makeRequest(path: "api/stream", query: [URLQueryItem(name: "scope", value: MonitoringSnapshot.scope)],
                                  accept: "text/event-stream", timeout: 30)
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw MonitoringClientFailure.notMonitoringService
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 64_000 { break }
                        }
                        throw Self.failure(status: http.statusCode, body: body)
                    }
                    try Self.checkStreamContentType(http)
                    var parser = ServerSentEventParser()
                    for try await byte in bytes {
                        guard let event = parser.consume(byte), event.event == "snapshot" else { continue }
                        do {
                            continuation.yield(try MonitoringSnapshot(data: Data(event.data.utf8)))
                        } catch let error as MonitoringContractError {
                            throw MonitoringClientFailure.incompatible(error)
                        }
                    }
                    throw MonitoringClientFailure.streamEnded
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: Self.transportFailure(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The settings screen's three checks, bounded so a silent service can't hold the form. All
    /// three run together; a slow stream doesn't make the snapshot and requests checks wait for
    /// each other, and each reports its own state.
    public func check(timeout: Duration = .seconds(8)) async -> MonitoringConnectionCheck {
        async let snapshot = checkStep(timeout: timeout) { try await self.snapshot() }
        async let recent = checkStep(timeout: timeout) { try await self.recent(MonitoringRequestQuery(size: 1)) }
        async let stream = checkStep(timeout: timeout) { try await self.firstStreamSnapshot(timeout: timeout) }
        return await MonitoringConnectionCheck(snapshot: snapshot, recent: recent, stream: stream)
    }

    private func checkStep<T: Sendable>(timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async -> MonitoringCheckStep {
        do {
            _ = try await withMonitoringTimeout(timeout, operation: operation)
            return MonitoringCheckStep(state: .ok)
        } catch is CancellationError {
            return MonitoringCheckStep(state: .failed, detail: "The check was cancelled.")
        } catch MonitoringClientFailure.timedOut {
            return MonitoringCheckStep(state: .timedOut, detail: MonitoringClientFailure.timedOut.errorDescription)
        } catch {
            return MonitoringCheckStep(state: .failed, detail: Self.describe(error))
        }
    }

    /// The first snapshot on a fresh SSE handshake, then the stream is let go: a connection check
    /// proves the service sends frames without leaving a stream reading behind.
    private func firstStreamSnapshot(timeout: Duration) async throws -> MonitoringSnapshot {
        let stream = snapshots()
        let task = Task { () throws -> MonitoringSnapshot in
            for try await snapshot in stream { return snapshot }
            throw MonitoringClientFailure.streamEnded
        }
        do {
            return try await withMonitoringTimeout(timeout) { try await task.value }
        } catch {
            task.cancel()
            throw error
        }
    }

    // MARK: - URLs and headers

    private nonisolated func makeRequest(
        path: String, query: [URLQueryItem], accept: String = "application/json", timeout: TimeInterval = 15
    ) -> URLRequest {
        var url = connection.endpoint(path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token = connection.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Answers

    private func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.transportFailure(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MonitoringClientFailure.notMonitoringService
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.failure(status: http.statusCode, body: data)
        }
        return (data, http)
    }

    private func checkContentType(_ response: HTTPURLResponse, allowing types: [String]) throws {
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard !contentType.isEmpty else { return }
        if contentType.contains("text/html") { throw MonitoringClientFailure.notMonitoringService }
        guard types.contains(where: contentType.contains) else {
            throw MonitoringClientFailure.notMonitoringService
        }
    }

    private nonisolated static func checkStreamContentType(_ response: HTTPURLResponse) throws {
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        // Some proxies omit it; the event stream itself still says what it is.
        if contentType.contains("text/html") { throw MonitoringClientFailure.notMonitoringService }
    }

    nonisolated static func failure(status: Int, body: Data) -> MonitoringClientFailure {
        let message = JSONValue.parse(body)?["error"]?.stringValue
            ?? JSONValue.parse(body)?["message"]?.stringValue
        switch status {
        case 400:
            return .refused(message)
        case 401, 403:
            return .unauthorized(status)
        case 300..<400:
            return .redirected(status)
        case 404:
            return .missingEndpoint(message)
        case 200..<300:
            return .notMonitoringService
        default:
            return .server(status, message)
        }
    }

    nonisolated static func transportFailure(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let failure = error as? MonitoringClientFailure { return failure }
        guard let urlError = error as? URLError else { return MonitoringClientFailure.connectionFailed }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return MonitoringClientFailure.timedOut
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return MonitoringClientFailure.secureConnection
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
             .notConnectedToInternet, .dataNotAllowed:
            return MonitoringClientFailure.unreachable
        default:
            return MonitoringClientFailure.transport(
                domain: (urlError as NSError).domain, code: (urlError as NSError).code
            )
        }
    }

    nonisolated static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return (error as NSError).localizedDescription
    }
}

/// What the settings screen shows for one probe.
public struct MonitoringCheckStep: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case ok, failed, timedOut
    }

    public var state: State
    public var detail: String?

    public init(state: State, detail: String? = nil) {
        self.state = state
        self.detail = detail
    }

    public var isOK: Bool { state == .ok }
}

/// The three checks together, and the mode the saved connection will run in.
public struct MonitoringConnectionCheck: Sendable, Equatable {
    public var snapshot: MonitoringCheckStep
    public var recent: MonitoringCheckStep
    public var stream: MonitoringCheckStep

    public init(snapshot: MonitoringCheckStep, recent: MonitoringCheckStep, stream: MonitoringCheckStep) {
        self.snapshot = snapshot
        self.recent = recent
        self.stream = stream
    }

    /// The snapshot and the requests list must both speak the scoped contract. The stream may
    /// fail: the app then polls every 10 s, which is still a usable connection and may be saved.
    public var isUsable: Bool { snapshot.isOK && recent.isOK }

    public var mode: MonitoringConnectionMode {
        guard isUsable else { return .unusable }
        return stream.isOK ? .live : .polling
    }

    /// The answer's one-line summary for the form.
    public var summary: String {
        switch mode {
        case .live:
            "Ready. The app updates live and falls back to a snapshot every 10 seconds if the stream drops."
        case .polling:
            "Snapshot and requests work. Live updates don't, so the app will read a snapshot every 10 seconds."
        case .unusable:
            if !snapshot.isOK { "The snapshot check failed. Fix that before saving." }
            else { "The requests check failed. Fix that before saving." }
        }
    }
}

public enum MonitoringConnectionMode: String, Sendable, Equatable {
    case live, polling, unusable
}

public enum MonitoringClientFailure: Error, Equatable, Sendable, LocalizedError {
    case unauthorized(Int)
    case refused(String?)
    case missingEndpoint(String?)
    case redirected(Int)
    case server(Int, String?)
    case notMonitoringService
    case incompatible(MonitoringContractError)
    case timedOut
    case secureConnection
    case unreachable
    case transport(domain: String, code: Int)
    case connectionFailed
    case streamEnded

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let status):
            status == 403
                ? "The monitor service refused this device (403). Check the token and the service's access rules, or choose No Authentication."
                : "The monitor service didn't accept the access token (401). Check the token, or choose No Authentication."
        case .refused(let message):
            message.map { "The monitor service refused the request: \($0)" }
                ?? "The monitor service refused the request."
        case .missingEndpoint:
            "The monitor service has no monitoring API at that address. Check that it's the service's root address."
        case .redirected:
            "The monitor service redirected to another address. Enter that address directly; the app never sends a token to a redirect's target."
        case .server(let status, _):
            "The monitor service answered \(status). Try again in a moment."
        case .notMonitoringService:
            "That address isn't a monitor service. Check the address."
        case .incompatible(let error):
            error.errorDescription
        case .timedOut:
            "The monitor service didn't answer in time. A timeout doesn't prove the token is wrong: check the address and the network."
        case .secureConnection:
            "The secure connection failed. Check the service's certificate and the address."
        case .unreachable:
            "Can't reach the monitor service. Check the address and the network."
        case .transport(let domain, let code):
            "The connection to the monitor service failed (\(domain) \(code))."
        case .connectionFailed:
            "The connection to the monitor service failed."
        case .streamEnded:
            "The live update stream ended."
        }
    }
}

/// Runs `operation`, giving up when `timeout` passes. The connection check uses it so a service
/// that accepts a connection and then says nothing can't hold the form.
func withMonitoringTimeout<T: Sendable>(
    _ timeout: Duration, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw MonitoringClientFailure.timedOut
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            throw MonitoringClientFailure.connectionFailed
        }
        return value
    }
}
