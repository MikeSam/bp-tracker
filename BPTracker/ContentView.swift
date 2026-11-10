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
    @State private var showHistory = false
    @State private var demoMode = false   // mock readings: nothing in Health to edit
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
                Button("History", systemImage: "list.bullet") { showHistory = true }
                    .disabled(readings.isEmpty)
                Button("Reminders", systemImage: "bell") { showSettings = true }
            }
        }
        .task {   // live: covers our saves, the Health app, and other apps
            #if DEBUG
            if let arg = UserDefaults.standard.string(forKey: "demo") { return await demo(arg) }
            #endif
            do { for try await all in Health.readings() { readings = all } } catch { status = error.localizedDescription }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHistory) { HistoryView(readings: window.filter(readings), readOnly: demoMode) }
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
            ConfirmView(reading: reading, readOnly: demoMode) { status = $0 }
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

    #if DEBUG
    /// Screenshot mode: mock readings instead of Health, then `-demo 1Y`, `report`, `reminders`, `history` or a photo path.
    private func demo(_ arg: String) async {
        readings = .mock
        demoMode = true
        if let preset = DateRange(rawValue: arg) { range = preset }
        else if arg == "history" { range = .week; showHistory = true }
        else if arg == "report" { report = Report(readings: window.filter(readings), window: window) }
        else if arg == "reminders" { showSettings = true }
        else if let image = UIImage(contentsOfFile: arg) { await read(image) }
    }
    #endif
}

/// The form for a new reading (scanned or typed) or for editing a saved one.
struct ConfirmView: View {
    enum Mode { case add, edit(BPSample) }

    @State private var reading: Reading
    @State private var sys: String
    @State private var dia: String
    @State private var pulse: String
    let mode: Mode
    var readOnly = false   // demo mode: shown for screenshots, never written to Health
    /// Called after the sheet's work is done, with what to tell the user.
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var saving = false

    init(reading: Reading, mode: Mode = .add, readOnly: Bool = false, onDone: @escaping (String) -> Void) {
        _reading = State(initialValue: reading)
        _sys = State(initialValue: reading.sys.map(String.init) ?? "")
        _dia = State(initialValue: reading.dia.map(String.init) ?? "")
        _pulse = State(initialValue: reading.pulse.map(String.init) ?? "")
        self.mode = mode
        self.readOnly = readOnly
        self.onDone = onDone
    }

    private var validation: Validation { validate(sys: sys, dia: dia, pulse: pulse) }

    private var original: BPSample? {
        if case .edit(let sample) = mode { sample } else { nil }
    }

    /// Nothing to save in edit mode until a value or the time differs from the saved reading.
    private var changed: Bool {
        guard let original else { return true }
        guard let v = validation.values else { return false }
        return v.sys != original.sys || v.dia != original.dia || v.pulse != (original.pulseID == nil ? nil : original.pulse)
            || reading.date != original.date
    }

    var body: some View {
        let issues = validation.issues
        NavigationStack {
            Form {
                let pairError = issues[.gap]?.isError == true   // systolic not above diastolic: both numbers are suspect
                row("Systolic", $sys, issues[.sys], red: pairError)
                row("Diastolic", $dia, issues[.dia], also: issues[.gap], red: pairError)
                row("Pulse", $pulse, issues[.pulse])
                if let original, original.pulseID == nil, original.pulse != nil {
                    Text("The pulse shown for this reading was saved separately and isn't changed here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                DatePicker("Taken", selection: $reading.date, in: ...Date.now)
                if let error { Text(error).foregroundStyle(.red) }
                if readOnly { Text("Demo data: changes aren't saved.").foregroundStyle(.secondary) }
            }
            .navigationTitle(original == nil ? LocalizedStringKey("Add to Health?") : "Edit reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(validation.values == nil || !changed || saving || readOnly)
                }
            }
        }
    }

    /// A value row, with the field's issue (and the systolic/diastolic one, under diastolic) beneath it.
    private func row(_ title: LocalizedStringKey, _ text: Binding<String>, _ issue: Issue?, also extra: Issue? = nil, red: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField("—", text: text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(red || issue?.isError == true ? .red : .primary)
            }
            ForEach([issue, extra].compactMap { $0 }.filter { $0.message != nil }, id: \.self) { issue in
                Text(issue.message!)
                    .font(.footnote)
                    .foregroundStyle(issue.isError ? .red : .orange)
            }
        }
    }

    private func save() async {
        guard !saving, !readOnly, changed, let values = validation.values else { return }
        saving = true
        defer { saving = false }
        let date = reading.date
        do {
            if let original {
                try await Health.replace(original, sys: values.sys, dia: values.dia, pulse: values.pulse, at: date)
                onDone(String(localized: "Reading updated."))
            } else {
                try await Health.save(sys: values.sys, dia: values.dia, pulse: values.pulse, at: date)
                onDone(String(localized: "Saved to Health."))
            }
            dismiss()
        } catch HealthError.oldNotRemoved {
            // The new reading is saved: close rather than let Save write it a second time.
            onDone(HealthError.oldNotRemoved.localizedDescription)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension Issue {
    /// What to tell the user; nil for an empty required field, where the disabled Save button says enough.
    var message: String? {
        switch self {
        case .missing: nil
        case .notANumber: String(localized: "Enter a whole number")
        case .below(let n): String(localized: "Must be at least \(n)")
        case .above(let n): String(localized: "Must be at most \(n)")
        case .sysNotAboveDia: String(localized: "Systolic must be higher than diastolic")
        case .unusuallyLow: String(localized: "Unusually low — check the value")
        case .unusuallyHigh: String(localized: "Unusually high — check the value")
        case .unusualGap: String(localized: "Unusual gap between systolic and diastolic — check both values")
        }
    }
}

#Preview {
    ConfirmView(reading: Reading(sys: 120, dia: 80, pulse: 65)) { _ in }
}
