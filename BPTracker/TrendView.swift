import SwiftUI
import Charts

/// Latest reading as a headline plus a systolic/diastolic trend line.
struct TrendView: View {
    let readings: [BPSample]

    var body: some View {
        if let latest = readings.last {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(latest.sys)/\(latest.dia)")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                + Text(" mmHg").font(.title3).foregroundStyle(.secondary)
                Text(latest.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Latest reading \(latest.sys) over \(latest.dia), \(latest.date.formatted(date: .abbreviated, time: .shortened))")

            Chart(readings) { r in
                LineMark(x: .value("Date", r.date), y: .value("Systolic", r.sys))
                    .foregroundStyle(by: .value("Measure", "Systolic"))
                    .symbol(.circle)
                LineMark(x: .value("Date", r.date), y: .value("Diastolic", r.dia))
                    .foregroundStyle(by: .value("Measure", "Diastolic"))
                    .symbol(.circle)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 220)
        } else {
            ContentUnavailableView(
                "No readings yet", systemImage: "waveform.path.ecg",
                description: Text("Scan your monitor to add one. If you already have readings, allow access in Health → Sharing → Apps."))
        }
    }
}

#Preview("Trend") {
    let day: TimeInterval = 86_400
    let samples: [BPSample] = (0..<14).map { i in
        BPSample(id: UUID(), date: Date(timeIntervalSinceNow: -Double(13 - i) * day), sys: 112 + (i * 7) % 18, dia: 72 + (i * 5) % 11)
    }
    TrendView(readings: samples).padding()
}

#Preview("Empty") {
    TrendView(readings: [])
}
