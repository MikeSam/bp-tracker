import SwiftUI

/// Every reading in the selected range, newest first, grouped by day. Readings this app saved can be edited or deleted.
struct HistoryView: View {
    let readings: [BPSample]   // already filtered to the range; live, so edits and deletes show up on their own
    var readOnly = false       // demo mode: mock readings aren't in Health, so the form opens but can't save, and nothing deletes
    @Environment(\.dismiss) private var dismiss
    @State private var editing: BPSample?
    @State private var pendingDelete: BPSample?
    @State private var busy = false
    @State private var message: String?

    private var days: [(day: Date, readings: [BPSample])] {
        Dictionary(grouping: readings) { Calendar.current.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(days, id: \.day) { day in
                    Section {
                        ForEach(day.readings) { row($0) }
                    } header: {
                        Text(day.day, format: .dateTime.weekday(.wide).day().month(.wide).year())
                    }
                }
                if readings.contains(where: { !$0.isOwn }) {
                    Section {} footer: { Text("Readings added by other apps can only be changed there.") }
                }
            }
            .overlay {
                if readings.isEmpty { ContentUnavailableView("No readings in this range", systemImage: "list.bullet") }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $editing) { sample in
                ConfirmView(reading: Reading(sys: sample.sys, dia: sample.dia, pulse: sample.pulseID == nil ? nil : sample.pulse, date: sample.date),
                            mode: .edit(sample), readOnly: readOnly) { message = $0 }
            }
            .confirmationDialog("Delete this reading?", isPresented: .init { pendingDelete != nil } set: { if !$0 { pendingDelete = nil } },
                                titleVisibility: .visible, presenting: pendingDelete) { sample in
                Button("Delete", role: .destructive) { Task { await delete(sample) } }
            } message: { _ in
                Text("It will be removed from Health.")
            }
            .alert(message ?? "", isPresented: .init { message != nil } set: { if !$0 { message = nil } }) {}
        }
    }

    /// A reading this app saved opens its edit form on tap (with a chevron saying so), and has Edit and Delete
    /// on swipe and long press. Others are plain rows.
    @ViewBuilder private func row(_ sample: BPSample) -> some View {
        if sample.isOwn {
            Button { edit(sample) } label: {
                HStack {
                    rowContent(sample)
                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .swipeActions {
                if !readOnly { Button("Delete", systemImage: "trash", role: .destructive) { askDelete(sample) } }
                Button("Edit", systemImage: "pencil") { edit(sample) }.tint(.blue)
            }
            .contextMenu {
                Button("Edit", systemImage: "pencil") { edit(sample) }
                if !readOnly { Button("Delete", systemImage: "trash", role: .destructive) { askDelete(sample) } }
            }
        } else {
            rowContent(sample)
        }
    }

    private func edit(_ sample: BPSample) { if !busy { editing = sample } }
    private func askDelete(_ sample: BPSample) { if !busy { pendingDelete = sample } }

    private func rowContent(_ sample: BPSample) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sample.sys)/\(sample.dia)").font(.headline).monospacedDigit()
                    + Text(" mmHg").font(.subheadline).foregroundStyle(.secondary)
                if !sample.isOwn {
                    Text("From \(sample.sourceName)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let pulse = sample.pulse {
                Text("\(pulse) bpm").font(.subheadline).monospacedDigit().foregroundStyle(.pink)
            }
            Text(sample.date, format: .dateTime.hour().minute())
                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    private func delete(_ sample: BPSample) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await Health.delete(sample) } catch { message = error.localizedDescription }
    }
}

#Preview {
    HistoryView(readings: Array([BPSample].mock.suffix(12)))
}
