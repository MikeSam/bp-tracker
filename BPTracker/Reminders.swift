import SwiftUI
import UserNotifications

/// Daily local notifications at each chosen time; Sat/Sun use the weekend times.
enum Reminders {
    // ponytail: Sat/Sun weekend hardcoded; use Calendar.isDateInWeekend if Fri/Sat locales matter
    private static let weekendDays: Set<Int> = [1, 7]

    static func schedule(weekdayTimes: [Date], weekendTimes: [Date]) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard !weekdayTimes.isEmpty || !weekendTimes.isEmpty else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }

        let content = UNMutableNotificationContent()
        content.title = NSString.localizedUserNotificationString(forKey: "Blood pressure check", arguments: nil)   // resolved at delivery, in the current language
        content.body = NSString.localizedUserNotificationString(forKey: "Measure and scan your monitor.", arguments: nil)
        content.sound = .default

        for weekday in 1...7 {
            for (i, time) in (weekendDays.contains(weekday) ? weekendTimes : weekdayTimes).enumerated() {
                var date = Calendar.current.dateComponents([.hour, .minute], from: time)
                date.weekday = weekday
                let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
                try? await center.add(UNNotificationRequest(identifier: "bp-\(weekday)-\(i)", content: content, trigger: trigger))
            }
        }
    }
}

struct SettingsView: View {
    // The original single reminder per category is kept as the morning one.
    @AppStorage("weekdayOn") private var weekdayMorningOn = false
    @AppStorage("weekdayTime") private var weekdayMorning = Self.defaultTime(hour: 8)
    @AppStorage("weekdayEveningOn") private var weekdayEveningOn = false
    @AppStorage("weekdayEveningTime") private var weekdayEvening = Self.defaultTime(hour: 20)
    @AppStorage("weekendOn") private var weekendMorningOn = false
    @AppStorage("weekendTime") private var weekendMorning = Self.defaultTime(hour: 10)
    @AppStorage("weekendEveningOn") private var weekendEveningOn = false
    @AppStorage("weekendEveningTime") private var weekendEvening = Self.defaultTime(hour: 20)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Weekdays") {
                    reminder("Morning", $weekdayMorningOn, $weekdayMorning)
                    reminder("Evening", $weekdayEveningOn, $weekdayEvening)
                }
                Section("Weekend") {
                    reminder("Morning", $weekendMorningOn, $weekendMorning)
                    reminder("Evening", $weekendEveningOn, $weekendEvening)
                }
            }
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: [weekdayTimes, weekendTimes]) {
                Task { await Reminders.schedule(weekdayTimes: weekdayTimes, weekendTimes: weekendTimes) }
            }
        }
    }

    private var weekdayTimes: [Date] { times((weekdayMorningOn, weekdayMorning), (weekdayEveningOn, weekdayEvening)) }
    private var weekendTimes: [Date] { times((weekendMorningOn, weekendMorning), (weekendEveningOn, weekendEvening)) }
    private func times(_ slots: (Bool, Double)...) -> [Date] {
        slots.filter(\.0).map { Date(timeIntervalSinceReferenceDate: $0.1) }
    }

    @ViewBuilder
    private func reminder(_ title: LocalizedStringKey, _ on: Binding<Bool>, _ time: Binding<Double>) -> some View {
        Toggle(title, isOn: on)
        if on.wrappedValue { timePicker(time) }
    }

    /// AppStorage can't hold Date, so times are stored as timeIntervalSinceReferenceDate.
    private func timePicker(_ seconds: Binding<Double>) -> some View {
        DatePicker("Time", selection: Binding(
            get: { Date(timeIntervalSinceReferenceDate: seconds.wrappedValue) },
            set: { seconds.wrappedValue = $0.timeIntervalSinceReferenceDate }
        ), displayedComponents: .hourAndMinute)
    }

    private static func defaultTime(hour: Int) -> Double {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!.timeIntervalSinceReferenceDate
    }
}

#Preview { SettingsView() }
