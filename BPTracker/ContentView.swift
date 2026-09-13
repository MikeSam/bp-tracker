import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var draft: Reading?
    @State private var status = "Photograph the monitor display."

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
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
                Button("Reminders", systemImage: "bell") { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
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
            ConfirmView(reading: reading) { status = $0 }
        }
    }

    private func read(_ image: UIImage) async {
        guard let cg = image.uprightCGImage else { return }
        var reading = (try? await readDisplay(cg)) ?? Reading()
        reading.date = .now
        if reading.sys == nil || reading.dia == nil { status = "Couldn't read the display — check or type the values." }
        draft = reading
    }
}

struct ConfirmView: View {
    @State var reading: Reading
    var onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

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
            onDone("Saved \(sys)/\(dia)" + (reading.pulse.map { " · \($0) bpm" } ?? "") + " at \(reading.date.formatted(date: .abbreviated, time: .shortened))")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview {
    ConfirmView(reading: Reading(sys: 120, dia: 80, pulse: 65)) { _ in }
}
