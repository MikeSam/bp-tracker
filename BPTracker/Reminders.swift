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
        content.categoryIdentifier = Snooze.category

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

/// "Remind in 30 min / 1 hour" buttons on the reminder; a tap re-sends the same notification after the delay.
final class Snooze: NSObject, UNUserNotificationCenterDelegate {
    static let category = "bp"
    private static let shared = Snooze()
    private static let delays: [String: TimeInterval] = ["snooze-30m": 30 * 60, "snooze-1h": 60 * 60]

    /// Call at launch: the delegate must be set before the app finishes launching to receive taps made while it wasn't running.
    static func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [
            UNNotificationAction(identifier: "snooze-30m", title: String(localized: "Remind in 30 min")),
            UNNotificationAction(identifier: "snooze-1h", title: String(localized: "Remind in 1 hour")),
        ], intentIdentifiers: [])])
        // Reminders scheduled by older versions lack the category, so they'd show no buttons until Settings is touched.
        Task {
            for request in await center.pendingNotificationRequests() where request.content.categoryIdentifier.isEmpty {
                let content = request.content.mutableCopy() as! UNMutableNotificationContent
                content.categoryIdentifier = category
                try? await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: request.trigger))
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let delay = Self.delays[response.actionIdentifier] else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        // One fixed id: snoozing again replaces the pending snooze instead of stacking them.
        try? await center.add(UNNotificationRequest(identifier: "snooze", content: response.notification.request.content, trigger: trigger))
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
