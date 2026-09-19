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

/// Reads SYS / DIA / PUL from a photo of the B.Well MED-55.
/// Vision's text recognizer can't read the 7-segment digits, so it is only used to locate the
/// printed labels; the digits left of each label are decoded by sampling their segments.
func readDisplay(_ image: CGImage) async throws -> Reading {
    let labels = try await findLabels(in: image)
    guard let sys = labels["SYS"], let dia = labels["DIA"] else { return Reading() }
    let anchors = [sys, dia, labels["PUL"]].compactMap { $0 }
    let h = anchors.map(\.height).reduce(0, +) / CGFloat(anchors.count)
    let right = anchors.map(\.minX).min()! - 0.3 * h
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)

    // Digits sit left of the label. Their window (in label heights: top/bottom from the label's centre, left from
    // the digits' right edge) differs per row: the device prints SYS beside the middle of its digits, DIA and PUL
    // nearer the top, the rows are only ~0.4 h apart, and the smaller PUL digits stop short of the date text.
    let window: [String: (top: CGFloat, bottom: CGFloat, left: CGFloat)] = ["SYS": (-3.0, 3.8, 11), "DIA": (-2.4, 4.2, 11), "PUL": (-1.8, 3.0, 9)]
    func value(_ key: String) -> Int? {
        guard let label = labels[key] else { return nil }
        let (top, bottom, left) = window[key]!
        let roi = CGRect(x: right - left * h, y: label.midY + top * h, width: left * h, height: (bottom - top) * h).intersection(bounds)
        let bitmap = Bitmap(image, roi: roi, maxSide: 800)
        let radius = Int(0.25 * h * bitmap.scale)   // closes the gaps between segments of one digit
        let blobs = bitmap.blobs(dilatedBy: radius)
            .filter { $0.height >= 2 * h * bitmap.scale && $0.minX > 0 && $0.maxX < CGFloat(bitmap.width) } // whole digits only
        let digits = blobs.sorted { $0.minX < $1.minX }.map { bitmap.digit(in: $0.insetBy(dx: CGFloat(radius), dy: CGFloat(radius))) }
        guard !digits.isEmpty, digits.allSatisfy({ $0 != nil }), let n = Int(digits.map { String($0!) }.joined()) else { return nil }
        return (30...300).contains(n) ? n : nil
    }
    return Reading(sys: value("SYS"), dia: value("DIA"), pulse: value("PUL"))
}

/// Label boxes in pixel coordinates, top-left origin.
private func findLabels(in image: CGImage) async throws -> [String: CGRect] {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let w = CGFloat(image.width), h = CGFloat(image.height)
    var found: [String: CGRect] = [:]
    for observation in try await request.perform(on: image) {
        guard let text = observation.topCandidates(1).first?.string.uppercased() else { continue }
        for key in ["SYS", "DIA", "PUL"] where text.contains(key) && found[key] == nil {
            let b = observation.boundingBox.cgRect
            found[key] = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
        }
    }
    return found
}

/// Thresholded crop of the image: 1 = dark (lit segment), 0 = background.
private struct Bitmap {
    let width: Int, height: Int
    let scale: CGFloat
    private(set) var bits: [UInt8]

    init(_ image: CGImage, roi: CGRect, maxSide: Int) {
        let s = min(1, CGFloat(maxSide) / max(roi.width, roi.height))
        let w = Int(roi.width * s), h = Int(roi.height * s)
        var gray = [UInt8](repeating: 0, count: w * h)
        gray.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image.cropping(to: roi)!, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        scale = s; width = w; height = h
        let t = Bitmap.otsu(gray)
        bits = gray.map { $0 < t ? 1 : 0 }
        clearEdgeTouching()
    }

    /// Anything cut off by the crop boundary (a neighbouring digit row, the LCD edge, a label) is not a digit:
    /// erase it before dilation so it can't weld onto the digits.
    private mutating func clearEdgeTouching() {
        var stack: [Int] = []
        for x in 0..<width { stack += [x, (height - 1) * width + x] }          // top and bottom rows
        for y in 0..<height { stack += [y * width, y * width + width - 1] }    // left and right columns
        while let i = stack.popLast() {
            guard bits[i] == 1 else { continue }
            bits[i] = 0
            let x = i % width
            for n in [i - 1, i + 1, i - width, i + width] where n >= 0 && n < bits.count && bits[n] == 1 && abs(n % width - x) <= 1 { stack.append(n) }
        }
    }

    private static func otsu(_ pixels: [UInt8]) -> UInt8 {
        var hist = [Int](repeating: 0, count: 256)
        for p in pixels { hist[Int(p)] += 1 }
        let total = pixels.count
        let sumAll = hist.enumerated().reduce(0) { $0 + $1.offset * $1.element }
        var sumB = 0, wB = 0, best = 0.0, threshold = 0
        for t in 0..<256 {
            wB += hist[t]; guard wB > 0 else { continue }
            let wF = total - wB; guard wF > 0 else { break }
            sumB += t * hist[t]
            let mB = Double(sumB) / Double(wB), mF = Double(sumAll - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = t }
        }
        return UInt8(threshold)
    }

    /// Bounding boxes of connected dark regions after a square dilation of `radius`.
    func blobs(dilatedBy radius: Int) -> [CGRect] {
        var d = bits
        for y in 0..<height { for x in 0..<width where bits[y * width + x] == 1 {
            for dy in max(0, y - radius)...min(height - 1, y + radius) { for dx in max(0, x - radius)...min(width - 1, x + radius) { d[dy * width + dx] = 1 } }
        } }
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
