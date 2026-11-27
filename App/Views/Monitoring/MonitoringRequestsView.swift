import HermesKit
import SwiftUI

/// Stats → Requests (`docs/monitoring.md` §2): the day's scoped requests, with the filters,
/// the frozen point, the newer prompt and the paging the plan asks for.
struct MonitoringRequestsView: View {
    @Bindable var requests: MonitoringRequestsModel
    let onRequest: (MonitoringFlight) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        List {
            Section {
                searchRow
                filterRow
                amountRow
                if let problem = requests.amountProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
                if let notice = requests.notice {
                    noticeRow(notice)
                }
                if requests.freeze != nil {
                    frozenRow
                }
            }

            if let error = requests.error {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(statsString("Couldn't load requests"), systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.warning)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                        Button(statsString("Try Again")) { Task { await requests.load() } }
                            .font(.caption.weight(.semibold))
                    }
                }
            }

            if let page = requests.pageData {
                Section {
                    if page.items.isEmpty {
                        ContentUnavailableView(
                            statsString("No requests match"), systemImage: "line.3.horizontal.decrease.circle",
                            description: Text(statsString("Change the search, the status or the amount range."))
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(page.items) { flight in
                            Button { onRequest(flight) } label: {
                                MonitoringFlightRow(flight: flight, timezone: page.timezone, now: requests.monitoring.snapshot?.now)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("stats.request.\(flight.id)")
                        }
                    }
                } header: {
                    HStack {
                        Text(summary(page))
                        Spacer()
                        if requests.isLoading { Spinner(size: .mini) }
                    }
                } footer: {
                    pager(page)
                }
            } else if requests.isLoading {
                Section {
                    SkeletonRows(count: 5)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .onAppear { requests.setVisible(true) }
        .onDisappear { requests.setVisible(false) }
        .onChange(of: requests.isLoading) { _, loading in
            // Loading a page is the list's own waiting; the field stays where it was.
            if !loading { searchFocused = false }
        }
        .accessibilityIdentifier("stats.requests")
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.secondaryText)
            TextField(statsString("Model, agent, account, exit or error"), text: $requests.searchText)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { requests.submitSearch() }
            if !requests.searchText.isEmpty {
                Button(statsString("Clear Search"), systemImage: "xmark.circle.fill") {
                    requests.searchText = ""
                    requests.submitSearch()
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    private var filterRow: some View {
        HStack(spacing: 10) {
            Menu {
                Picker(statsString("Status"), selection: statusBinding) {
                    Text(statsString("Any status")).tag(MonitoringStatusFilter.all)
                    Text(statsString("Successful")).tag(MonitoringStatusFilter.success)
                    Text(statsString("Failed")).tag(MonitoringStatusFilter.failed)
                    Text(statsString("Canceled")).tag(MonitoringStatusFilter.cancelled)
                }
                Divider()
                Picker(statsString("Cost"), selection: costBinding) {
                    Text(statsString("Any cost")).tag(MonitoringCostFilter.any)
                    Text(statsString("Priced")).tag(MonitoringCostFilter.priced)
                    Text(statsString("Not priced")).tag(MonitoringCostFilter.none)
                    Text(statsString("Only unpriced")).tag(MonitoringCostFilter.unpriced)
                }
            } label: {
                Label(statusTitle, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline)
            }
            Menu {
                Picker(statsString("Sort"), selection: sortBinding) {
                    Text(statsString("Newest first")).tag(MonitoringRequestSort.newest)
                    Text(statsString("Oldest first")).tag(MonitoringRequestSort.oldest)
                    Text(statsString("Cost, highest first")).tag(MonitoringRequestSort.costDescending)
                    Text(statsString("Cost, lowest first")).tag(MonitoringRequestSort.costAscending)
                    Text(statsString("Slowest first")).tag(MonitoringRequestSort.duration)
                }
            } label: {
                Label(sortTitle, systemImage: "arrow.up.arrow.down")
                    .font(.subheadline)
            }
            Spacer(minLength: 0)
            if requests.freeze != nil || requests.query.hasFilters {
                Button(statsString("Clear")) { requests.clearFilters() }
                    .font(.subheadline)
            }
        }
    }

    private var amountRow: some View {
        HStack(spacing: 8) {
            TextField(statsString("Lowest $"), text: $requests.minimumText)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 110)
            Text(statsString("to"))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            TextField(statsString("Highest $"), text: $requests.maximumText)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 110)
            Spacer(minLength: 0)
            Button(statsString("Apply")) { requests.apply() }
                .font(.subheadline.weight(.semibold))
                .disabled(requests.amountProblem != nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(statsString("Amount range in dollars"))
    }

    private var frozenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(statsString("This list is frozen"), systemImage: "snowflake")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            Text(statsString("New requests don't move these rows. Clear the filters to follow live again."))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if requests.newerCount > 0 {
                Button {
                    requests.showNewer()
                } label: {
                    Label(newerTitle, systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func noticeRow(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(Theme.warning)
            Text(notice)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var newerTitle: String {
        requests.newerCount == 1
            ? statsString("1 new request")
            : statsString("\(requests.newerCount) new requests")
    }

    private func summary(_ page: MonitoringRecentPage) -> String {
        var parts = [page.total == 1
            ? statsString("1 request")
            : statsString("\(page.total) requests")]
        if let cost = page.costSum {
            parts.append(MonitoringFormat.dollars(cost))
        }
        if page.unpricedCount > 0 {
            parts.append(statsString("\(page.unpricedCount) without a price"))
        }
        if requests.canClaimLive { parts.append(statsString("live")) }
        return parts.joined(separator: " · ")
    }

    private func pager(_ page: MonitoringRecentPage) -> some View {
        HStack {
            Button(statsString("Previous"), systemImage: "chevron.left") { requests.previousPage() }
                .disabled(!requests.canGoBack)
            Spacer()
            Text(statsString("Page \(page.page) of \(max(1, page.pages))"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Button(statsString("Next"), systemImage: "chevron.right") { requests.nextPage() }
                .disabled(!requests.canGoForward)
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
    }

    // MARK: - Bindings

    private var statusBinding: Binding<MonitoringStatusFilter> {
        Binding(get: { requests.status }, set: { requests.setStatus($0) })
    }

    private var costBinding: Binding<MonitoringCostFilter> {
        Binding(get: { requests.cost }, set: { requests.setCost($0) })
    }

    private var sortBinding: Binding<MonitoringRequestSort> {
        Binding(get: { requests.sort }, set: { requests.setSort($0) })
    }

    private var statusTitle: String {
        switch requests.status {
        case .all: statsString("Any status")
        case .success: statsString("Successful")
        case .failed: statsString("Failed")
        case .cancelled: statsString("Canceled")
        }
    }

    private var sortTitle: String {
        switch requests.sort {
        case .newest: statsString("Newest")
        case .oldest: statsString("Oldest")
        case .costDescending: statsString("Cost ↓")
        case .costAscending: statsString("Cost ↑")
        case .duration: statsString("Slowest")
        }
    }
}

// MARK: - Rows

/// One request, as the overview's recent list and the requests list draw it: who and how it
/// ended, the model, then the timings and the price, then where it went.
struct MonitoringFlightRow: View {
    let flight: MonitoringFlight
    let timezone: String
    var now: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(agentName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                Text(outcomeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(outcomeColor)
                Text(clock)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
            }
            Text(flight.displayModel)
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if flight.done {
                    Text(statsString("TTFT \(MonitoringFormat.milliseconds(flight.ttft))"))
                    Text(statsString("total \(MonitoringFormat.milliseconds(flight.milliseconds))"))
                } else if let elapsed = flight.elapsedSeconds(now: now) {
                    Text(statsString("running \(MonitoringFormat.seconds(elapsed))"))
                }
                if let speed = flight.tpsNow ?? flight.tps {
                    Text(statsString("\(flight.tpsFloor ? "≥" : "")\(speed.formatted(.number.precision(.fractionLength(1)))) tok/s"))
                }
                if flight.done {
                    Text(MonitoringFormat.dollars(flight.cost))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
            Text(metaText)
                .font(.caption2)
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var agentName: String {
        switch flight.agent {
        case "hermes": "Hermes"
        case "claude": "Claude Code"
        case let agent?: agent
        case nil: statsString("Unknown agent")
        }
    }

    private var clock: String {
        let epoch = flight.end ?? MonitoringTime.epoch(fromISO: flight.time ?? "") ?? flight.start
        return MonitoringFormat.clock(epoch, timezone: timezone)
    }

    private var metaText: String {
        var parts: [String] = []
        if let account = flight.providerName ?? flight.provider { parts.append(account) }
        parts.append(flight.statsExit)
        if let effort = flight.effort { parts.append(effort) }
        return parts.joined(separator: " · ")
    }

    private var outcomeText: String {
        switch flight.outcome {
        case .success: statsString("Success")
        case .failed: flight.status.map { statsString("Error \($0)") } ?? statsString("Error")
        case .cancelled: statsString("Canceled")
        case .inFlight: flight.answering
            ? statsString("Answering")
            : statsString("Waiting for first token")
        case .unknown: statsString("Unknown")
        }
    }

    private var outcomeColor: Color {
        switch flight.outcome {
        case .success: Theme.success
        case .failed: Theme.danger
        case .cancelled: Theme.tertiaryText
        case .inFlight: Theme.link
        case .unknown: Theme.secondaryText
        }
    }

    private var accessibilityText: String {
        var parts = [agentName, outcomeText, flight.displayModel, clock]
        if flight.done {
            parts.append(statsString("first token \(MonitoringFormat.milliseconds(flight.ttft))"))
            parts.append(statsString("total \(MonitoringFormat.milliseconds(flight.milliseconds))"))
        }
        parts.append(metaText)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Detail

/// A request's full detail (`docs/monitoring.md` §2). The sheet holds the request it opened
/// with, so a snapshot or a page refresh never closes or rewrites it.
struct MonitoringRequestDetailView: View {
    let flight: MonitoringFlight
    let timezone: String

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(flight.displayModel)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(outcomeLine)
                            .font(.caption)
                            .foregroundStyle(outcomeColor)
                    }
                    .padding(.vertical, 4)
                    LabeledContent(statsString("Request ID")) {
                        Text(flight.id)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Button {
                        Pasteboard.copy(flight.id)
                        copied = true
                    } label: {
                        Label(
                            copied ? statsString("Copied") : statsString("Copy request ID"),
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .accessibilityIdentifier("stats.copyRequestID")
                }

                Section(header: Text(statsString("Models"))) {
                    fact(statsString("Requested"), flight.requestedModel)
                    fact(statsString("Served"), flight.servedModel)
                    fact(statsString("Reported model"), flight.model)
                    fact(statsString("Account"), flight.providerName ?? flight.provider)
                    fact(statsString("Effort"), flight.effort)
                    fact(statsString("Exit"), flight.exit.map {
                        statsString("\($0) (inferred from the tunnel log)")
                    } ?? statsString("Exit unknown"))
                }

                Section(header: Text(statsString("Timing"))) {
                    fact(statsString("Started"), startText)
                    fact(statsString("Ended"), endText)
                    fact(statsString("Total"), MonitoringFormat.milliseconds(flight.milliseconds))
                    fact(statsString("First token"), MonitoringFormat.milliseconds(flight.ttft))
                    fact(statsString("Body speed"), speedText)
                }

                Section(header: Text(statsString("Tokens"))) {
                    fact(statsString("Uncached input"), MonitoringFormat.tokens(flight.inputTokens))
                    fact(statsString("Cache read"), MonitoringFormat.tokens(flight.cacheRead))
                    fact(statsString("Cache write"), MonitoringFormat.tokens(flight.cacheWrite))
                    fact(statsString("Output"), MonitoringFormat.tokens(flight.outputTokens))
                    fact(statsString("Reasoning"), MonitoringFormat.tokens(flight.reasoning))
                    fact(statsString("Cache hit"), flight.computedCacheHitRate.map(MonitoringFormat.percent) ?? "—")
                }

                Section(header: Text(statsString("Cost"))) {
                    fact(statsString("Estimated"), MonitoringFormat.preciseDollars(flight.cost))
                    fact(statsString("Pricing"), flight.costMode)
                    if let parts = flight.costParts {
                        fact(statsString("Input part"), MonitoringFormat.preciseDollars(parts.input))
                        fact(statsString("Output part"), MonitoringFormat.preciseDollars(parts.output))
                        fact(statsString("Cache read part"), MonitoringFormat.preciseDollars(parts.cacheRead))
                        fact(statsString("Cache write part"), MonitoringFormat.preciseDollars(parts.cacheWrite))
                    }
                }

                Section(header: Text(statsString("Outcome"))) {
                    fact(statsString("Status"), flight.status.map(String.init))
                    fact(statsString("Stop reason"), flight.stop)
                    if let error = flight.error, !error.isEmpty {
                        fact(statsString("Error"), error)
                    }
                }

                Section {
                    Text(statsString("From the snapshot the sheet opened with. It stays open while the list refreshes."))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .navigationTitle(statsString("Request detail"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(statsString("Done")) { dismiss() }
                }
            }
            #if os(macOS)
            .frame(width: 560, height: 640)
            #endif
        }
    }

    private func fact(_ title: String, _ value: String?) -> some View {
        LabeledContent(title) {
            Text(value ?? "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(value == nil ? Theme.tertiaryText : Theme.secondaryText)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private var outcomeLine: String {
        let who = flight.agent ?? statsString("unknown agent")
        switch flight.outcome {
        case .success:
            return statsString("Success · \(flight.status.map(String.init) ?? "200") · \(who)")
        case .failed:
            return statsString("Failed · \(flight.status.map(String.init) ?? "error") · \(who)")
        case .cancelled:
            return statsString("Canceled by the caller · 499 · \(who)")
        case .inFlight:
            return statsString("In flight when the snapshot was taken · \(who)")
        case .unknown:
            return statsString("Outcome unknown · \(who)")
        }
    }

    private var outcomeColor: Color {
        switch flight.outcome {
        case .success: Theme.success
        case .failed: Theme.danger
        case .cancelled: Theme.secondaryText
        case .inFlight: Theme.link
        case .unknown: Theme.secondaryText
        }
    }

    private var startText: String {
        let epoch = flight.statsStart
        return MonitoringFormat.dayClock(epoch, timezone: timezone)
    }

    private var endText: String {
        MonitoringFormat.dayClock(flight.end, timezone: timezone)
    }

    private var speedText: String {
        guard let tps = flight.tps else { return "—" }
        let floor = flight.tpsFloor ? "≥" : ""
        return "\(floor)\(tps.formatted(.number.precision(.fractionLength(1)))) tok/s"
    }
}

