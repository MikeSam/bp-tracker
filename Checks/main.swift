// Run: swiftc BPTracker/Reader.swift Checks/main.swift -o /tmp/reader_check && /tmp/reader_check [photo.png ...]
import Foundation
import ImageIO
setvbuf(stdout, nil, _IONBF, 0)

let fixtures: [(path: String, sys: Int, dia: Int, pulse: Int)] = [
    ("Checks/med55.png", 117, 77, 56),
    ("Checks/med55-2.png", 115, 74, 72),
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
    for f in fixtures {
        let r = try await read(f.path)
        precondition(r.sys == f.sys && r.dia == f.dia && r.pulse == f.pulse, "\(f.path): got \(r.sys ?? 0)/\(r.dia ?? 0)/\(r.pulse ?? 0)")
    }
    print("reader_check OK (\(fixtures.count) photos)")
}
