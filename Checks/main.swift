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

    // Typed values: whole-input parse, nothing trimmed into a different number.
    for (text, want) in [("120", Parsed.number(120)), (" 120 ", .number(120)), ("", .empty), ("  ", .empty), ("007", .number(7)),
                         ("1200", .number(1200)), ("-120", .invalid), ("1.5", .invalid), ("1,5", .invalid), ("1 200", .invalid),
                         ("12a", .invalid), ("Ⅻ", .invalid), ("½", .invalid), ("１２０", .number(120)), ("٣٤", .number(34)),
                         ("99999999999999999999", .number(.max))] {
        precondition(parse(text) == want, "parse(\"\(text)\") = \(parse(text)), want \(want)")
    }
    func issues(_ s: String, _ d: String, _ p: String = "") -> [Field: Issue] { validate(sys: s, dia: d, pulse: p).issues }
    func saves(_ s: String, _ d: String, _ p: String = "") -> Bool { validate(sys: s, dia: d, pulse: p).values != nil }
    precondition(issues("120", "80", "65").isEmpty && saves("120", "80", "65") && saves("120", "80"))
    precondition(validate(sys: "120", dia: "80", pulse: "").values! == (120, 80, nil))
    // Hard limits: one past them is an error; the endpoints save.
    for (s, d, p, field, issue) in [("49", "30", "", Field.sys, Issue.below(50)), ("301", "80", "", .sys, .above(300)),
                                    ("120", "19", "", .dia, .below(20)), ("300", "251", "", .dia, .above(250)),
                                    ("120", "80", "24", .pulse, .below(25)), ("120", "80", "251", .pulse, .above(250)),
                                    ("1200", "80", "", .sys, .above(300)), ("", "80", "", .sys, .missing), ("120", "", "", .dia, .missing),
                                    ("120", "80", "6x", .pulse, .notANumber), ("80", "120", "", .gap, .sysNotAboveDia), ("90", "90", "", .gap, .sysNotAboveDia)] {
        precondition(issues(s, d, p)[field] == issue && !saves(s, d, p), "\(s)/\(d)/\(p): \(issues(s, d, p))")
    }
    precondition(saves("300", "250", "250") && saves("70", "50", "25"))
    // Warnings: saveable, but flagged low or high.
    precondition(issues("79", "60")[.sys] == .unusuallyLow && issues("201", "100")[.sys] == .unusuallyHigh && saves("201", "100"))
    precondition(issues("120", "39")[.dia] == .unusuallyLow && issues("240", "131")[.dia] == .unusuallyHigh && saves("240", "210"))
    precondition(issues("120", "80", "39")[.pulse] == .unusuallyLow && issues("120", "80", "151")[.pulse] == .unusuallyHigh)
    precondition(issues("80", "40", "40")[.sys] == nil && issues("200", "130", "150")[.dia] == nil)
    // Gap: 15…100 is quiet, 14 and 101 are flagged; an out-of-range field gets no gap check at all.
    precondition(issues("115", "100")[.gap] == nil && issues("114", "100")[.gap] == .unusualGap && saves("114", "100"))
    precondition(issues("180", "80")[.gap] == nil && issues("181", "80")[.gap] == .unusualGap)
    precondition(issues("1200", "80")[.gap] == nil && issues("\(Int.max)", "\(Int.min)")[.sys] == .above(300))
    precondition(Limits.allows(sys: 120, dia: 80, pulse: nil) && !Limits.allows(sys: 120, dia: 80, pulse: 300) && !Limits.allows(sys: Int.max, dia: Int.min, pulse: nil))

    // Pulse links: only a heart rate known to belong to a reading is edited/deleted with it (pulseID);
    // others may still show the nearest unlinked pulse within a minute.
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    func bp(_ at: Date, own: Bool = true, id: String? = nil) -> BPSample {
        BPSample(id: UUID(), date: at, sys: 120, dia: 80, isOwn: own, sourceName: own ? "BP Tracker" : "Omron", readingID: id)
    }
    func merge(_ bps: [BPSample], _ hrs: [(UUID, Date, Int, String?)]) -> [BPSample] {
        let m = Health.Merged()
        m.bps = bps
        for (id, at, n, rid) in hrs { m.pulses[id] = .init(date: at, bpm: n, readingID: rid) }
        return m.readings
    }
    let hrA = UUID(), hrB = UUID()
    var out = merge([bp(t, id: "A")], [(hrA, t, 70, "A")])
    precondition(out[0].pulseID == hrA && out[0].pulse == 70)
    out = merge([bp(t, id: "A"), bp(t.addingTimeInterval(10), id: "B")], [(hrA, t, 70, "A")])   // B saved without pulse: doesn't borrow A's
    precondition(out[0].pulseID == hrA && out[1].pulse == nil && out[1].pulseID == nil)
    out = merge([bp(t)], [(hrA, t, 70, nil)])   // before IDs: exact time, nothing else there
    precondition(out[0].pulseID == hrA && out[0].pulse == 70)
    out = merge([bp(t), bp(t)], [(hrA, t, 70, nil)])   // two readings at that instant: ambiguous, display only
    precondition(out.allSatisfy { $0.pulseID == nil && $0.pulse == 70 })
    out = merge([bp(t)], [(hrA, t, 70, nil), (hrB, t, 72, nil)])
    precondition(out[0].pulseID == nil)
    out = merge([bp(t)], [(hrA, t.addingTimeInterval(10), 70, nil)])   // close but not exact: display only
    precondition(out[0].pulseID == nil && out[0].pulse == 70)
    out = merge([bp(t, own: false)], [(hrA, t, 70, nil)])   // another app's reading never owns our heart rate
    precondition(out[0].pulseID == nil && out[0].pulse == 70)
    out = merge([bp(t), bp(t.addingTimeInterval(20), id: "B")], [(hrA, t.addingTimeInterval(20), 70, "B")])   // a linked pulse isn't lent out
    precondition(out[0].pulse == nil && out[1].pulseID == hrA)

    // The same rule on fresh Health data at delete/edit time: a link that became ambiguous is dropped.
    precondition(Health.linkedPulse(readingID: "A", unlinkedReadingsAtSameTime: 0, candidates: [(hrA, "A")]) == hrA)
    precondition(Health.linkedPulse(readingID: "A", unlinkedReadingsAtSameTime: 0, candidates: [(hrA, "A"), (hrB, "A")]) == nil)
    precondition(Health.linkedPulse(readingID: "A", unlinkedReadingsAtSameTime: 0, candidates: [(hrA, nil)]) == nil)
    precondition(Health.linkedPulse(readingID: nil, unlinkedReadingsAtSameTime: 1, candidates: [(hrA, nil)]) == hrA)
    precondition(Health.linkedPulse(readingID: nil, unlinkedReadingsAtSameTime: 2, candidates: [(hrA, nil)]) == nil)   // another reading synced in at that time
    precondition(Health.linkedPulse(readingID: nil, unlinkedReadingsAtSameTime: 1, candidates: [(hrA, nil), (hrB, nil)]) == nil)
    precondition(Health.linkedPulse(readingID: nil, unlinkedReadingsAtSameTime: 1, candidates: [(hrA, "B")]) == nil)
    let window = Health.timeWindow(around: t)   // the fresh lookup's query window must strictly contain the reading's time
    precondition(window.lowerBound < t && t < window.upperBound)

    for f in fixtures {
        let r = try await read(f.path)
        precondition(r.sys == f.sys && r.dia == f.dia && r.pulse == f.pulse, "\(f.path): got \(r.sys ?? 0)/\(r.dia ?? 0)/\(r.pulse ?? 0)")
    }
    print("reader_check OK (\(fixtures.count) photos, chart buckets)")
}
