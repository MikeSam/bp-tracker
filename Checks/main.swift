// Run: swiftc -target arm64-apple-macos15.0 BPTracker/Reader.swift BPTracker/TrendView.swift BPTracker/Health.swift Checks/main.swift -o /tmp/reader_check && /tmp/reader_check [photo.png ...]
import Foundation
import ImageIO
import SwiftUI
setvbuf(stdout, nil, _IONBF, 0)

// pulse nil: the photo's pulse isn't read yet (digits in shadow / welded to the LCD edge); it must never be read wrong.
let fixtures: [(path: String, sys: Int, dia: Int, pulse: Int?)] = [
    ("Checks/med55.png", 117, 77, 56),
    ("Checks/med55-2.png", 115, 74, 72),
    ("Checks/med55-3.jpg", 122, 76, 66),
    ("Checks/omron-hem7120.jpg", 119, 68, nil),
    ("Checks/omron-hem7120-2.jpg", 161, 89, 64),
    ("Checks/omron-hem7120-3.jpg", 109, 82, nil),
    ("Checks/omron-m3.jpg", 131, 78, 67),
    ("Checks/omron-m2-plus.jpg", 104, 70, 74),
    ("Checks/omron-r6.jpg", 114, 75, 72),
    ("Checks/sanitas-wrist.jpg", 120, 74, 80),
    ("Checks/microlife.jpg", 138, 73, nil),
]

func read(_ path: String) async throws -> Reading {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return try await readDisplay(CGImageSourceCreateImageAtIndex(source, 0, nil)!)
}

if CommandLine.arguments.count > 1 {           // ad-hoc: print readings for the given photos
    for path in CommandLine.arguments.dropFirst() {
        let r = try await read(path)
        print("\(path): sys=\(r.sys.map(String.init) ?? "nil") dia=\(r.dia.map(String.init) ?? "nil") pulse=\(r.pulse.map(String.init) ?? "nil")")
    }
} else {
    // Chart bucketing: ≤10 days shows every reading, ≤120 days one bar per day spanning min dia…max sys, longer one bar per week.
    let day: TimeInterval = 86_400
    let readings = (0..<20).map { i in BPSample(id: UUID(), date: Date(timeIntervalSinceNow: -Double(19 - i) * day / 2), sys: 110 + i, dia: 70 + i % 5, pulse: 60 + i) }
    let week = DateRange.week.window(custom: .now ... .now), month = DateRange.month.window(custom: .now ... .now)
    precondition(week.bars(readings).count == readings.filter { $0.date >= Date(timeIntervalSinceNow: -7 * day) }.count)
    let daily = month.bars(readings)
    precondition(daily.allSatisfy { $0.count <= 2 && $0.interval.duration >= day - 3_600 } && daily.map(\.count).reduce(0, +) == readings.count)
    for bar in daily {
        let inside = readings.filter { bar.interval.contains($0.date) }
        precondition(bar.count == inside.count && bar.sys == inside.map(\.sys).min()!...inside.map(\.sys).max()!, "\(bar)")
        precondition(bar.pulse == inside.compactMap(\.pulse).reduce(0, +) / inside.count, "\(bar)")
        precondition(bar.last == inside.map(\.date).max()!, "\(bar)")
    }
    let year = DateRange.custom.window(custom: Date(timeIntervalSinceNow: -365 * day) ... .now)
    precondition(year.bars(readings).allSatisfy { $0.interval.duration >= 7 * day - 3_600 } && year.bars([]).isEmpty)
    let twoDays = DateRange.custom.window(custom: Date(timeIntervalSinceNow: -2 * day) ... .now)
    precondition(twoDays.bucket == nil && twoDays.bars(readings).allSatisfy { $0.count == 1 })

    for f in fixtures {
        let r = try await read(f.path)
        precondition(r.sys == f.sys && r.dia == f.dia && r.pulse == f.pulse, "\(f.path): got \(r.sys ?? 0)/\(r.dia ?? 0)/\(r.pulse ?? 0)")
    }
    print("reader_check OK (\(fixtures.count) photos, chart buckets)")
}
