import SwiftUI
import UserNotifications

/// One daily local notification per weekday; Sat/Sun use the weekend time.
enum Reminders {
    // ponytail: Sat/Sun weekend hardcoded; use Calendar.isDateInWeekend if Fri/Sat locales matter
    private static let weekendDays: Set<Int> = [1, 7]

    static func schedule(weekdayTime: Date?, weekendTime: Date?) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard weekdayTime != nil || weekendTime != nil else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }

        let content = UNMutableNotificationContent()
        content.title = "Blood pressure check"
        content.body = "Measure and scan your monitor."
        content.sound = .default

        for weekday in 1...7 {
            guard let time = weekendDays.contains(weekday) ? weekendTime : weekdayTime else { continue }
            var date = Calendar.current.dateComponents([.hour, .minute], from: time)
            date.weekday = weekday
            let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
            try? await center.add(UNNotificationRequest(identifier: "bp-\(weekday)", content: content, trigger: trigger))
        }
    }
}

struct SettingsView: View {
    @AppStorage("weekdayOn") private var weekdayOn = false
    @AppStorage("weekendOn") private var weekendOn = false
    @AppStorage("weekdayTime") private var weekdayTime = Self.defaultTime(hour: 8)
    @AppStorage("weekendTime") private var weekendTime = Self.defaultTime(hour: 10)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Weekdays") {
                    Toggle("Remind me", isOn: $weekdayOn)
                    if weekdayOn { timePicker($weekdayTime) }
                }
                Section("Weekend") {
                    Toggle("Remind me", isOn: $weekendOn)
                    if weekendOn { timePicker($weekendTime) }
                }
            }
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: [weekdayOn ? weekdayTime : 0, weekendOn ? weekendTime : 0]) {
                Task {
                    await Reminders.schedule(
                        weekdayTime: weekdayOn ? Date(timeIntervalSinceReferenceDate: weekdayTime) : nil,
                        weekendTime: weekendOn ? Date(timeIntervalSinceReferenceDate: weekendTime) : nil)
                }
            }
        }
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
