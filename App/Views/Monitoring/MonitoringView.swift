import Charts
import HermesKit
import SwiftUI

/// Stats (`docs/monitoring.md`): the Xunxin link's overview, requests, models and exits. One
/// screen for iPhone's tab and for the iPad/Mac sheet; the monitor connection is its own, so no
/// gateway has to be open.
struct MonitoringView: View {
    let model: MonitoringModel
    /// Shown as a sheet (welcome, sidebar): it needs its own Done.
    var allowsDismiss = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.monitoringWindowIsVisible) private var windowIsVisible
    @State private var consumerID = UUID()
    @State private var isVisible = false
    @State private var section = MonitoringSection.overview
    @State private var requests: MonitoringRequestsModel
    @State private var showsSettings = false
    @State private var selectedFlight: MonitoringFlight?

    init(model: MonitoringModel, allowsDismiss: Bool = false) {
        self.model = model
        self.allowsDismiss = allowsDismiss
        _requests = State(initialValue: MonitoringRequestsModel(monitoring: model))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Picker(statsString("Section"), selection: $section) {
                    ForEach(MonitoringSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .accessibilityIdentifier("stats.sections")

                content
            }
            .background(Theme.canvas)
            .navigationTitle(statsString("Stats"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(statsString("Monitoring Settings"), systemImage: "gearshape") {
                        showsSettings = true
                    }
                    .accessibilityIdentifier("stats.settings")
                }
                if allowsDismiss {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(statsString("Done")) { dismiss() }
                    }
                }
            }
            .navigationDestination(isPresented: $showsSettings) {
                MonitoringSettingsView(model: model)
                    #if os(macOS)
                    .frame(width: 560, height: 620)
                    #endif
            }
        }
        // A replacement connection cannot leave a pushed model detail holding the old payload.
        .id(model.connectionGeneration)
        .onAppear {
            isVisible = true
            model.setConsumer(consumerID, active: scenePhase != .background && windowIsVisible)
        }
        .onChange(of: scenePhase) { _, phase in
            let active = isVisible && windowIsVisible && phase != .background
            model.setConsumer(consumerID, active: active)
            requests.setVisible(active && section == .requests)
        }
        .onChange(of: windowIsVisible) { _, visible in
            let active = isVisible && visible && scenePhase != .background
            model.setConsumer(consumerID, active: active)
            requests.setVisible(active && section == .requests)
        }
        .onDisappear {
            isVisible = false
            requests.setVisible(false)
            model.setConsumer(consumerID, active: false)
        }
        .onChange(of: model.connectionGeneration) {
            selectedFlight = nil
            showsSettings = false
        }
        .sheet(item: $selectedFlight) { flight in
            MonitoringRequestDetailView(
                flight: flight, timezone: model.snapshot?.timezone ?? "+00:00"
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 7, height: 7)
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    if let received = model.snapshotReceivedAt {
                        Text(statsString("· Updated \(received.formatted(date: .omitted, time: .standard))"))
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("stats.status")
            }
            Spacer(minLength: 0)
            if model.isSnapshotStale {
                Label(statsString("Stale"), systemImage: "clock.badge.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .live: Theme.success
        case .polling: Theme.warning
        case .offline, .incompatible: Theme.danger
        case .connecting: Theme.warning
        case .idle: Theme.tertiaryText
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if let snapshot = model.snapshot {
            VStack(spacing: 0) {
                connectionBanner
                switch section {
                case .overview:
                    MonitoringOverviewView(
                        model: model, snapshot: snapshot,
                        onAllRequests: { section = .requests },
                        onRequest: { selectedFlight = $0 }
                    )
                case .requests:
                    MonitoringRequestsView(requests: requests, onRequest: { selectedFlight = $0 })
                case .models:
                    MonitoringModelsView(snapshot: snapshot)
                }
            }
        } else if model.setupIssue != nil || !model.settings.enabled {
            MonitoringSetupView(model: model) { showsSettings = true }
        } else {
            switch model.connectionState {
            case .incompatible(let reason):
                MonitoringUnavailableView(
                    symbol: "exclamationmark.triangle",
                    title: statsString("This service doesn't speak the Stats contract"),
                    message: reason,
                    retry: { model.refresh() },
                    openSettings: { showsSettings = true }
                )
            case .offline(let reason):
                MonitoringUnavailableView(
                    symbol: "wifi.exclamationmark",
                    title: statsString("Can't reach the monitor service"),
                    message: reason,
                    retry: { model.refresh() },
                    openSettings: { showsSettings = true }
                )
            default:
                ScrollView {
                    SkeletonRows(count: 4)
                        .padding(16)
                }
                .accessibilityLabel(statsString("Loading the monitor service"))
            }
        }
    }

    @ViewBuilder private var connectionBanner: some View {
        switch model.connectionState {
        case .offline(let reason):
            banner(
                symbol: "wifi.exclamationmark", tint: Theme.warning,
                text: statsString("Showing the last snapshot. \(reason)"), retry: true
            )
        case .incompatible(let reason):
            banner(
                symbol: "exclamationmark.triangle", tint: Theme.danger,
                text: reason, retry: true
            )
        case .polling:
            banner(
                symbol: "arrow.clockwise", tint: Theme.secondaryText,
                text: statsString("Live updates are unavailable; the app reads a snapshot every 10 seconds."), retry: false
            )
        default:
            EmptyView()
        }
    }

    private func banner(symbol: String, tint: Color, text: String, retry: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if retry {
                Button(statsString("Check Again")) { model.refresh() }
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.warningTint)
        .accessibilityElement(children: .combine)
    }
}

enum MonitoringSection: String, CaseIterable, Identifiable {
    case overview, requests, models

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: statsString("Overview")
        case .requests: statsString("Requests")
        case .models: statsString("Models")
        }
    }
}

// MARK: - Overview

private struct MonitoringOverviewView: View {
    let model: MonitoringModel
    let snapshot: MonitoringSnapshot
    let onAllRequests: () -> Void
    let onRequest: (MonitoringFlight) -> Void

    private var presentation: MonitoringPresentation {
        model.presentation ?? MonitoringPresentation(snapshot: snapshot, receivedAt: nil, now: .now, state: .idle)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                health
                exits
                today
                inflight
                recent
            }
            .padding(16)
        }
        .refreshable { model.refresh() }
    }

    // MARK: Health

    private var health: some View {
        MonitoringCard(title: statsString("Link health"), symbol: "point.3.connected.trianglepath.dotted") {
            VStack(spacing: 10) {
                healthRow(
                    statsString("Monitor service"),
                    state: model.connectionState.isLive || model.connectionState.isPolling ? .live : .down,
                    detail: model.statusText
                )
                healthRow(
                    statsString("Relay"),
                    state: presentation.relayState,
                    detail: relayDetail
                )
                healthRow(
                    statsString("Live trace"),
                    state: presentation.traceState,
                    detail: traceDetail
                )
                healthRow(
                    statsString("Usage file"),
                    state: presentation.usageState,
                    detail: usageDetail
                )
            }
            .padding(.top, 2)
            Text(path)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .accessibilityLabel(statsString("Path: \(path)"))
        }
    }

    private var path: String {
        let exit = snapshot.failover.lastUsed ?? snapshot.exits.first(where: { $0.role == "primary" })?.name ?? "—"
        return statsString("Agent → magpie → Relay → \(exit) → Xunxin")
    }

    private var relayDetail: String {
        guard presentation.relayState == .live else { return presentation.relayState.title }
        guard let reachable = snapshot.failover.reachable else { return statsString("Unknown") }
        guard reachable else { return statsString("Unreachable") }
        let count: String
        if let tunnels = snapshot.failover.tunnels {
            count = tunnels == 1
                ? statsString("1 active tunnel")
                : statsString("\(tunnels) active tunnels")
        } else {
            count = statsString("Active tunnels unknown")
        }
        guard let lastUsed = snapshot.failover.lastUsed else { return count }
        return count + statsString(" · last used \(lastUsed)")
    }

    private var traceDetail: String {
        switch presentation.traceState {
        case .live: statsString("Receiving state")
        case .stale: statsString("Last update is old")
        case .down: snapshot.trace.error ?? statsString("Unavailable")
        case .unknown: statsString("The service doesn't report its freshness")
        }
    }

    private var usageDetail: String {
        switch presentation.usageState {
        case .live: statsString("Today's totals are current")
        case .stale: statsString("Today's totals may be behind")
        case .down: statsString("Unavailable")
        case .unknown: statsString("The service doesn't report its freshness")
        }
    }

    private func healthRow(_ title: String, state: MonitoringSourceState, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MonitoringStateDot(state: state)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(statsString("\(title): \(state.title). \(detail)")))
    }

    // MARK: Exits

    private var exits: some View {
        MonitoringCard(title: statsString("Exits"), symbol: "arrow.triangle.branch") {
            if snapshot.exits.isEmpty {
                Text(statsString("The service didn't report any exits."))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                VStack(spacing: 0) {
                    ForEach(snapshot.exits) { exit in
                        NavigationLink {
                            MonitoringExitsView(model: model)
                        } label: {
                            exitRow(exit)
                        }
                        .buttonStyle(.plain)
                        if exit.id != snapshot.exits.last?.id { Divider() }
                    }
                }
            }
            NavigationLink { MonitoringExitsView(model: model) } label: { Text(statsString("Exit details")) }
                .font(.subheadline.weight(.semibold))
                .padding(.top, 6)
        }
    }

    private func exitRow(_ exit: MonitoringExit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(presentation.exitState(exit).statsColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(exit.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                Text(subtitle(for: exit))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            Text(exit.milliseconds.map(MonitoringFormat.milliseconds) ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func subtitle(for exit: MonitoringExit) -> String {
        var parts: [String] = []
        if !exit.role.isEmpty { parts.append(exit.displayRole) }
        parts.append(presentation.reachability(exit))
        if exit.servedToday > 0 {
            parts.append(statsString("\(exit.servedToday) today"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Today

    private var today: some View {
        MonitoringCard(title: statsString("Today"), symbol: "calendar") {
            HStack {
                Text(snapshot.day.isEmpty ? "—" : snapshot.day)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(snapshot.timezone)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 12) {
                metric(
                    statsString("Requests"), value: MonitoringFormat.count(snapshot.today.requests),
                    detail: statsString("\(snapshot.today.error) errors · \(snapshot.today.canceled) canceled"),
                    symbol: "arrow.left.arrow.right"
                )
                metric(
                    statsString("Estimated cost"), value: MonitoringFormat.dollars(snapshot.today.cost),
                    detail: costDetail, symbol: "dollarsign.circle"
                )
                metric(
                    statsString("First token p50"), value: MonitoringFormat.milliseconds(snapshot.today.ttftP50),
                    detail: statsString("Successful requests"), symbol: "timer"
                )
                metric(
                    statsString("Body speed p50"), value: MonitoringFormat.speed(snapshot.today.tpsP50),
                    detail: statsString("\(snapshot.today.tpsSamples) measured"), symbol: "speedometer"
                )
            }
            .padding(.top, 4)
            Text(cacheDetail)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 2)
        }
    }

    private var costDetail: String {
        snapshot.today.unknownCosts == 0
            ? statsString("All \(snapshot.today.pricedRequests) priced")
            : statsString("\(snapshot.today.unknownCosts) without a price")
    }

    private var cacheDetail: String {
        let hit = snapshot.today.cacheHitRate.map(MonitoringFormat.percent) ?? "—"
        return statsString("Cache hit \(hit) of input read · failures never enter the latencies")
    }

    private func metric(_ title: String, value: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(statsString("\(title): \(value). \(detail)")))
    }

    // MARK: In flight

    private var inflight: some View {
        MonitoringCard(title: statsString("In flight"), symbol: "bolt.horizontal") {
            switch presentation.traceState {
            case .down:
                Text(statsString("Trace is unavailable, so requests in flight can't be read."))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            case .stale:
                Text(statsString("Trace is stale; this list may be behind."))
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                if !snapshot.inflight.isEmpty { flightRows }
            case .unknown:
                Text(statsString("The service didn't report whether trace is current."))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            case .live:
                flightRows
            }
        }
    }

    @ViewBuilder private var flightRows: some View {
        if snapshot.inflight.isEmpty {
            Text(presentation.canClaimNoInflight
                ? statsString("No requests in flight.")
                : statsString("The current number of requests in flight is unknown."))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        } else {
            let flights = snapshot.inflight.sorted {
                ($0.start ?? .greatestFiniteMagnitude, $0.id) < ($1.start ?? .greatestFiniteMagnitude, $1.id)
            }
            VStack(spacing: 0) {
                ForEach(flights) { flight in
                    inflightRow(flight)
                    if flight.id != flights.last?.id { Divider() }
                }
            }
        }
    }

    private func inflightRow(_ flight: MonitoringFlight) -> some View {
        Button { onRequest(flight) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(flight.displayModel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(flight.answering
                        ? statsString("Answering")
                        : statsString("Waiting for first token"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(flight.answering ? Theme.success : Theme.warning)
                }
                HStack(spacing: 8) {
                    Text(flight.agent ?? "—")
                    if let elapsed = flight.elapsedSeconds(now: snapshot.now) {
                        Text(MonitoringFormat.seconds(elapsed))
                    }
                    if let speed = flight.tpsNow ?? flight.tps, speed > 0 {
                        Text(statsString("≈\(speed.formatted(.number.precision(.fractionLength(1)))) tok/s"))
                    }
                    if let exit = flight.exit { Text(exit) }
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: Recent

    private var recent: some View {
        MonitoringCard(title: statsString("Recently completed"), symbol: "checkmark.circle") {
            if snapshot.recent.isEmpty {
                Text(statsString("No completed requests yet today."))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(presentation.recent)) { flight in
                        Button { onRequest(flight) } label: {
                            MonitoringFlightRow(flight: flight, timezone: snapshot.timezone, now: snapshot.now)
                        }
                        .buttonStyle(.plain)
                        if flight.id != presentation.recent.last?.id { Divider() }
                    }
                }
            }
            Button(statsString("All requests"), action: onAllRequests)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 6)
        }
    }
}

// MARK: - Setup and failures

private struct MonitoringSetupView: View {
    let model: MonitoringModel
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 38))
                .foregroundStyle(Theme.secondaryText)
            Text(model.settings.enabled
                ? statsString("The Xunxin link needs attention")
                : statsString("Set up the Xunxin link"))
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            Text(model.setupIssue ?? statsString("Add the monitor service's address in Settings."))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(statsString("Open Monitoring Settings"), action: openSettings)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("stats.setup")
    }
}

private struct MonitoringUnavailableView: View {
    let symbol: String
    let title: String
    let message: String
    let retry: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 38))
                .foregroundStyle(Theme.warning)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(statsString("Check Again"), action: retry)
                    .buttonStyle(.borderedProminent)
                Button(statsString("Settings"), action: openSettings)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Shared pieces

struct MonitoringCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
    }
}

struct MonitoringStateDot: View {
    let state: MonitoringSourceState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .live: Theme.success
        case .stale: Theme.warning
        case .down: Theme.danger
        case .unknown: Theme.tertiaryText
        }
    }
}

extension MonitoringExit {
    /// A known role reads in the app's language; any other value stays as the service sent it.
    var displayRole: String {
        switch role.lowercased() {
        case "primary": statsString("Primary")
        case "secondary": statsString("Secondary")
        case "backup": statsString("Backup")
        default: role.capitalized
        }
    }
}

extension MonitoringSourceState {
    var statsColor: Color {
        switch self {
        case .live: Theme.success
        case .down: Theme.danger
        case .stale: Theme.warning
        case .unknown: Theme.tertiaryText
        }
    }

    var title: String {
        switch self {
        case .live: statsString("Live")
        case .stale: statsString("Stale")
        case .down: statsString("Down")
        case .unknown: statsString("Unknown")
        }
    }
}

/// Stats' copy lives in its own `Stats` table: a word it shares with the rest of the app
/// ("Done", "Settings") is translated here without translating it anywhere else.
nonisolated func statsString(_ value: String.LocalizationValue) -> String {
    String(localized: value, table: "Stats")
}

enum MonitoringFormat {
    static func bucketHour(_ label: String) -> String { String(label.prefix(2)) }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func dollars(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "$" + value.formatted(.number.precision(.fractionLength(2)))
    }

    static func preciseDollars(_ value: Double?) -> String {
        guard let value else { return "—" }
        let digits = value != 0 && abs(value) < 0.01 ? 4 : 2
        return "$" + value.formatted(.number.precision(.fractionLength(digits)))
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value < 1 { return "<1 ms" }
        if value < 1000 { return "\(Int(value.rounded())) ms" }
        return seconds(value / 1000)
    }

    static func seconds(_ value: Double) -> String {
        guard value.isFinite, value >= 0, let rounded = Int(exactly: value.rounded()) else { return "—" }
        if value < 10 { return String(format: "%.1f s", value) }
        return "\(rounded) s"
    }

    static func chartValue(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, Int(exactly: value.rounded()) != nil else { return nil }
        return value
    }

    static func probeAxis(_ value: Double) -> String {
        guard value.isFinite, value >= 0, let rounded = Int(exactly: value.rounded()) else { return "—" }
        return statsString("\(rounded) ms")
    }

    static func speed(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) tok/s"
    }

    static func percent(_ value: Double) -> String {
        (value * 100).formatted(.number.precision(.fractionLength(1))) + "%"
    }

    static func int(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    static func tokens(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000 { return (value / 1_000_000).formatted(.number.precision(.fractionLength(2))) + "M" }
        if value >= 1_000 { return (value / 1_000).formatted(.number.precision(.fractionLength(1))) + "K" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    static func clock(_ epoch: Double?, timezone: String) -> String {
        guard let epoch else { return "—" }
        return MonitoringTime.clock(epoch, timezone: timezone)
    }

    static func dayClock(_ epoch: Double?, timezone: String) -> String {
        guard let epoch else { return "—" }
        return MonitoringTime.dayClock(epoch, timezone: timezone)
    }
}
