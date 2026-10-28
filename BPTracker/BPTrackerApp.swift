import SwiftUI

@main
struct BPTrackerApp: App {
    init() { Snooze.register() }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
