import Charts
import HermesKit
import SwiftUI

/// Stats → Exits and events (`docs/monitoring.md` §4): each exit's probe history and the events
/// the service includes in its window. Probe latency is not a model's first-token latency, and
/// the events are not claimed as a full day's history.
struct MonitoringExitsView: View {
    let model: MonitoringModel

    var body: some View {
        List {
            if let snapshot = model.snapshot {
                if snapshot.exits.isEmpty {
                    ContentUnavailableView(
                        statsString("No exits reported"), systemImage: "arrow.triangle.branch",
                        description: Text(statsString("The service didn't include exit probes in this snapshot."))
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(snapshot.exits) { exit in
                        Section {
                            MonitoringExitCard(exit: exit, timezone: snapshot.timezone, presentation: model.presentation)
                        }
                    }
                }

                Section {
                    if snapshot.events.isEmpty {
                        Text(statsString("The service reports no events in its window."))
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        ForEach(snapshot.events) { event in
                            eventRow(event, timezone: snapshot.timezone)
                        }
                    }
                } header: {
                    Text(statsString("Events"))
                } footer: {
                    Text(statsString("The window is the one the service sends. It isn't presented as a complete day."))
                }
            } else {
                SkeletonRows(count: 4)
                    .listRowBackground(Color.clear)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle(statsString("Exits and events"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("stats.exits")
    }

    private func eventRow(_ event: MonitoringEvent, timezone: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(for: event.kind))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.displayKind)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                    Spacer(minLength: 8)
                    Text(MonitoringFormat.clock(event.at ?? MonitoringTime.epoch(fromISO: event.timeText), timezone: timezone))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                }
                if !event.message.isEmpty {
                    Text(event.message)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let exit = event.exit {
                    Text(exit)
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "failover": "arrow.triangle.swap"
        case "recover", "recovered": "checkmark.circle"
        case "down", "unreachable": "exclamationmark.triangle"
        case "switch", "exit": "arrow.triangle.branch"
        default: "dot.radiowaves.left.and.right"
        }
    }
}

extension MonitoringEvent {
    /// A known kind reads in the app's language; any other value stays as the service sent it.
    var displayKind: String {
        switch kind.lowercased() {
        case "failover": statsString("Failover")
        case "recover": statsString("Recover")
        case "recovered": statsString("Recovered")
        case "switch": statsString("Switch")
        case "probe": statsString("Probe")
        case "down": statsString("Down")
        case "unreachable": statsString("Unreachable")
        case "exit": statsString("Exit")
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private struct MonitoringExitCard: View {
    let exit: MonitoringExit
    let timezone: String
    let presentation: MonitoringPresentation?
    @State private var selectedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill((presentation?.exitState(exit) ?? .unknown).statsColor)
                    .frame(width: 8, height: 8)
                Text(exit.name)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                Text(reachability)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle((presentation?.exitState(exit) ?? .unknown).statsColor)
            }
            Text(details)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if samples.isEmpty {
                Text(statsString("No probe samples in the service's window."))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                chart
                if let selectedSample {
                    Text(selectionText(selectedSample))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                }
                Text(rangeText)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var samples: [MonitoringProbeSample] {
        exit.history.sorted { $0.at < $1.at }
    }

    private var chart: some View {
        Chart {
            ForEach(samples) { sample in
                if let milliseconds = MonitoringFormat.chartValue(sample.milliseconds) {
                    LineMark(
                        x: .value(statsString("Probe time"), Date(timeIntervalSince1970: sample.at)),
                        y: .value(statsString("Latency"), milliseconds)
                    )
                    .foregroundStyle(Theme.link)
                    .interpolationMethod(.monotone)
                    PointMark(
                        x: .value(statsString("Probe time"), Date(timeIntervalSince1970: sample.at)),
                        y: .value(statsString("Latency"), milliseconds)
                    )
                    .foregroundStyle(Theme.link)
                    .symbolSize(14)
                }
            }
            if let selectedSample {
                RuleMark(x: .value(statsString("Probe time"), Date(timeIntervalSince1970: selectedSample.at)))
                    .foregroundStyle(Theme.secondaryText.opacity(0.35))
            }
        }
        .chartXSelection(value: Binding(
            get: { selectedAt },
            set: { selectedAt = $0 }
        ))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(MonitoringFormat.clock(date.timeIntervalSince1970, timezone: timezone))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(MonitoringFormat.probeAxis(number))
                            .font(.caption2)
                    }
                }
            }
        }
        .frame(height: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(statsString("\(exit.name) probe latency")))
        .accessibilityValue(accessibilitySummary)
    }

    private var selectedSample: MonitoringProbeSample? {
        guard let selectedAt else { return nil }
        return samples.min {
            abs($0.at - selectedAt.timeIntervalSince1970) < abs($1.at - selectedAt.timeIntervalSince1970)
        }
    }

    private func selectionText(_ sample: MonitoringProbeSample) -> String {
        let time = MonitoringFormat.clock(sample.at, timezone: timezone)
        guard let milliseconds = sample.milliseconds else {
            return statsString("\(time) · probe failed")
        }
        return "\(time) · \(MonitoringFormat.milliseconds(milliseconds))"
    }

    private var reachability: String {
        presentation?.reachability(exit) ?? statsString("Unknown")
    }

    private var details: String {
        var parts: [String] = []
        if !exit.role.isEmpty { parts.append(exit.displayRole) }
        if let latest = exit.statsLatestProbe { parts.append(latest) }
        if let failures = exit.consecutiveFailures, failures > 0 {
            parts.append(failures == 1
                ? statsString("1 consecutive failure")
                : statsString("\(failures) consecutive failures"))
        }
        parts.append(exit.tunnels == 1
            ? statsString("1 active tunnel")
            : statsString("\(exit.tunnels) active tunnels"))
        parts.append(statsString("\(exit.servedToday) served today (inferred)"))
        if let host = exit.host { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    private var rangeText: String {
        guard let first = samples.first, let last = samples.last else { return "" }
        let failures = samples.filter { $0.milliseconds == nil }.count
        let failed = failures == 0
            ? ""
            : (failures == 1
                ? statsString(" · 1 failed probe")
                : statsString(" · \(failures) failed probes"))
        let range = "\(MonitoringFormat.clock(first.at, timezone: timezone))–\(MonitoringFormat.clock(last.at, timezone: timezone))"
        let count = samples.count == 1
            ? statsString("1 probe")
            : statsString("\(samples.count) probes")
        return "\(range) · \(count)\(failed)"
    }

    private var accessibilitySummary: String {
        let measured = samples.compactMap(\.milliseconds).sorted()
        guard let minimum = measured.first, let maximum = measured.last else {
            return samples.count == 1
                ? statsString("1 probe, none measured a latency")
                : statsString("\(samples.count) probes, none measured a latency")
        }
        let median = measured[measured.count / 2]
        let count = samples.count == 1
            ? statsString("1 probe.")
            : statsString("\(samples.count) probes.")
        return count + statsString(" Lowest \(MonitoringFormat.milliseconds(minimum)), median \(MonitoringFormat.milliseconds(median)), highest \(MonitoringFormat.milliseconds(maximum)). \(rangeText)")
    }
}
