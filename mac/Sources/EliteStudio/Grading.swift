import Foundation
import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

// Automatic colour grading. Same JSON (`effects.grade`) and same maths as Windows/grading.py:
// per-clip analysis (levels, white balance, exposure, flat-profile detection) + a creative look,
// baked into one 33³ 3D LUT used by the Metal compositor (preview and export alike).

struct GradeAuto: Hashable, Codable {
    var black = 0.0, white = 1.0, gamma = 1.0
    var wb: [Double] = [1, 1, 1]
    var flat = false
    var median: Double? = nil
    enum K: String, CodingKey { case black, white, gamma, wb, flat, median }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        black = c.get(.black, 0); white = c.get(.white, 1); gamma = c.get(.gamma, 1)
        wb = c.get(.wb, [1.0, 1.0, 1.0]); flat = c.get(.flat, false); median = try? c.decodeIfPresent(Double.self, forKey: .median)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(black, forKey: .black); try c.encode(white, forKey: .white); try c.encode(gamma, forKey: .gamma)
        try c.encode(wb, forKey: .wb); try c.encode(flat, forKey: .flat); try c.encodeIfPresent(median, forKey: .median)
    }
}

struct Grade: Hashable, Codable {
    var look = Grading.defaultLook
    var amount = 1.0
    var correct = true
    var match = true
    var auto = GradeAuto()
    var wheels = GradeWheels()
    var basic = GradeBasic()
    enum K: String, CodingKey { case look, amount, correct, match, auto, wheels, basic }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        look = c.get(.look, Grading.defaultLook); amount = c.get(.amount, 1); correct = c.get(.correct, true)
        match = c.get(.match, true); auto = c.get(.auto, GradeAuto())
        wheels = c.get(.wheels, GradeWheels()); basic = c.get(.basic, GradeBasic())
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(look, forKey: .look); try c.encode(amount, forKey: .amount); try c.encode(correct, forKey: .correct)
        try c.encode(match, forKey: .match); try c.encode(auto, forKey: .auto)
        try c.encode(wheels, forKey: .wheels); try c.encode(basic, forKey: .basic)
    }

    /// Mirrors grading.normalized(): clamped values, unknown look -> default.
    var normalized: Grade {
        var g = self
        func num(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double { v.isFinite ? min(hi, max(lo, v)) : fallback }
        if Grading.looks[g.look] == nil && g.look != "none" { g.look = Grading.defaultLook }
        g.amount = num(g.amount, 0, 1.5, 1)
        g.auto.black = num(auto.black, 0, 0.4, 0); g.auto.white = num(auto.white, 0.5, 1.1, 1); g.auto.gamma = num(auto.gamma, 0.5, 2, 1)
        g.auto.wb = auto.wb.count == 3 ? auto.wb.map { num($0, 0.8, 1.25, 1) } : [1, 1, 1]
        g.auto.median = nil; g.match = false          // not part of the picture
        g.wheels.lift = g.wheels.lift.count == 3 ? g.wheels.lift.map { num($0, -0.25, 0.25, 0) } : [0, 0, 0]
        g.wheels.gamma = g.wheels.gamma.count == 3 ? g.wheels.gamma.map { num($0, -0.25, 0.25, 0) } : [0, 0, 0]
        g.wheels.gain = g.wheels.gain.count == 3 ? g.wheels.gain.map { num($0, -0.25, 0.25, 0) } : [0, 0, 0]
        g.wheels.offset = g.wheels.offset.count == 3 ? g.wheels.offset.map { num($0, -0.25, 0.25, 0) } : [0, 0, 0]
        g.basic.temperature = num(g.basic.temperature, -1, 1, 0); g.basic.tint = num(g.basic.tint, -1, 1, 0)
        g.basic.exposure = num(g.basic.exposure, -5, 5, 0); g.basic.contrast = num(g.basic.contrast, 0, 2, 1)
        g.basic.pivot = num(g.basic.pivot, 0.05, 0.95, 0.5); g.basic.highlights = num(g.basic.highlights, -1, 1, 0)
        g.basic.shadows = num(g.basic.shadows, -1, 1, 0); g.basic.whites = num(g.basic.whites, -1, 1, 0)
        g.basic.blacks = num(g.basic.blacks, -1, 1, 0); g.basic.saturation = num(g.basic.saturation, 0, 2, 1)
        g.basic.vibrance = num(g.basic.vibrance, -1, 1, 0)
        return g
    }
}

struct GradeWheels: Hashable, Codable {
    var lift: [Double] = [0, 0, 0]
    var gamma: [Double] = [0, 0, 0]
    var gain: [Double] = [0, 0, 0]
    var offset: [Double] = [0, 0, 0]
}

struct GradeBasic: Hashable, Codable {
    var temperature = 0.0, tint = 0.0, exposure = 0.0, contrast = 1.0, pivot = 0.5
    var highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0, saturation = 1.0, vibrance = 0.0
}

struct Look {
    var name: String
    var contrast: Double, pivot: Double, sat: Double, vibrance: Double, warmth: Double, lift: Double
    var shadows: SIMD3<Double>, highlights: SIMD3<Double>
    var bands: [[Double]]                // centre°, width°, hue shift°, sat ×, value ×
}

enum Grading {
    static let size = 33
    static let luma = SIMD3<Double>(0.2126, 0.7152, 0.0722)
    static let defaultLook = "natural"
    static let order = ["natural", "alpine", "golden", "moody", "vivid", "film", "bw", "none"]
    static let looks: [String: Look] = [
        "natural": Look(name: "Naturale cinematico", contrast: 1.10, pivot: 0.45, sat: 1.0, vibrance: 0.10, warmth: 0.03, lift: 0.008,
                        shadows: [-0.008, 0.002, 0.010], highlights: [0.010, 0.004, -0.008],
                        bands: [[35, 32, 0, 1.04, 1.0], [212, 40, 2, 1.06, 0.97]]),
        "alpine": Look(name: "Alpino cinematico", contrast: 1.24, pivot: 0.43, sat: 1.04, vibrance: 0.18, warmth: 0.06, lift: 0.012,
                       shadows: [-0.018, 0.004, 0.022], highlights: [0.020, 0.008, -0.018],
                       bands: [[35, 32, -2, 1.12, 1.02], [95, 45, -12, 0.90, 0.96], [212, 40, 4, 1.10, 0.92]]),
        "golden": Look(name: "Golden hour", contrast: 1.22, pivot: 0.45, sat: 1.10, vibrance: 0.25, warmth: 0.38, lift: 0.02,
                       shadows: [0.010, -0.004, -0.014], highlights: [0.045, 0.018, -0.040],
                       bands: [[35, 35, -2, 1.30, 1.06], [100, 45, -28, 0.80, 0.96], [215, 40, 0, 0.95, 0.96]]),
        "moody": Look(name: "Moody nordico", contrast: 1.30, pivot: 0.45, sat: 0.72, vibrance: 0, warmth: -0.22, lift: 0.045,
                      shadows: [-0.022, 0.004, 0.028], highlights: [-0.006, 0.004, 0.010],
                      bands: [[35, 35, 6, 0.70, 0.95], [100, 50, 18, 0.55, 0.90], [210, 45, 4, 1.10, 0.82]]),
        "vivid": Look(name: "Naturale vivido", contrast: 1.18, pivot: 0.45, sat: 1.18, vibrance: 0.40, warmth: 0.04, lift: 0,
                      shadows: [0, 0, 0], highlights: [0, 0, 0], bands: [[215, 40, 0, 1.15, 0.94]]),
        "film": Look(name: "Pellicola vintage", contrast: 1.16, pivot: 0.45, sat: 0.86, vibrance: 0.10, warmth: 0.18, lift: 0.07,
                     shadows: [-0.010, 0.022, 0.012], highlights: [0.030, 0.016, -0.026],
                     bands: [[35, 35, 4, 1.10, 1.0], [100, 45, 14, 0.80, 0.95], [210, 45, -10, 0.80, 0.95]]),
        "bw": Look(name: "Bianco e nero drammatico", contrast: 1.50, pivot: 0.42, sat: 0, vibrance: 0, warmth: 0, lift: 0.01,
                   shadows: [0, 0, 0], highlights: [0, 0, 0], bands: [[215, 50, 0, 1.0, 0.60], [35, 40, 0, 1.0, 1.12]]),
    ]
    static func name(_ look: String) -> String { look == "none" ? "Solo correzione" : looks[look]?.name ?? look }

    // MARK: maths (keep in step with grading.py)

    private static func clamp01(_ v: SIMD3<Double>) -> SIMD3<Double> { simd_clamp(v, SIMD3(repeating: 0), SIMD3(repeating: 1)) }
    private static func fmod360(_ x: Double) -> Double { x - 360 * (x / 360).rounded(.down) }
    private static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
    }
    private static func curve(_ v: SIMD3<Double>, _ a: Double, _ p: Double) -> SIMD3<Double> {
        func one(_ x0: Double) -> Double {
            let x = min(1, max(0, x0))
            return x < p ? p * pow(max(0, x / p), a) : 1 - (1 - p) * pow(max(0, (1 - x) / (1 - p)), a)
        }
        return SIMD3(one(v.x), one(v.y), one(v.z))
    }
    private static func saturate(_ v: SIMD3<Double>, _ f: Double) -> SIMD3<Double> {
        let l = simd_dot(v, luma); return SIMD3(repeating: l) + (v - SIMD3(repeating: l)) * f
    }
    private static func hsv(_ c: SIMD3<Double>) -> (Double, Double, Double) {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z), d = mx - mn
        var h = 0.0
        if d > 1e-9 {
            if mx == c.x { let q = (c.y - c.z) / d; h = q - 6 * (q / 6).rounded(.down) }
            else if mx == c.y { h = (c.z - c.x) / d + 2 }
            else { h = (c.x - c.y) / d + 4 }
            h *= 60
        }
        return (h, mx > 1e-9 ? d / mx : 0, mx)
    }
    private static func rgb(_ h0: Double, _ s: Double, _ v: Double) -> SIMD3<Double> {
        let h = fmod360(h0) / 60, c = v * s
        let hm2 = h - 2 * (h / 2).rounded(.down)
        let x = c * (1 - abs(hm2 - 1)), m = v - c
        var i = Int(h.rounded(.down)) % 6; if i < 0 { i += 6 }
        let t: SIMD3<Double>
        switch i {
        case 0: t = [c, x, 0]
        case 1: t = [x, c, 0]
        case 2: t = [0, c, x]
        case 3: t = [0, x, c]
        case 4: t = [x, 0, c]
        default: t = [c, 0, x]
        }
        return t + SIMD3(repeating: m)
    }

    static func correct(_ input: SIMD3<Double>, _ a: GradeAuto) -> SIMD3<Double> {
        var v = (input - SIMD3(repeating: a.black)) / max(0.05, a.white - a.black)
        v = clamp01(v * SIMD3(a.wb[0], a.wb[1], a.wb[2]))
        v = SIMD3(pow(v.x, a.gamma), pow(v.y, a.gamma), pow(v.z, a.gamma))
        if a.flat { v = saturate(curve(v, 1.18, 0.45), 1.22) }
        return clamp01(v)
    }

    static func look(_ input: SIMD3<Double>, _ L: Look) -> SIMD3<Double> {
        let w = L.warmth
        var v = input * SIMD3(1 + 0.10 * w, 1 + 0.01 * w, 1 - 0.10 * w)
        v = curve(v, L.contrast, L.pivot)
        if !L.bands.isEmpty {
            var (h, s, val) = hsv(clamp01(v))
            let chroma = smooth(0.04, 0.22, s)
            for b in L.bands {
                let d = abs(fmod360(h - b[0] + 180) - 180)
                let k = smooth(0, 1, 1 - d / b[1]) * chroma
                h += b[2] * k; s *= 1 + (b[3] - 1) * k; val *= 1 + (b[4] - 1) * k
            }
            v = rgb(h, min(1, max(0, s)), min(1, max(0, val)))
        }
        let l = simd_dot(v, luma)
        let sh = L.shadows - SIMD3(repeating: simd_dot(L.shadows, luma))
        let hi = L.highlights - SIMD3(repeating: simd_dot(L.highlights, luma))
        v += (1 - l) * (1 - l) * sh + l * l * hi
        let chroma = max(v.x, v.y, v.z) - min(v.x, v.y, v.z)
        v = saturate(v, L.sat * (1 + L.vibrance * min(1, max(0, 1 - chroma * 2.5))))
        v = SIMD3(repeating: L.lift) + (1 - L.lift) * v
        return clamp01(v)
    }

    static func apply(_ c: SIMD3<Double>, _ g: Grade) -> SIMD3<Double> {
        var base = g.correct ? correct(c, g.auto) : clamp01(c)
        let b = g.basic
        if b != GradeBasic() || g.wheels != GradeWheels() {
            base *= pow(2, b.exposure)
            base = (base - SIMD3(repeating: b.pivot)) * b.contrast + SIMD3(repeating: b.pivot)
            let lum = simd_dot(base, luma)
            base += SIMD3(repeating: b.shadows * pow(1 - min(1, max(0, lum)), 2) + b.highlights * pow(min(1, max(0, lum)), 2))
            base += SIMD3(repeating: b.blacks * (1 - min(1, max(0, lum * 4))) + b.whites * min(1, max(0, (lum - 0.75) * 4)))
            base *= SIMD3(1 + 0.12 * b.temperature, 1 + 0.08 * b.tint, 1 - 0.12 * b.temperature)
            let chroma = max(base.x, base.y, base.z) - min(base.x, base.y, base.z)
            base = saturate(base, b.saturation * (1 + b.vibrance * min(1, max(0, 1 - chroma * 2.5))))
            let y = min(1, max(0, simd_dot(base, luma)))
            // Wheel offsets: x + lift + gamma*(1-Y) + gain*Y + offset; all vectors are RGB.
            base += SIMD3(g.wheels.lift[0], g.wheels.lift[1], g.wheels.lift[2])
            base += SIMD3(g.wheels.gamma[0], g.wheels.gamma[1], g.wheels.gamma[2]) * (1 - y)
            base += SIMD3(g.wheels.gain[0], g.wheels.gain[1], g.wheels.gain[2]) * y
            base += SIMD3(g.wheels.offset[0], g.wheels.offset[1], g.wheels.offset[2])
            base = clamp01(base)
        }
        guard g.look != "none", g.amount > 0, let L = looks[g.look] else { return base }
        return clamp01(base + (look(base, L) - base) * g.amount)
    }

    // MARK: LUT

    private static let lock = NSLock()
    private static var tables: [Grade: [SIMD3<Float>]] = [:]

    /// size³ entries, red fastest (same order as .cube).
    static func table(_ grade: Grade) -> [SIMD3<Float>] {
        let g = grade.normalized
        lock.lock(); if let t = tables[g] { lock.unlock(); return t }; lock.unlock()
        let n = size; var out = [SIMD3<Float>](); out.reserveCapacity(n * n * n)
        for b in 0..<n { for gg in 0..<n { for r in 0..<n {
            let v = apply(SIMD3(Double(r), Double(gg), Double(b)) / Double(n - 1), g)
            out.append(SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)))
        } } }
        lock.lock(); if tables.count > 32 { tables.removeAll() }; tables[g] = out; lock.unlock()
        return out
    }

    static func cubeText(_ grade: Grade) -> String {
        var s = "TITLE \"Elite Studio grade\"\nLUT_3D_SIZE \(size)\n"
        for v in table(grade) { s += String(format: "%.6f %.6f %.6f\n", v.x, v.y, v.z) }
        return s
    }

    /// CPU trilinear application, for the grading window's previews.
    static func render(_ image: CGImage, _ grade: Grade?) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let grade, let data = ctx.data else { return ctx.makeImage() }
        let t = table(grade), n = size, top = Float(n - 1)
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        DispatchQueue.concurrentPerform(iterations: h) { y in
            for x in 0..<w {
                let o = (y * w + x) * 4
                let p = SIMD3<Float>(Float(px[o]), Float(px[o + 1]), Float(px[o + 2])) / 255 * top
                let i0 = SIMD3<Int>(Int(p.x), Int(p.y), Int(p.z)), i1 = pointwiseMin(i0 &+ 1, SIMD3<Int>(repeating: n - 1))
                let f = p - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
                func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { t[(b * n + g) * n + r] }
                let c00 = simd_mix(at(i0.x, i0.y, i0.z), at(i1.x, i0.y, i0.z), SIMD3(repeating: f.x))
                let c10 = simd_mix(at(i0.x, i1.y, i0.z), at(i1.x, i1.y, i0.z), SIMD3(repeating: f.x))
                let c01 = simd_mix(at(i0.x, i0.y, i1.z), at(i1.x, i0.y, i1.z), SIMD3(repeating: f.x))
                let c11 = simd_mix(at(i0.x, i1.y, i1.z), at(i1.x, i1.y, i1.z), SIMD3(repeating: f.x))
                let c = simd_mix(simd_mix(c00, c10, SIMD3(repeating: f.y)), simd_mix(c01, c11, SIMD3(repeating: f.y)), SIMD3(repeating: f.z))
                px[o] = UInt8(min(255, max(0, c.x * 255 + 0.5))); px[o + 1] = UInt8(min(255, max(0, c.y * 255 + 0.5)))
                px[o + 2] = UInt8(min(255, max(0, c.z * 255 + 0.5)))
            }
        }
        return ctx.makeImage()
    }

    // MARK: analysis (keep in step with grading.stats / analyze / match)

    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let i = q / 100 * Double(sorted.count - 1), lo = Int(i.rounded(.down)), hi = min(sorted.count - 1, lo + 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (i - Double(lo))
    }
    private static func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }

    static func exposureGamma(_ median: Double, target: Double = 0.38, strength: Double = 0.6) -> Double {
        let g = log(target) / log(min(0.95, max(0.05, median)))
        return min(1.12, max(0.8, 1 + (g - 1) * strength))
    }

    static func stats(_ px: [SIMD3<Double>]) -> GradeAuto {
        let l = px.map { simd_dot($0, luma) }.sorted()
        var black = percentile(l, 0.4), white = percentile(l, 99.7)
        black = min(black, 0.25); white = max(white, black + 0.70)
        let span = white - black
        let n = px.map { clamp01(($0 - SIMD3(repeating: black)) / span) }
        let mid = n.filter { let v = simd_dot($0, luma); return v > 0.15 && v < 0.85 }
        let sel = mid.count > 100 ? mid : n
        let means = sel.reduce(SIMD3<Double>(repeating: 0), +) / Double(max(1, sel.count))
        let target = simd_dot(means, luma)
        var wb = simd_clamp(SIMD3(repeating: target) / simd_max(means, SIMD3(repeating: 1e-4)), SIMD3(repeating: 0.94), SIMD3(repeating: 1.06))
        wb = SIMD3(repeating: 1) + (wb - SIMD3(repeating: 1)) * 0.6
        wb /= simd_dot(wb, luma)
        let lum = n.map { simd_dot(clamp01($0 * wb), luma) }.sorted()
        let median = lum.isEmpty ? 0.5 : (lum.count % 2 == 1 ? lum[lum.count / 2] : (lum[lum.count / 2 - 1] + lum[lum.count / 2]) / 2)
        white = black + (white - black) / 0.97
        let sat = px.reduce(0.0) { $0 + (max($1.x, $1.y, $1.z) - min($1.x, $1.y, $1.z)) } / Double(max(1, px.count))
        var a = GradeAuto()
        a.black = r4(black); a.white = r4(white); a.gamma = r4(exposureGamma(median)); a.wb = [r4(wb.x), r4(wb.y), r4(wb.z)]
        a.flat = black > 0.035 && white < 0.93 && sat < 0.2; a.median = r4(median)
        return a
    }

    static func match(_ autos: [GradeAuto]) -> [GradeAuto] {
        let medians = autos.compactMap(\.median)
        guard medians.count >= 2 else { return autos }
        let target = min(0.45, max(0.30, medians.reduce(0, +) / Double(medians.count)))
        return autos.map { a in
            guard let m = a.median else { return a }
            var b = a; b.gamma = r4(exposureGamma(m, target: target, strength: 0.85)); return b
        }
    }

    /// DJI sidecar: [color_md : d_cinlike] marks the flat D-Cinelike profile.
    static func srtProfile(_ url: URL) -> String? {
        let base = url.deletingPathExtension()
        for ext in ["SRT", "srt"] {
            guard let h = FileHandle(forReadingAtPath: base.appendingPathExtension(ext).path) else { continue }
            defer { try? h.close() }
            let text = String(decoding: h.readData(ofLength: 4000), as: UTF8.self)
            guard let r = text.range(of: #"color_md\s*:\s*[\w-]+"#, options: .regularExpression) else { return nil }
            return text[r].split(separator: ":").last?.trimmingCharacters(in: .whitespaces).lowercased()
        }
        return nil
    }

    static func pixels(_ cg: CGImage) -> [SIMD3<Double>] {
        let w = 320, h = 180
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return [] }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        return (0..<(w * h)).map { i in SIMD3(Double(p[i * 4]), Double(p[i * 4 + 1]), Double(p[i * 4 + 2])) / 255 }
    }

    static func analyze(_ m: MediaItem, samples: Int = 8) async throws -> GradeAuto {
        var px: [SIMD3<Double>] = []
        if m.still, let src = CGImageSourceCreateWithURL(m.url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            px = pixels(cg)
        } else {
            let asset = AVURLAsset(url: m.url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true; gen.maximumSize = CGSize(width: 640, height: 360)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let d = try await asset.load(.duration).seconds
            for i in 0..<samples {
                let t = CMTime(seconds: d * (Double(i) + 0.5) / Double(samples), preferredTimescale: 600)
                if let cg = try? await gen.image(at: t).image { px += pixels(cg) }
            }
        }
        guard !px.isEmpty else { throw NSError(domain: "EliteStudio", code: 40, userInfo: [NSLocalizedDescriptionKey: "Impossibile leggere \(m.name)"]) }
        var a = stats(px)
        if let profile = srtProfile(m.url) { a.flat = ["d_cinlike", "d-cinelike", "dlog", "d_log", "dlog_m", "hlg"].contains(profile) || a.flat }
        return a
    }
}

// MARK: - Window

@MainActor
final class GradingModel: ObservableObject {
    let editor: Editor
    let targets: [ID]
    @Published var look = Grading.defaultLook
    @Published var amount = 1.0
    @Published var basic = GradeBasic()
    @Published var correct = true { didSet { if correct != oldValue { apply() } } }
    @Published var match = true { didSet { if match != oldValue { apply() } } }
    @Published var focus: ID?
    @Published var before: CGImage?
    @Published var after: CGImage?
    @Published var thumbs: [String: CGImage] = [:]
    @Published var info = "Analisi delle clip…"
    @Published var busy = false
    @Published var split = 0.5
    static var analysis: [String: GradeAuto] = [:]       // by file path, kept while the app runs
    private var source: CGImage?

    init(editor: Editor) {
        self.editor = editor
        let p = editor.project
        func usable(_ c: Clip) -> Bool { !c.isTitle && p.media(c.mediaID)?.hasVideo == true }
        var chosen = p.clips.filter { editor.selection.contains($0.id) && usable($0) }
        if chosen.isEmpty { chosen = p.clips.filter(usable) }
        targets = chosen.sorted { ($0.start, $0.track) < ($1.start, $1.track) }.map(\.id)
        focus = targets.first
        if let g = chosen.compactMap(\.effects.grade).first {
            look = g.look; amount = g.amount; correct = g.correct; match = g.match; basic = g.basic
        }
    }

    func clip(_ id: ID) -> Clip? { editor.project.clips.first { $0.id == id } }
    func media(_ id: ID) -> MediaItem? { clip(id).flatMap { editor.project.media($0.mediaID) } }
    func note(_ id: ID) -> String {
        guard let m = media(id) else { return "" }
        guard let a = Self.analysis[m.url.path] else { return "in analisi…" }
        return a.flat ? "D-Cinelike/flat" : "standard"
    }

    func start(force: Bool = false) {
        guard !targets.isEmpty else { info = "Nessuna clip video nella timeline: importa le clip e riapri questa finestra."; return }
        var seen = Set<String>()
        let todo = targets.compactMap { media($0) }.filter { seen.insert($0.url.path).inserted && (force || Self.analysis[$0.url.path] == nil) }
        let graded = targets.contains { clip($0)?.effects.grade != nil }
        guard !todo.isEmpty else {
            if !graded || force { apply() }
            Task { await refresh(thumbnails: true) }; return
        }
        busy = true
        Task {
            for (i, m) in todo.enumerated() {
                info = "Analisi \(i + 1)/\(todo.count): \(m.name)…"
                do { Self.analysis[m.url.path] = try await Grading.analyze(m) }
                catch { info = "Analisi non riuscita: \(error.localizedDescription)"; busy = false; return }
            }
            busy = false
            if !graded || force { apply() }
            await refresh(thumbnails: true)
        }
    }

    func autos() -> [String: GradeAuto] {
        var paths: [String] = []
        for id in targets { if let p = media(id)?.url.path, Self.analysis[p] != nil, !paths.contains(p) { paths.append(p) } }
        var values = paths.map { Self.analysis[$0]! }
        if match { values = Grading.match(values) }
        return Dictionary(uniqueKeysWithValues: zip(paths, values))
    }

    func grade(for id: ID, look l: String? = nil, amount a: Double? = nil, autos: [String: GradeAuto]? = nil) -> Grade {
        var g = Grade(); g.look = l ?? look; g.amount = ((a ?? amount) * 1000).rounded() / 1000; g.correct = correct; g.match = match
        g.basic = basic
        if let p = media(id)?.url.path { g.auto = (autos ?? self.autos())[p] ?? GradeAuto() }
        return g
    }

    func apply() {
        guard !targets.isEmpty, !busy else { return }
        let all = autos()
        let grades = Dictionary(uniqueKeysWithValues: targets.map { ($0, grade(for: $0, autos: all)) })
        editor.edit { p in for i in p.clips.indices { if let g = grades[p.clips[i].id] { p.clips[i].effects.grade = g } } }
        info = "Applicato «\(Grading.name(look))» al \(Int((amount * 100).rounded()))% su \(targets.count) clip. Trascina la linea gialla per confrontare. ⌘Z annulla."
        Task { await refresh(thumbnails: false) }
    }

    func choose(_ l: String) { guard l != look else { return }; look = l; apply() }

    func remove() {
        let ids = Set(targets)
        editor.edit { p in for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].effects.grade = nil } }
        info = "Grading rimosso (⌘Z per ripristinarlo)."; Task { await refresh(thumbnails: false) }
    }

    func exportCube() {
        guard let id = focus ?? targets.first, let m = media(id) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.nameFieldStringValue = m.url.deletingPathExtension().lastPathComponent + "_\(look).cube"
        panel.directoryURL = m.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Grading.cubeText(grade(for: id)).write(to: url, atomically: true, encoding: .ascii); info = "LUT salvata: \(url.path)" }
        catch { info = "Salvataggio non riuscito: \(error.localizedDescription)" }
    }

    func focusChanged() { source = nil; Task { await refresh(thumbnails: true) } }

    func frame() async -> CGImage? {
        if let source { return source }
        guard let id = focus, let c = clip(id), let m = media(id) else { return nil }
        let now = editor.clock.time
        let local = now >= c.start && now < c.end ? now - c.start : c.duration / 2
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: m.url))
        gen.appliesPreferredTrackTransform = true; gen.maximumSize = CGSize(width: 960, height: 540)
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let image = try? await gen.image(at: CMTime(seconds: c.sourceIn + local * c.speed, preferredTimescale: 600)).image
        source = image; return image
    }

    func refresh(thumbnails: Bool, previewAmount: Double? = nil) async {
        guard let src = await frame(), let id = focus, let c = clip(id) else { return }
        let g = c.effects.grade == nil ? nil : grade(for: id, amount: previewAmount)
        before = src
        after = await Task.detached { Grading.render(src, g) }.value
        guard thumbnails else { return }
        let small = await Task.detached { () -> CGImage? in
            let w = 336, h = max(2, Int(Double(src.height) * 336 / Double(max(1, src.width))))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .medium; ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.makeImage()
        }.value
        guard let small else { return }
        for l in Grading.order {
            let g = grade(for: id, look: l, amount: 1)
            thumbs[l] = await Task.detached { Grading.render(small, g) }.value
        }
    }
}

struct CompareView: View {
    @ObservedObject var model: GradingModel
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(white: 0.03)
                if let after = model.after {
                    let size = fitted(CGSize(width: after.width, height: after.height), in: geo.size)
                    let origin = CGPoint(x: (geo.size.width - size.width) / 2, y: (geo.size.height - size.height) / 2)
                    Image(decorative: after, scale: 1).resizable().frame(width: size.width, height: size.height).offset(x: origin.x, y: origin.y)
                    if let before = model.before {
                        Image(decorative: before, scale: 1).resizable().frame(width: size.width, height: size.height)
                            .mask(alignment: .leading) { Rectangle().frame(width: size.width * model.split) }
                            .offset(x: origin.x, y: origin.y)
                    }
                    Rectangle().fill(Color.yellow).frame(width: 2, height: size.height).offset(x: origin.x + size.width * model.split - 1, y: origin.y)
                    tag("PRIMA").offset(x: origin.x + 10, y: origin.y + 10)
                    tag("DOPO").offset(x: origin.x + size.width - 70, y: origin.y + 10)
                } else {
                    Text(model.info).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard let after = model.after else { return }
                let size = fitted(CGSize(width: after.width, height: after.height), in: geo.size)
                model.split = min(1, max(0, (v.location.x - (geo.size.width - size.width) / 2) / size.width))
            })
        }
    }
    private func fitted(_ s: CGSize, in box: CGSize) -> CGSize {
        let k = min(box.width / max(1, s.width), box.height / max(1, s.height)); return CGSize(width: s.width * k, height: s.height * k)
    }
    private func tag(_ t: String) -> some View {
        Text(t).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.6)).foregroundStyle(.white).frame(width: 60)
    }
}

struct GradingView: View {
    @ObservedObject var model: GradingModel
    @State private var sliding = 1.0
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                CompareView(model: model).frame(minWidth: 560, minHeight: 315)
                Text(model.info).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Grading.order, id: \.self) { l in
                            Button { model.choose(l) } label: {
                                VStack(spacing: 4) {
                                    Group {
                                        if let t = model.thumbs[l] { Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                                        else { Color(white: 0.12) }
                                    }
                                    .frame(width: 168, height: 95).clipped()
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(model.look == l ? Color.yellow : .clear, lineWidth: 2))
                                    Text(Grading.name(l)).font(.caption).lineLimit(1)
                                }
                            }.buttonStyle(.plain)
                        }
                    }.padding(.bottom, 4)
                }.frame(height: 128)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("COLORE").font(.headline).foregroundStyle(.yellow)
                Text("Clip coinvolte").font(.caption).foregroundStyle(.secondary)
                List(model.targets, id: \.self, selection: Binding(get: { model.focus }, set: { model.focus = $0; model.focusChanged() })) { id in
                    Text("\(model.media(id)?.name ?? "?")  ·  \(model.note(id))").font(.caption).lineLimit(1)
                }.frame(minHeight: 120)
                Toggle("Correzione automatica (livelli, bilanciamento, D-Cinelike)", isOn: $model.correct)
                Toggle("Uniforma le clip tra loro", isOn: $model.match)
                Text("Intensità look: \(Int((sliding * 100).rounded()))%").font(.caption)
                Slider(value: $sliding, in: 0...1.5, onEditingChanged: { editing in
                    if !editing { model.amount = sliding; model.apply() }
                })
                .onChange(of: sliding) { _, v in Task { await model.refresh(thumbnails: false, previewAmount: v) } }
                Text("Base").font(.subheadline.bold())
                GradeSlider(title: "Temperatura", value: $model.basic.temperature, range: -1...1) { model.apply() }
                GradeSlider(title: "Tinta", value: $model.basic.tint, range: -1...1) { model.apply() }
                GradeSlider(title: "Esposizione", value: $model.basic.exposure, range: -5...5) { model.apply() }
                GradeSlider(title: "Contrasto", value: $model.basic.contrast, range: 0...2) { model.apply() }
                GradeSlider(title: "Luci", value: $model.basic.highlights, range: -1...1) { model.apply() }
                GradeSlider(title: "Ombre", value: $model.basic.shadows, range: -1...1) { model.apply() }
                GradeSlider(title: "Bianchi", value: $model.basic.whites, range: -1...1) { model.apply() }
                GradeSlider(title: "Neri", value: $model.basic.blacks, range: -1...1) { model.apply() }
                GradeSlider(title: "Saturazione", value: $model.basic.saturation, range: 0...2) { model.apply() }
                GradeSlider(title: "Vividezza", value: $model.basic.vibrance, range: -1...1) { model.apply() }
                Button("Applica di nuovo / rianalizza") { model.start(force: true) }
                Button("Esporta LUT .cube (DaVinci)…") { model.exportCube() }
                Button("Rimuovi grading") { model.remove() }
                Spacer()
            }.frame(width: 260)
        }
        .padding(14)
        .frame(minWidth: 1000, minHeight: 600)
        .onAppear { sliding = model.amount; model.start() }
    }
}

struct GradeSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", value)).font(.caption.monospacedDigit())
            }
            Slider(value: $value, in: range, onEditingChanged: { editing in
                if !editing { onCommit() }
            }).controlSize(.small)
        }
    }
}

@MainActor
enum GradingWindow {
    private static var window: NSWindow?
    static func show(_ editor: Editor) {
        window?.close()
        editor.pause()
        let model = GradingModel(editor: editor)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Colore"; w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: GradingView(model: model))
        w.center(); w.makeKeyAndOrderFront(nil); window = w
    }
}
