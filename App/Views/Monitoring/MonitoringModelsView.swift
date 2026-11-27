import Charts
import HermesKit
import SwiftUI

/// Stats → Models (`docs/monitoring.md` §3): today's scoped models and their eight three-hour
/// buckets. The chart is Swift Charts; every bucket also has a text value, which is what
/// VoiceOver reads.
struct MonitoringModelsView: View {
    let snapshot: MonitoringSnapshot

    var body: some View {
        List {
            if snapshot.models.items.isEmpty {
                ContentUnavailableView(
                    statsString("No models today"), systemImage: "cpu",
                    description: Text(statsString("The service hasn't recorded a Xunxin request today."))
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(sortedModels) { model in
                        NavigationLink {
                            MonitoringModelDetailView(model: model, buckets: buckets(for: model))
                        } label: {
                            modelRow(model)
                        }
                        .accessibilityIdentifier("stats.model.\(model.key)")
                    }
                } header: {
                    Text(statsString("Today · Xunxin only"))
                } footer: {
                    Text(statsString("First-token and body-speed percentiles use successful, measurable samples. Missing data shows as —."))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .accessibilityIdentifier("stats.models")
    }

    private var sortedModels: [MonitoringModelItem] {
        snapshot.models.items.sorted { ($0.requests, $1.name) > ($1.requests, $0.name) }
    }

    /// Every bucket the service names, in hour order. A model that didn't report one still gets
    /// its empty slot, shown as —.
    private func buckets(for model: MonitoringModelItem) -> [MonitoringModelBucket] {
        let hours = snapshot.models.bucketHours.isEmpty
            ? Array(stride(from: 0, to: 24, by: 3))
            : snapshot.models.bucketHours.sorted()
        let byHour = Dictionary(uniqueKeysWithValues: model.buckets.map { ($0.hour, $0) })
        return hours.map { hour in
            byHour[hour] ?? MonitoringModelBucket(JSONValue.object([
                "hour": .number(Double(hour))
            ]))
        }
    }

    private func modelRow(_ model: MonitoringModelItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(MonitoringFormat.dollars(model.cost))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            Text(statsString("\(model.requests) requests · \(model.ok) ok · \(model.error) errors · \(model.canceled) canceled"))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            Text(statsString("Cache \(model.cacheHitRate.map(MonitoringFormat.percent) ?? "—") · TTFT \(MonitoringFormat.milliseconds(model.ttftP50)) / \(MonitoringFormat.milliseconds(model.ttftP90)) · \(model.tpsP50.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—") tok/s"))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One model's day: its summary, then the eight buckets as a selectable chart and as readable
/// values. The chart's selection and the grid name the same bucket.
private struct MonitoringModelDetailView: View {
    let model: MonitoringModelItem
    let buckets: [MonitoringModelBucket]

    @State private var metric = ModelMetric.firstToken
    @State private var selectedHour: Int?

    var body: some View {
        List {
            Section {
                summary
            }

            Section {
                Picker(statsString("Metric"), selection: $metric) {
                    ForEach(ModelMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                chartView
                    .padding(.vertical, 6)

                if selectedBucket != nil {
                    selectedDetail
                }

                bucketGrid
            } header: {
                Text(statsString("Today by three-hour bucket"))
            } footer: {
                Text(statsString("Select a point to read its bucket. Empty buckets show —; they aren't zero latency."))
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle(model.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("stats.modelDetail")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), alignment: .leading)], spacing: 8) {
                summaryValue(statsString("Requests"), MonitoringFormat.count(model.requests))
                summaryValue(statsString("Success"), MonitoringFormat.count(model.ok))
                summaryValue(statsString("Errors"), MonitoringFormat.count(model.error))
                summaryValue(statsString("Canceled"), MonitoringFormat.count(model.canceled))
                summaryValue(statsString("Cache hit"), model.cacheHitRate.map(MonitoringFormat.percent) ?? "—")
                summaryValue(statsString("Estimated"), MonitoringFormat.preciseDollars(model.cost))
                summaryValue(statsString("Average"), MonitoringFormat.preciseDollars(model.averageCost))
            }
            Text(statsString("First token p50 / p90 \(MonitoringFormat.milliseconds(model.ttftP50)) / \(MonitoringFormat.milliseconds(model.ttftP90)) · Body p50 / p90 \(speed(model.tpsP50)) / \(speed(model.tpsP90))"))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func summaryValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(statsString("\(title): \(value)")))
    }

    // MARK: Chart

    private var chartView: some View {
        Chart {
            chartMarks
        }
        .chartXScale(domain: points.map(\.label))
        .chartXSelection(value: Binding(
            get: { selectedBucket?.label },
            set: { label in selectedHour = points.first { $0.label == label }?.hour }
        ))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(centered: false, collisionResolution: .greedy) {
                    if let label = value.as(String.self) {
                        Text(MonitoringFormat.bucketHour(label))
                            .font(.caption2.monospacedDigit())
                            .fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric.axisValue(number))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
        .frame(height: 190)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(statsString("\(model.name), \(metric.title) by three-hour bucket")))
        .accessibilityValue(accessibilityBuckets)
        .accessibilityIdentifier("stats.modelChart")
    }

    /// The chart's marks, apart from its axes and selection: one expression the compiler can
    /// check without solving the whole chart and List together.
    @ChartContentBuilder private var chartMarks: some ChartContent {
        ForEach(points) { point in
            if let p50 = point.p50 {
                LineMark(
                    x: .value(statsString("Bucket"), point.label),
                    y: .value(metric.axisTitle, p50)
                )
                .foregroundStyle(Theme.link)
                .interpolationMethod(.monotone)
                PointMark(
                    x: .value(statsString("Bucket"), point.label),
                    y: .value(metric.axisTitle, p50)
                )
                .foregroundStyle(Theme.link)
                .symbolSize(selectedHour == point.hour ? 70 : 26)
            }
            if let p90 = point.p90 {
                LineMark(
                    x: .value(statsString("Bucket"), point.label),
                    y: .value(metric.axisTitle, p90),
                    series: .value(statsString("Percentile"), "p90")
                )
                .foregroundStyle(Theme.warning)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .interpolationMethod(.monotone)
            }
        }
        if let selected = selectedBucket, selected.requests > 0,
           (metric == .firstToken ? selected.ttftP50 : selected.tpsP50) != nil {
            RuleMark(x: .value(statsString("Bucket"), selected.label))
                .foregroundStyle(Theme.secondaryText.opacity(0.35))
        }
    }

    private var selectedDetail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedBucket?.label ?? "")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            Text(selectedDetailText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var selectedDetailText: String {
        guard let bucket = selectedBucket else { return "" }
        if bucket.requests == 0 {
            return statsString("No samples in this bucket.")
        }
        var parts = [
            statsString("\(bucket.requests) requests"),
            statsString("\(bucket.ok) ok"),
            statsString("\(bucket.error) errors"),
            statsString("\(bucket.canceled) canceled"),
        ]
        if let p50 = bucket.ttftP50 {
            parts.append(statsString("first token p50 \(MonitoringFormat.milliseconds(p50))"))
        }
        if let p90 = bucket.ttftP90 {
            parts.append(statsString("p90 \(MonitoringFormat.milliseconds(p90))"))
        }
        if let p50 = bucket.tpsP50 { parts.append(statsString("body p50 \(speed(p50))")) }
        if let p90 = bucket.tpsP90 { parts.append(statsString("p90 \(speed(p90))")) }
        if let cost = bucket.cost { parts.append(MonitoringFormat.preciseDollars(cost)) }
        return parts.joined(separator: " · ")
    }

    private var bucketGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(points) { point in
                Button {
                    selectedHour = point.hour
                } label: {
                    VStack(spacing: 2) {
                        Text(point.label)
                            .font(.caption2.monospacedDigit())
                        Text(point.displayValue)
                            .font(.caption.weight(.medium).monospacedDigit())
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        selectedHour == point.hour ? Theme.infoTint : Theme.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(statsString("\(point.label): \(point.displayValue), \(point.requests) requests")))
            }
        }
        .padding(.vertical, 4)
    }

    private var accessibilityBuckets: String {
        points.map { point in
            statsString("\(point.label): \(point.displayValue), \(point.requests) requests")
        }.joined(separator: ". ")
    }

    private func speed(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) tok/s"
    }

    // MARK: Data

    private var points: [BucketPoint] {
        buckets.map { bucket in
            let p50 = metric == .firstToken ? bucket.ttftP50 : bucket.tpsP50
            let p90 = metric == .firstToken ? bucket.ttftP90 : bucket.tpsP90
            return BucketPoint(
                hour: bucket.hour, requests: bucket.requests,
                p50: bucket.requests > 0 ? MonitoringFormat.chartValue(p50) : nil,
                p90: bucket.requests > 0 ? MonitoringFormat.chartValue(p90) : nil,
                metric: metric
            )
        }
    }

    private var selectedBucket: MonitoringModelBucket? {
        guard let selectedHour else { return nil }
        return buckets.first { $0.hour == selectedHour }
    }
}

private enum ModelMetric: String, CaseIterable, Identifiable {
    case firstToken, speed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstToken: statsString("First token")
        case .speed: statsString("Body speed")
        }
    }

    var axisTitle: String {
        switch self {
        case .firstToken: statsString("Milliseconds")
        case .speed: statsString("Tokens per second")
        }
    }

    func axisValue(_ value: Double) -> String {
        switch self {
        case .firstToken: MonitoringFormat.milliseconds(value)
        case .speed: value.formatted(.number.precision(.fractionLength(0)))
        }
    }
}

private struct BucketPoint: Identifiable {
    let hour: Int
    let requests: Int
    let p50: Double?
    let p90: Double?
    let metric: ModelMetric

    var id: Int { hour }

    var label: String {
        String(format: "%02d–%02d", hour, (hour + 3) % 24)
    }

    var displayValue: String {
        guard let p50 else { return "—" }
        return metric == .firstToken
            ? MonitoringFormat.milliseconds(p50)
            : p50.formatted(.number.precision(.fractionLength(1)))
    }
}
