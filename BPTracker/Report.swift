import SwiftUI
import PDFKit

/// The readings in view as a PDF: summary and chart on the first page, then a dated table.
struct Report: Identifiable {
    let id = UUID()
    let readings: [BPSample]
    let window: Window

    @MainActor
    func pdf() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: String(localized: "Blood Pressure") + ".pdf")
        let usLetter = Locale.current.measurementSystem == .us
        var page = CGRect(origin: .zero, size: usLetter ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842))
        guard let pdf = CGContext(url as CFURL, mediaBox: &page, nil) else { throw CocoaError(.fileWriteUnknown) }

        var rows = readings.reversed()[...]   // newest first
        var pageNumber = 1
        repeat {
            let count = pageNumber == 1 ? 16 : 40
            let content = ReportPage(report: self, rows: Array(rows.prefix(count)), pageNumber: pageNumber)
                .frame(width: page.width, height: page.height)
            ImageRenderer(content: content).render { _, draw in
                pdf.beginPDFPage(nil); draw(pdf); pdf.endPDFPage()
            }
            rows = rows.dropFirst(count)
            pageNumber += 1
        } while !rows.isEmpty
        pdf.closePDF()
        return url
    }
}

private struct ReportPage: View {
    let report: Report
    let rows: [BPSample]
    let pageNumber: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if pageNumber == 1 {
                Text("Blood Pressure").font(.title.bold())
                Text((report.window.start..<report.window.end).formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.secondary)
                Summary(readings: report.readings)
                BPChart(readings: report.readings, window: report.window)
                    .frame(height: 220)
                    .padding(.bottom, 8)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    Text("Date"); Text("Systolic"); Text("Diastolic"); Text("Pulse")
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                Divider()
                ForEach(rows) { r in
                    GridRow {
                        Text(r.date.formatted(date: .abbreviated, time: .shortened))
                        Text("\(r.sys)").gridColumnAlignment(.trailing)
                        Text("\(r.dia)").gridColumnAlignment(.trailing)
                        Text(r.pulse.map { "\($0)" } ?? "–").gridColumnAlignment(.trailing)
                    }
                    .monospacedDigit()
                }
            }
            .font(.footnote)
            Spacer(minLength: 0)
            Text("Page \(pageNumber)").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(40)
        .background(.white)
        .environment(\.colorScheme, .light)
    }
}

/// Health-style summary strip: count, ranges, mean.
private struct Summary: View {
    let readings: [BPSample]

    var body: some View {
        let sys = readings.map(\.sys), dia = readings.map(\.dia), pulse = readings.compactMap(\.pulse)
        HStack(alignment: .top, spacing: 24) {
            stat("Measurements", "\(readings.count)")
            if let lo = sys.min(), let hi = sys.max() { stat("Systolic", "\(lo)–\(hi)", unit: "mmHg") }
            if let lo = dia.min(), let hi = dia.max() { stat("Diastolic", "\(lo)–\(hi)", unit: "mmHg") }
            if !sys.isEmpty { stat("Mean", "\(sys.reduce(0, +) / sys.count)/\(dia.reduce(0, +) / dia.count)", unit: "mmHg") }
            if !pulse.isEmpty { stat("Mean pulse", "\(pulse.reduce(0, +) / pulse.count)", unit: "bpm") }
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String, unit: LocalizedStringKey? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            (Text(value).font(.headline.monospacedDigit()) + Text(" ") + Text(unit ?? "").font(.caption).foregroundStyle(.secondary))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)   // shrink, don't truncate, ranges like 114–131 and long translated labels
    }
}

#if canImport(UIKit)
/// Renders the PDF, shows it, and offers the finished file to share. Rendering happens here so the spinner is visible.
struct ReportPreview: View {
    let report: Report
    @State private var url: URL?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    PDFKitView(url: url).ignoresSafeArea(edges: .bottom)
                } else if let error {
                    ContentUnavailableView("Couldn't create the PDF", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView("Preparing PDF…")
                }
            }
            .navigationTitle("Blood Pressure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { if let url { ShareLink(item: url) } }
            }
        }
        .task {
            await Task.yield()   // let the sheet and spinner draw before rendering blocks the main actor
            do { url = try report.pdf() } catch { self.error = error.localizedDescription }
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
#endif

#Preview("Report page") {
    let window = DateRange.month.window(custom: .now ... .now)
    ReportPage(report: Report(readings: .mock, window: window), rows: [BPSample].mock.reversed(), pageNumber: 1)
        .frame(width: 595, height: 842)
}
