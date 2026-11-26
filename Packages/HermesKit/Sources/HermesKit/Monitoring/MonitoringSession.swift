import Foundation

/// What a session can ask of the monitor service. `MonitoringClient` is the real one; tests hand
/// in a fake so the stream/poll/generation rules can be driven without a socket.
public protocol MonitoringTransport: Sendable {
    func snapshot() async throws -> MonitoringSnapshot
    func recent(_ query: MonitoringRequestQuery) async throws -> MonitoringRecentPage
    func snapshots() -> AsyncThrowingStream<MonitoringSnapshot, any Error>
}

extension MonitoringClient: MonitoringTransport {}

/// The connection the session runs on. Turning live updates off is a saved choice: the app then
/// polls, which is what a deployment without SSE needs.
public struct MonitoringSessionConfiguration: Sendable, Equatable {
    public var connection: MonitoringConnection
    public var allowsStreaming: Bool

    public init(connection: MonitoringConnection, allowsStreaming: Bool = true) {
        self.connection = connection
        self.allowsStreaming = allowsStreaming
    }
}

/// Durations the session runs on. Tests shorten them; production uses the plan's numbers.
public struct MonitoringTiming: Sendable, Equatable {
    /// SSE is gone and snapshots work: the plan's 10 s fallback.
    public var pollInterval: Duration
    /// While polling, how many poll beats pass before another stream attempt.
    public var streamRetryEveryPolls: Int
    /// No snapshot yet: retries grow through these before repeating the last.
    public var initialRetryDelays: [Duration]
    /// A reconnection waits a little less or more than its delay.
    public var jitter: Double

    public init(
        pollInterval: Duration = .seconds(10), streamRetryEveryPolls: Int = 6,
        initialRetryDelays: [Duration] = [.seconds(3), .seconds(6), .seconds(12), .seconds(24)],
        jitter: Double = 0.2
    ) {
        self.pollInterval = pollInterval
        self.streamRetryEveryPolls = streamRetryEveryPolls
        self.initialRetryDelays = initialRetryDelays
        self.jitter = jitter
    }

    public static let standard = MonitoringTiming()
}

public enum MonitoringConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case live
    /// Polling snapshots because live updates aren't available (or are turned off).
    case polling(reason: String)
    /// No successful read yet, or the last two polls failed. The last snapshot, if any, stays.
    case offline(reason: String)
    /// The service doesn't speak the scoped contract. Retrying can't fix it.
    case incompatible(reason: String)

    public var isLive: Bool { self == .live }
    public var isPolling: Bool {
        if case .polling = self { return true }
        return false
    }
    public var hasStopped: Bool {
        switch self {
        case .incompatible, .idle: true
        default: false
        }
    }
    public var reason: String? {
        switch self {
        case .polling(let reason), .offline(let reason), .incompatible(let reason): reason
        case .idle, .connecting, .live: nil
        }
    }
}

public enum MonitoringSessionUpdate: Sendable, Equatable {
    case state(MonitoringConnectionState)
    case snapshot(MonitoringSnapshot, receivedAt: Date)
}

/// Owns one monitoring connection's live updates, its polling fallback and its generation.
///
/// The plan's lifecycle lives here rather than in a view: `start` reads a snapshot, opens the
/// stream and polls only when the stream is gone; `stop` cancels everything; `refresh` reads a
/// snapshot now. Every async step checks the generation it began with, so a response for an old
/// address can't land on a new one. The session never touches a gateway.
public actor MonitoringSession {
    nonisolated public let updates: AsyncStream<MonitoringSessionUpdate>
    private let continuation: AsyncStream<MonitoringSessionUpdate>.Continuation
    private let transport: any MonitoringTransport
    private let configuration: MonitoringSessionConfiguration
    private let timing: MonitoringTiming
    private let now: @Sendable () -> Date

    private var runTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var state: MonitoringConnectionState = .idle
    private var hasSnapshot = false

    public init(
        transport: any MonitoringTransport,
        configuration: MonitoringSessionConfiguration,
        timing: MonitoringTiming = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.configuration = configuration
        self.timing = timing
        self.now = now
        let (updates, continuation) = AsyncStream.makeStream(
            of: MonitoringSessionUpdate.self, bufferingPolicy: .bufferingNewest(32)
        )
        self.updates = updates
        self.continuation = continuation
    }

    /// Begins the connection once. A second call does nothing: a view that appears twice can't
    /// open two streams.
    public func start() {
        guard runTask == nil else { return }
        generation += 1
        let generation = self.generation
        runTask = Task { [weak self] in
            await self?.run(generation)
        }
    }

    /// Stops the stream, polling and any refresh. The last snapshot is not cleared here: what is
    /// on screen stays until the caller decides it's gone.
    public func stop() {
        generation += 1
        runTask?.cancel()
        runTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        hasSnapshot = false
        emit(.idle)
    }

    /// Reads a fresh snapshot now (returning to the foreground, Check Again). A no-op while
    /// stopped: the view's `start` reads one anyway.
    public func refresh() {
        guard runTask != nil else { return }
        refreshTask?.cancel()
        let generation = self.generation
        refreshTask = Task { [weak self] in
            await self?.readOnce(generation)
        }
    }

    /// Ends the update stream for good, when the model that owns this session goes away.
    public func finish() {
        stop()
        continuation.finish()
    }

    // MARK: - The loop

    private func run(_ generation: Int) async {
        guard isCurrent(generation) else { return }
        setState(.connecting, generation: generation)

        await readOnce(generation, initial: true)

        var retry = 0
        while isCurrent(generation) {
            if configuration.allowsStreaming {
                let outcome = await streamUntilEnded(generation)
                guard isCurrent(generation) else { return }
                switch outcome {
                case .cancelled:
                    return
                case .fatal(let failure):
                    setState(.incompatible(reason: failure), generation: generation)
                    return
                case .ended(let error):
                    setState(fallbackState(for: error), generation: generation)
                }
            } else {
                setState(.polling(reason: "Live updates are off for this connection."), generation: generation)
            }

            let wantsStreamAgain = await poll(generation)
            guard isCurrent(generation) else { return }
            guard wantsStreamAgain else { return }

            // A stream attempt after polling waits through the retry ladder and its jitter.
            let delay = timing.initialRetryDelays.isEmpty
                ? timing.pollInterval
                : timing.initialRetryDelays[min(retry, timing.initialRetryDelays.count - 1)]
            retry += 1
            if !(await sleep(jittered(delay), generation: generation)) { return }
        }
    }

    private enum StreamOutcome {
        case ended(any Error)
        case fatal(String)
        case cancelled
    }

    private func streamUntilEnded(_ generation: Int) async -> StreamOutcome {
        do {
            for try await snapshot in transport.snapshots() {
                guard isCurrent(generation) else { return .cancelled }
                apply(snapshot, generation: generation)
                if state != .live { setState(.live, generation: generation) }
            }
            return .ended(MonitoringClientFailure.streamEnded)
        } catch is CancellationError {
            return .cancelled
        } catch {
            if let failure = fatalFailure(error) { return .fatal(failure) }
            return .ended(error)
        }
    }

    /// Polls snapshots until it's time to try the stream again (returns true), the session stops
    /// (false), or the service turns out to speak another contract (sets `.incompatible`).
    private func poll(_ generation: Int) async -> Bool {
        var failures = 0
        var polls = 0
        while isCurrent(generation) {
            if polls > 0, configuration.allowsStreaming, polls % max(1, timing.streamRetryEveryPolls) == 0 {
                return true
            }
            if polls > 0, !(await sleep(timing.pollInterval, generation: generation)) { return false }
            guard isCurrent(generation) else { return false }
            do {
                let snapshot = try await transport.snapshot()
                guard isCurrent(generation) else { return false }
                failures = 0
                apply(snapshot, generation: generation)
            } catch {
                guard isCurrent(generation) else { return false }
                if let failure = fatalFailure(error) {
                    setState(.incompatible(reason: failure), generation: generation)
                    return false
                }
                failures += 1
                // One missed beat keeps the last values and the polling state; two make it
                // offline, with the last snapshot still on screen.
                if failures >= 2 || !hasSnapshot {
                    let reason = MonitoringClient.describe(error)
                    if state != .offline(reason: reason) {
                        setState(.offline(reason: reason), generation: generation)
                    }
                }
            }
            polls += 1
        }
        return false
    }

    private func readOnce(_ generation: Int, initial: Bool = false) async {
        do {
            let snapshot = try await transport.snapshot()
            guard isCurrent(generation) else { return }
            apply(snapshot, generation: generation)
        } catch {
            guard isCurrent(generation) else { return }
            if let failure = fatalFailure(error) {
                setState(.incompatible(reason: failure), generation: generation)
                return
            }
            // The stream may still work, so only say offline when nothing has ever arrived.
            if initial, !hasSnapshot {
                setState(.offline(reason: MonitoringClient.describe(error)), generation: generation)
            }
        }
    }

    // MARK: - State

    private func apply(_ snapshot: MonitoringSnapshot, generation: Int) {
        guard isCurrent(generation) else { return }
        hasSnapshot = true
        continuation.yield(.snapshot(snapshot, receivedAt: now()))
    }

    private func setState(_ next: MonitoringConnectionState, generation: Int) {
        guard isCurrent(generation) else { return }
        guard state != next else { return }
        state = next
        continuation.yield(.state(next))
    }

    private func emit(_ state: MonitoringConnectionState) {
        self.state = state
        continuation.yield(.state(state))
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation && runTask != nil
    }

    /// A stream that ended while snapshots work falls back to polling; one that never had a
    /// snapshot is offline. Either way the last snapshot stays.
    private func fallbackState(for error: any Error) -> MonitoringConnectionState {
        let reason = MonitoringClient.describe(error)
        return hasSnapshot ? .polling(reason: reason) : .offline(reason: reason)
    }

    private func fatalFailure(_ error: any Error) -> String? {
        guard case MonitoringClientFailure.incompatible(let contract) = error else { return nil }
        return contract.errorDescription
    }

    private func jittered(_ delay: Duration) -> Duration {
        guard timing.jitter > 0 else { return delay }
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        let spread = seconds * timing.jitter
        let jittered = seconds - spread + Double.random(in: 0...(2 * spread))
        return .seconds(max(0, jittered))
    }

    /// Sleeps unless the session stops or is replaced: a cancelled sleep returns false so the
    /// loop leaves without touching new state.
    private func sleep(_ delay: Duration, generation: Int) async -> Bool {
        do {
            try await Task.sleep(for: delay)
        } catch {
            return false
        }
        return isCurrent(generation)
    }
}
