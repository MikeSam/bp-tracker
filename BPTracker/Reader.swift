import Foundation
import CoreGraphics
import Vision

struct Reading: Identifiable {
    let id = UUID()
    var sys: Int?
    var dia: Int?
    var pulse: Int?
    var date: Date = .now
}

/// The app's entry limits for a reading. They catch typos and misreads; they are not medical ranges,
/// so a value inside `usual…` can still be unhealthy. Outside the hard ranges a reading can't be saved;
/// outside the usual ones the form only asks to check the value.
enum Limits {
    static let sys = 50...300, dia = 20...250, pulse = 25...250   // diastolic up to 250: some monitors report 215
    static let usualSys = 80...200, usualDia = 40...130, usualPulse = 40...150
    static let usualGap = 15...100   // systolic minus diastolic; outside this a digit is often mistyped

    static func allows(sys: Int, dia: Int, pulse: Int?) -> Bool {
        validate(sys: String(sys), dia: String(dia), pulse: pulse.map(String.init) ?? "").values != nil
    }
}

enum Field: Hashable { case sys, dia, pulse, gap }

enum Issue: Hashable {
    // errors: the reading can't be saved
    case missing, notANumber, below(Int), above(Int), sysNotAboveDia
    // warnings: possible, but worth a second look
    case unusuallyLow, unusuallyHigh, unusualGap

    var isError: Bool {
        switch self {
        case .missing, .notANumber, .below, .above, .sysNotAboveDia: true
        case .unusuallyLow, .unusuallyHigh, .unusualGap: false
        }
    }
}

struct Validation {
    /// At most one issue per field; an error always wins over a warning.
    var issues: [Field: Issue] = [:]
    /// The values to save, or nil while any field has an error.
    var values: (sys: Int, dia: Int, pulse: Int?)?
}

enum Parsed: Equatable { case empty, number(Int), invalid }

/// Whole-input parse of a typed value: digits only (any script's decimal digits), surrounding spaces ignored.
/// Nothing is trimmed or corrected, so "1200" stays 1200 and "-120" or "1.5" is invalid.
func parse(_ text: String) -> Parsed {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return .empty }
    // decimal digits only: a Roman numeral or a fraction also has a numeric value
    guard trimmed.allSatisfy({ $0.unicodeScalars.count == 1 && $0.unicodeScalars.first!.properties.numericType == .decimal }) else { return .invalid }
    let digits = trimmed.drop { $0.wholeNumberValue == 0 }
    if digits.count > 6 { return .number(.max) }   // far above any limit; avoids Int overflow on a long paste
    return .number(digits.reduce(0) { $0 * 10 + $1.wholeNumberValue! })
}

/// Checks the three form fields. SYS and DIA are required, pulse is optional (empty is fine, text that isn't a number is not).
func validate(sys sysText: String, dia diaText: String, pulse pulseText: String) -> Validation {
    var result = Validation()
    func check(_ text: String, _ field: Field, required: Bool, hard: ClosedRange<Int>, usual: ClosedRange<Int>) -> Int? {
        switch parse(text) {
        case .empty: if required { result.issues[field] = .missing }; return nil
        case .invalid: result.issues[field] = .notANumber; return nil
        case .number(let n):
            if n < hard.lowerBound { result.issues[field] = .below(hard.lowerBound); return nil }
            if n > hard.upperBound { result.issues[field] = .above(hard.upperBound); return nil }
            if n < usual.lowerBound { result.issues[field] = .unusuallyLow }
            if n > usual.upperBound { result.issues[field] = .unusuallyHigh }
            return n
        }
    }
    let sys = check(sysText, .sys, required: true, hard: Limits.sys, usual: Limits.usualSys)
    let dia = check(diaText, .dia, required: true, hard: Limits.dia, usual: Limits.usualDia)
    let pulse = check(pulseText, .pulse, required: false, hard: Limits.pulse, usual: Limits.usualPulse)
    if let sys, let dia {   // both in range, so the subtraction can't overflow
        if sys <= dia { result.issues[.gap] = .sysNotAboveDia }
        else if !Limits.usualGap.contains(sys - dia) { result.issues[.gap] = .unusualGap }
    }
    if let sys, let dia, !result.issues.values.contains(where: \.isError) {
        result.values = (sys, dia, pulse)
    }
    return result
}

/// Reads SYS / DIA / PUL from a photo of a home blood pressure monitor's LCD.
/// Vision's text recognizer can't read the 7-segment digits, so it is only used to locate the
/// printed SYS / DIA / PUL(SE) labels; the digits beside each label are decoded by sampling their segments.
func readDisplay(_ image: CGImage) async throws -> Reading {
    var labels = try await findLabels(in: image)
    if labels["DIA"] == nil, let s = labels["SYS"], let p = labels["PUL"] {    // Vision sometimes misses one: DIA sits halfway
        labels["DIA"] = s.offsetBy(dx: 0, dy: (p.midY - s.midY) / 2)
    }
    guard let sys = labels["SYS"], let dia = labels["DIA"], dia.midY > sys.midY else { return Reading() }
    let rows = [("SYS", sys), ("DIA", dia), ("PUL", labels["PUL"])].compactMap { k, r in r.map { (k, $0) } }
    let pitch = dia.midY - sys.midY            // row spacing: every other size on the display scales with it
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let top = sys.midY - 1.1 * pitch, bottom = rows.last!.1.midY + 1.1 * pitch

    // Digits sit left of the labels on B.Well, Microlife, Sanitas and right of them on Omron: read both sides, keep the plausible one.
    func read(leftOfLabels: Bool, stripFrame: Bool) -> Reading {
        let edge = leftOfLabels ? rows.map(\.1.maxX).max()! : rows.map(\.1.minX).min()!   // labels are staggered; each row is trimmed to its own below
        let width = 3.2 * pitch
        let roi = CGRect(x: leftOfLabels ? edge - width : edge, y: top, width: width, height: bottom - top).intersection(bounds)
        guard !roi.isEmpty else { return Reading() }
        // The threshold window also sets how far the dark LCD bezel bleeds inward; wider welds tall digits to it (Omron M2 Plus).
        let bitmap = Bitmap(image, roi: roi, scale: min(3, 150 / pitch), window: Int(0.25 * pitch), maxDigit: Int(1.3 * pitch), stripFrame: stripFrame, erasing: rows.map(\.1))   // ~150 px per row: enough detail, JPEG speckle averaged away
        let s = bitmap.scale, rx = max(1, Int(0.01 * pitch * s)), ry = Int(0.035 * pitch * s)   // vertical: joins a digit's segments, not neighbours
        // Rows of digits nearly touch on some displays, so each row is read on its own band of the crop: cut between
        // neighbouring rows, and above the first / below the last (date, captions), at the emptiest scanline nearest
        // the midpoint of the labels / the label. Ink is summed over a few scanlines, so a cut can't land in the
        // hairline gap splitting a 7 or an 11 in half.
        let ys = rows.map { ($0.1.midY - roi.minY) * s }, unit = pitch * s
        let k = Int(0.04 * unit), raw = (0..<bitmap.height).map(bitmap.dark(row:))
        let ink = raw.indices.map { raw[max(0, $0 - k)...min(raw.count - 1, $0 + k)].reduce(0, +) }
        func cut(_ range: ClosedRange<CGFloat>, near y: CGFloat) -> Int {
            let lo = max(0, Int(range.lowerBound)), hi = min(ink.count - 1, Int(range.upperBound))
            return lo < hi ? (lo...hi).min { (ink[$0], abs(CGFloat($0) - y)) < (ink[$1], abs(CGFloat($1) - y)) }! : lo
        }
        var cuts = [cut(ys[0] - 1.1 * unit ... ys[0] - 0.35 * unit, near: ys[0])]
        for (a, b) in zip(ys, ys.dropFirst()) { cuts.append(max(cuts.last!, cut((a + b) / 2 - 0.3 * (b - a) ... (a + b) / 2 + 0.3 * (b - a), near: (a + b) / 2))) }
        cuts.append(cut(ys.last! + 0.2 * unit ... ys.last! + 1.1 * unit, near: ys.last!) + 1)
        var values: [String: Int] = [:], heights: [String: CGFloat] = [:]
        for (i, (key, label)) in rows.enumerated() where cuts[i] < cuts[i + 1] {
            // Trim to this row's own label, so the frame beside it is cut and erased.
            let x = Int(((leftOfLabels ? label.minX : label.maxX) - roi.minX) * s)
            let band = bitmap.band(cuts[i]..<cuts[i + 1], leftOfLabels ? 0..<max(1, x) : min(x, bitmap.width - 1)..<bitmap.width)
            let blobs = band.blobs(dilatedBy: rx, ry).filter { $0.height > 0.3 * pitch * s && $0.width > 0.11 * pitch * s && $0.width < 1.1 * $0.height }
            // Every value has at least two digits of one height; a lone taller blob is an icon.
            let paired = blobs.filter { b in blobs.contains { $0 != b && abs($0.height - b.height) < 0.15 * b.height } }
            guard let tallest = paired.map(\.height).max() else { continue }
            let row = blobs.filter { $0.height > 0.7 * tallest && $0.height < 1.15 * tallest }.sorted { leftOfLabels ? $0.maxX > $1.maxX : $0.minX < $1.minX }
            // The number is the run of digits nearest the label; a wide gap ends it (icons, bar graphs beyond).
            // A 1 sits at the right of its digit cell, so measure gaps between whole cells.
            let cell = max(row.map(\.width).max() ?? 0, 0.5 * tallest)
            var run = Array(row.prefix(1))
            // Digit cells don't overlap: a blob less than a cell past the last digit is something else (a bar graph segment).
            for b in row.dropFirst() {
                let step = leftOfLabels ? run.last!.maxX - b.maxX : b.maxX - run.last!.maxX
                if step > 0.8 * cell && step - cell < 0.5 * tallest { run.append(b) }
            }
            let digits = run.sorted { $0.minX < $1.minX }.map { band.digit(in: $0.insetBy(dx: CGFloat(rx), dy: CGFloat(ry))) }
            guard (1...3).contains(digits.count), digits.allSatisfy({ $0 != nil }), let n = Int(digits.map { String($0!) }.joined()) else { continue }
            values[key] = n; heights[key] = tallest
        }
        // SYS and DIA are printed the same size; a mismatch means one row is fragments of digits (half of each, split by a frame cut).
        if let hs = heights["SYS"], let hd = heights["DIA"], abs(hs - hd) > 0.2 * max(hs, hd) { return Reading() }
        return Reading(sys: values["SYS"], dia: values["DIA"], pulse: values["PUL"])
    }
    func plausible(_ r: Reading) -> Int {
        guard let s = r.sys, let d = r.dia, (60...260).contains(s), (30...160).contains(d), s > d else { return 0 }
        return (r.pulse.map { (30...200).contains($0) } ?? false) ? 2 : 1
    }
    // Digits touching the LCD frame get erased with it unless the frame is stripped first, but stripping leaves
    // frame corners that can pass for digits elsewhere: try both, keep the first most plausible reading.
    let readings = [(true, false), (false, false), (true, true), (false, true)].lazy.map { read(leftOfLabels: $0, stripFrame: $1) }
    var best = Reading()
    for r in readings where plausible(r) > plausible(best) { best = r; if plausible(r) == 2 { break } }
    return best
}

/// Label boxes in pixel coordinates, top-left origin.
private func findLabels(in image: CGImage) async throws -> [String: CGRect] {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let w = CGFloat(image.width), h = CGFloat(image.height)
    var found: [String: CGRect] = [:]
    for observation in try await request.perform(on: image) {
        guard let candidate = observation.topCandidates(1).first else { continue }
        for key in ["SYS", "DIA", "PUL"] where found[key] == nil {
            // Box just the label: Vision often merges it with neighbours ("SYS —", "PULSE/min").
            guard let range = candidate.string.range(of: key, options: .caseInsensitive),
                  let b = candidate.boundingBox(for: range)?.boundingBox.cgRect else { continue }
            found[key] = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
        }
    }
    return found
}

/// Thresholded crop of the image: 1 = dark (lit segment), 0 = background.
/// The threshold is local (mean of a `window`-sized neighbourhood) so a crop spanning plastic, LCD and glare still separates segments.
private struct Bitmap {
    private(set) var width: Int, height: Int
    let scale: CGFloat
    private let maxDigit: Int
    private(set) var bits: [UInt8]

    init(_ image: CGImage, roi: CGRect, scale s: CGFloat, window: Int, maxDigit: Int, stripFrame: Bool, erasing: [CGRect]) {
        let w = Int(roi.width * s), h = Int(roi.height * s)
        var gray = [UInt8](repeating: 0, count: w * h)
        gray.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image.cropping(to: roi)!, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        scale = s; width = w; height = h; self.maxDigit = Int(CGFloat(maxDigit) * s)
        let r = max(2, Int(CGFloat(window) * s))
        var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h { var row = 0; for x in 0..<w { row += Int(gray[y * w + x]); integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row } }
        bits = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                let sum = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                // ponytail: fixed 15 % contrast margin; make it adaptive if faint LCDs drop segments
                if Int(gray[y * w + x]) * 100 * (x1 - x0) * (y1 - y0) < sum * 85 { bits[y * w + x] = 1 }
            }
        }
        if stripFrame { eraseLongRuns(self.maxDigit) }
        clearNonDigits()
        for r in erasing {   // the labels: a glyph stacked on "/min" can pass for a 1
            let box = r.offsetBy(dx: -roi.minX, dy: -roi.minY).applying(CGAffineTransform(scaleX: s, y: s)).intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard !box.isNull, !box.isEmpty else { continue }
            for y in Int(box.minY)..<Int(box.maxY) { for x in Int(box.minX)..<Int(box.maxX) { bits[y * w + x] = 0 } }
        }
    }

    /// The LCD frame and shadow edges are straight runs longer than any digit; digits often touch them,
    /// so cut those runs away first or the digits get erased along with the frame.
    private mutating func eraseLongRuns(_ limit: Int) {
        var erase = [Bool](repeating: false, count: bits.count)
        for (lines, length, step, lineStep) in [(height, width, 1, width), (width, height, width, 1)] {
            for line in 0..<lines {
                var start = 0
                for i in 0...length {
                    let dark = i < length && bits[line * lineStep + i * step] == 1
                    if dark { continue }
                    if i - start > limit { for j in start..<i { erase[line * lineStep + j * step] = true } }
                    start = i + 1
                }
            }
        }
        var mask = self
        mask.bits = erase.map { $0 ? 1 : 0 }
        let halo = max(1, limit / 60)   // the frame's ragged edge, so no sliver stays welded to a digit
        for (i, e) in mask.dilated(halo, halo).bits.enumerated() where e == 1 { bits[i] = 0 }
    }

    /// The sub-rectangle `ys` × `xs` alone, with whatever the cut sliced through erased.
    func band(_ ys: Range<Int>, _ xs: Range<Int>) -> Bitmap {
        var b = self
        b.height = ys.count; b.width = xs.count
        b.bits = ys.flatMap { y in bits[y * width + xs.lowerBound ..< y * width + xs.upperBound] }
        b.clearNonDigits()
        return b
    }

    func dark(row y: Int) -> Int { bits[y * width ..< (y + 1) * width].reduce(0) { $0 + Int($1) } }

    /// Anything cut off by the crop boundary (a neighbouring digit row, a label) or bigger than a digit (the LCD frame,
    /// a shadow) is not a digit: erase it before dilation so it can't weld onto the digits.
    private mutating func clearNonDigits() {
        var seen = [Bool](repeating: false, count: bits.count), component: [Int] = []
        for start in 0..<bits.count where bits[start] == 1 && !seen[start] {
            var minX = width, maxX = 0, minY = height, maxY = 0
            component = [start]; seen[start] = true
            var next = 0
            while next < component.count {
                let i = component[next], x = i % width, y = i / width; next += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for n in [i - 1, i + 1, i - width, i + width] where n >= 0 && n < bits.count && bits[n] == 1 && !seen[n] && abs(n % width - x) <= 1 {
                    seen[n] = true; component.append(n)
                }
            }
            if minX == 0 || minY == 0 || maxX == width - 1 || maxY == height - 1 || maxX - minX > maxDigit || maxY - minY > maxDigit {
                for i in component { bits[i] = 0 }
            }
        }
    }

    /// Box dilation by `rx` × `ry`: separable, via prefix sums, O(pixels) regardless of radius.
    func dilated(_ rx: Int, _ ry: Int) -> Bitmap {
        func dilate(_ src: [UInt8], radius: Int, stride: Int, length: Int, lines: Int, lineStride: Int) -> [UInt8] {
            var out = src
            var prefix = [Int](repeating: 0, count: length + 1)
            for line in 0..<lines {
                let base = line * lineStride
                for i in 0..<length { prefix[i + 1] = prefix[i] + Int(src[base + i * stride]) }
                for i in 0..<length where prefix[min(length, i + radius + 1)] - prefix[max(0, i - radius)] > 0 { out[base + i * stride] = 1 }
            }
            return out
        }
        var d = dilate(bits, radius: rx, stride: 1, length: width, lines: height, lineStride: width)   // rows
        d = dilate(d, radius: ry, stride: width, length: height, lines: width, lineStride: 1)          // columns
        var b = self
        b.bits = d
        return b
    }

    /// Bounding boxes of connected dark regions after a box dilation of `rx` × `ry`.
    func blobs(dilatedBy rx: Int, _ ry: Int) -> [CGRect] {
        var d = dilated(rx, ry).bits
        var rects: [CGRect] = []
        var stack: [Int] = []
        for start in 0..<d.count where d[start] == 1 {
            var minX = width, maxX = 0, minY = height, maxY = 0
            stack.append(start); d[start] = 2
            while let i = stack.popLast() {
                let x = i % width, y = i / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for n in [i - 1, i + 1, i - width, i + width] where n >= 0 && n < d.count && d[n] == 1 && abs(n % width - x) <= 1 {
                    d[n] = 2; stack.append(n)
                }
            }
            rects.append(CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        }
        return rects
    }

    /// Fraction of dark pixels in a sub-rectangle of `box` (fractions of its width/height).
    func lit(_ box: CGRect, _ x0: CGFloat, _ x1: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> Bool {
        let ys = max(0, Int(box.minY + y0 * box.height)), ye = min(height, Int(box.minY + y1 * box.height))
        let xs = max(0, Int(box.minX + x0 * box.width)), xe = min(width, Int(box.minX + x1 * box.width))
        guard ys < ye, xs < xe else { return false }
        var dark = 0
        for y in ys..<ye { for x in xs..<xe { dark += Int(bits[y * width + x]) } }
        return Double(dark) / Double((ye - ys) * (xe - xs)) > 0.25
    }

    /// Decode one 7-segment digit inside `box`. Regions are generous to tolerate the italic slant.
    func digit(in box: CGRect) -> Int? {
        if box.width < 0.4 * box.height { return 1 }
        let pattern = [
            lit(box, 0.3, 0.7, 0.0, 0.18),   // a top
            lit(box, 0.65, 1.0, 0.15, 0.42), // b top-right
            lit(box, 0.65, 1.0, 0.58, 0.85), // c bottom-right
            lit(box, 0.3, 0.7, 0.82, 1.0),   // d bottom
            lit(box, 0.0, 0.35, 0.58, 0.85), // e bottom-left
            lit(box, 0.0, 0.35, 0.15, 0.42), // f top-left
            lit(box, 0.3, 0.7, 0.41, 0.59),  // g middle
        ]
        let table: [[Bool]: Int] = [
            [true, true, true, true, true, true, false]: 0,
            [true, true, false, true, true, false, true]: 2,
            [true, true, true, true, false, false, true]: 3,
            [false, true, true, false, false, true, true]: 4,
            [true, false, true, true, false, true, true]: 5,
            [true, false, true, true, true, true, true]: 6,
            [true, true, true, false, false, false, false]: 7,
            [true, true, true, false, false, true, false]: 7,
            [true, true, true, true, true, true, true]: 8,
            [true, true, true, true, false, true, true]: 9,
        ]
        if let exact = table[pattern] { return exact }
        // ponytail: accept one misread segment; tighten if it starts confusing digits
        let near = table.filter { zip($0.key, pattern).filter { $0 != $1 }.count == 1 }
        return near.count == 1 ? near.first!.value : nil
    }
}
