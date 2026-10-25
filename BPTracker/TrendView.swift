import SwiftUI
import Charts

enum DateRange: String, CaseIterable, Identifiable {
    case week = "7D", month = "30D", quarter = "90D", year = "1Y", custom = "Custom"
    var id: Self { self }

    /// The dates the chart covers. Presets end now; `custom` is what the user picked.
    func window(custom: ClosedRange<Date>) -> Window {
        let days: Int
        switch self {
        case .week: days = 7
        case .month: days = 30
        case .quarter: days = 90
        case .year: days = 365
        case .custom: return Window(start: Calendar.current.startOfDay(for: custom.lowerBound), end: custom.upperBound.endOfDay)
        }
        return Window(start: Calendar.current.date(byAdding: .day, value: -days, to: .now)!, end: .now)
    }
}

/// A span of dates to chart, with readings grouped so bars stay legible.
struct Window: Equatable {
    let start: Date
    let end: Date

    /// One bar per bucket; `nil` shows every reading.
    // ponytail: weekly buckets beyond 120 days; switch to months once a window can span years
    var bucket: Calendar.Component? {
        let days = end.timeIntervalSince(start) / 86_400
        return days <= 10 ? nil : days <= 120 ? .day : .weekOfYear
    }

    /// Axis domain snapped to whole buckets.
    var domain: ClosedRange<Date> {
        guard let bucket else { return start...end }
        let cal = Calendar.current
        return cal.dateInterval(of: bucket, for: start)!.start...cal.dateInterval(of: bucket, for: end)!.end
    }

    func filter(_ readings: [BPSample]) -> [BPSample] {
        readings.filter { (start...end).contains($0.date) }
    }

    func bars(_ readings: [BPSample]) -> [Bar] {
        let shown = filter(readings)
        guard let bucket else {
            return shown.map { Bar(id: $0.date, interval: DateInterval(start: $0.date, duration: 0), sys: $0.sys...$0.sys, dia: $0.dia...$0.dia, pulse: $0.pulse, count: 1) }
        }
        let cal = Calendar.current
        return Dictionary(grouping: shown) { cal.dateInterval(of: bucket, for: $0.date)!.start }
            .map { start, group in
                let sys = group.map(\.sys), dia = group.map(\.dia), pulses = group.compactMap(\.pulse)
                return Bar(id: start, interval: cal.dateInterval(of: bucket, for: start)!,
                           sys: sys.min()!...sys.max()!, dia: dia.min()!...dia.max()!,
                           pulse: pulses.isEmpty ? nil : pulses.reduce(0, +) / pulses.count, count: group.count)
            }
            .sorted { $0.id < $1.id }
    }
}

extension Date {
    var endOfDay: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: self))!.addingTimeInterval(-1) }
}

/// One chart bar: a single reading, or the span of all readings in a day or week.
struct Bar: Identifiable {
    let id: Date              // bucket start, or the reading time
    let interval: DateInterval
    let sys: ClosedRange<Int>
    let dia: ClosedRange<Int>
    let pulse: Int?           // mean over the bucket
    let count: Int

    var mid: Date { interval.start.addingTimeInterval(interval.duration / 2) }
    var values: String {
        let bp = count == 1 ? "\(sys.upperBound)/\(dia.lowerBound)" : "\(sys.lowerBound)–\(sys.upperBound) / \(dia.lowerBound)–\(dia.upperBound)"
        return pulse.map { String(localized: "\(bp) · \($0) bpm") } ?? bp
    }
    var when: String {
        switch count {
        case 1: id.formatted(date: .abbreviated, time: .shortened)
        default: String(localized: "\(count) readings") + " · " + (interval.duration <= 86_400 ? id.formatted(date: .abbreviated, time: .omitted)
                                                                         : (interval.start..<interval.end).formatted(date: .abbreviated, time: .omitted))
        }
    }
}

/// Latest reading as a headline plus a trend chart of the selected window.
struct TrendView: View {
    let readings: [BPSample]
    let window: Window

    var body: some View {
        if let latest = readings.last {
            let when = latest.date.formatted(date: .abbreviated, time: .shortened)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(latest.sys)/\(latest.dia)")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                + Text(" mmHg").font(.title3).foregroundStyle(.secondary)
                + Text(latest.pulse.map { "  " + String(localized: "\($0) bpm") } ?? "").font(.title3).foregroundStyle(.pink)
                Text(when)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(latest.pulse.map { String(localized: "Latest reading \(latest.sys) over \(latest.dia), pulse \($0), \(when)") }
                                ?? String(localized: "Latest reading \(latest.sys) over \(latest.dia), \(when)"))

            BPChart(readings: readings, window: window)
                .frame(height: 240)
        } else {
            ContentUnavailableView(
                "No readings yet", systemImage: "waveform.path.ecg",
                description: Text("Scan your monitor to add one. If you already have readings, allow access in Health → Sharing → Apps."))
        }
    }
}

/// Health-style range bars: each bar spans diastolic to systolic; pulse is the dotted line. Tap or drag to read one off.
struct BPChart: View {
    let readings: [BPSample]
    let window: Window
    @State private var selectedDate: Date?
    private let bpLabel = String(localized: "Blood pressure"), pulseLabel = String(localized: "Pulse")

    private func selected(in bars: [Bar]) -> Bar? {
        guard let selectedDate else { return nil }
        return bars.min { abs($0.mid.timeIntervalSince(selectedDate)) < abs($1.mid.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        let bars = window.bars(readings)
        let selected = selected(in: bars)
        Chart(bars) { bar in
            BarMark(x: .value("Date", bar.id, unit: window.bucket ?? .second),
                    yStart: .value("Diastolic", bar.dia.lowerBound), yEnd: .value("Systolic", bar.sys.upperBound),
                    width: window.bucket == nil ? .fixed(6) : .ratio(0.6))
                .cornerRadius(3)
                .foregroundStyle(by: .value("Measure", bpLabel))
                .opacity(selected == nil || selected?.id == bar.id ? 1 : 0.35)
            if let pulse = bar.pulse {
                LineMark(x: .value("Date", bar.mid), y: .value("Pulse", pulse))
                    .foregroundStyle(by: .value("Measure", pulseLabel))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    .symbol(.circle)
                    .symbolSize(20)
            }
            if let selected, selected.id == bar.id {
                RuleMark(x: .value("Date", bar.mid))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bar.values).font(.headline.monospacedDigit())
                            Text(bar.when).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(.regularMaterial, in: .rect(cornerRadius: 6))
                    }
            }
        }
        .chartForegroundStyleScale([bpLabel: Color.accentColor, pulseLabel: Color.pink])
        .chartXScale(domain: window.domain)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXSelection(value: $selectedDate)
        .overlay {
            if bars.isEmpty {
                Text("No readings in this range").foregroundStyle(.secondary)
            }
        }
    }
}

extension [BPSample] {
    /// Two weeks of plausible readings for previews.
    static var mock: [BPSample] {
        (0..<14).map { i in
            BPSample(id: UUID(), date: Date(timeIntervalSinceNow: -Double(13 - i) * 86_400 + Double(i % 3) * 3_600),
                     sys: 112 + (i * 7) % 18, dia: 72 + (i * 5) % 11, pulse: i % 4 == 0 ? nil : 58 + (i * 3) % 14)
        }
    }
}

#Preview("Trend") {
    TrendView(readings: .mock, window: DateRange.month.window(custom: .now ... .now)).padding()
}

#Preview("Empty") {
    TrendView(readings: [], window: DateRange.month.window(custom: .now ... .now))
}
