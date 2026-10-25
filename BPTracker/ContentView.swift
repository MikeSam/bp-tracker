import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var readings: [BPSample] = []
    @State private var range = DateRange.month
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
    @State private var customEnd = Date.now
    @State private var report: Report?
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var draft: Reading?
    @State private var status = String(localized: "Photograph the monitor display.")

    private var window: Window { range.window(custom: min(customStart, customEnd)...customEnd) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack {
                    Picker("Range", selection: $range) {
                        ForEach(DateRange.allCases) { Text(LocalizedStringKey($0.rawValue)) }
                    }
                    .pickerStyle(.segmented)
                    if range == .custom {
                        HStack {
                            DatePicker("From", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                            DatePicker("To", selection: $customEnd, in: customStart...Date.now, displayedComponents: .date)
                        }
                        .labelsHidden()
                        .font(.subheadline)
                    }
                }
                TrendView(readings: readings, window: window)
                Spacer()
                Text(status)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button { showCamera = true } label: {
                    Label("Scan monitor", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label("Choose photo", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding()
            .navigationTitle("BP Tracker")
            .toolbar {
                Button("Export PDF", systemImage: "square.and.arrow.up") {
                    report = Report(readings: window.filter(readings), window: window)
                }
                .disabled(window.filter(readings).isEmpty)
                Button("Reminders", systemImage: "bell") { showSettings = true }
            }
        }
        .task {   // live: covers our saves, the Health app, and other apps
            do { for try await all in Health.readings() { readings = all } } catch { status = error.localizedDescription }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $report) { ReportPreview(report: $0) }
        .onChange(of: pickedItem) {
            Task {
                if let data = try? await pickedItem?.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await read(image)
                }
                pickedItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in Task { await read(image) } }
                .ignoresSafeArea()
        }
        .sheet(item: $draft) { reading in
            ConfirmView(reading: reading) { status = String(localized: "Saved to Health.") }
        }
    }

    private func read(_ image: UIImage) async {
        guard let cg = image.uprightCGImage else { return }
        status = String(localized: "Reading the display…")
        var reading = await Task.detached { try? await readDisplay(cg) }.value ?? Reading()   // off the main thread
        reading.date = .now
        if reading.sys == nil || reading.dia == nil { status = String(localized: "Couldn't read the display — check or type the values.") }
        draft = reading
    }
}

struct ConfirmView: View {
    @State private var reading: Reading
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    init(reading: Reading, onDone: @escaping () -> Void) {
        _reading = State(initialValue: reading)
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Systolic") { field($reading.sys) }
                LabeledContent("Diastolic") { field($reading.dia) }
                LabeledContent("Pulse") { field($reading.pulse) }
                DatePicker("Taken", selection: $reading.date, in: ...Date.now)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Add to Health?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(reading.sys == nil || reading.dia == nil)
                }
            }
        }
    }

    private func field(_ value: Binding<Int?>) -> some View {
        TextField("—", value: value, format: .number)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
    }

    private func save() async {
        guard let sys = reading.sys, let dia = reading.dia else { return }
        do {
            try await Health.save(sys: sys, dia: dia, pulse: reading.pulse, at: reading.date)
            onDone()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview {
    ConfirmView(reading: Reading(sys: 120, dia: 80, pulse: 65)) {}
}
