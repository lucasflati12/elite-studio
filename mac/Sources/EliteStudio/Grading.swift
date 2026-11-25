import Foundation
import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
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
    var curves = GradeCurves()
    var hue = GradeHue()
    var inputLut = GradeLUT()
    var creativeLut = GradeLUT()
    enum K: String, CodingKey { case look, amount, correct, match, auto, wheels, basic, curves, hue, inputLut, creativeLut }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        look = c.get(.look, Grading.defaultLook); amount = c.get(.amount, 1); correct = c.get(.correct, true)
        match = c.get(.match, true); auto = c.get(.auto, GradeAuto())
        wheels = c.get(.wheels, GradeWheels()); basic = c.get(.basic, GradeBasic())
        curves = c.get(.curves, GradeCurves()); hue = c.get(.hue, GradeHue())
        inputLut = c.get(.inputLut, GradeLUT()); creativeLut = c.get(.creativeLut, GradeLUT())
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        let g = normalized
        try c.encode(g.look, forKey: .look); try c.encode(g.amount, forKey: .amount); try c.encode(g.correct, forKey: .correct)
        try c.encode(g.auto, forKey: .auto); try c.encode(g.wheels, forKey: .wheels); try c.encode(g.basic, forKey: .basic)
        try c.encode(g.curves, forKey: .curves); try c.encode(g.hue, forKey: .hue)
        try c.encode(g.inputLut, forKey: .inputLut); try c.encode(g.creativeLut, forKey: .creativeLut)
    }

    /// Mirrors grading.normalized(): clamped values, unknown look -> default.
    var normalized: Grade {
        var g = self
        func num(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double { v.isFinite ? min(hi, max(lo, v)) : fallback }
        if Grading.looks[g.look] == nil && g.look != "none" { g.look = Grading.defaultLook }
        g.amount = num(g.amount, 0, 1.5, 1)
        g.auto.black = num(auto.black, 0, 0.4, 0); g.auto.white = num(auto.white, 0.5, 1.1, 1); g.auto.gamma = num(auto.gamma, 0.5, 2, 1)
        g.auto.wb = auto.wb.count == 3 ? auto.wb.map { num($0, 0.8, 1.25, 1) } : [1, 1, 1]
        g.auto.median = nil
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
        g.match = false
        g.curves.normalize()
        g.hue.normalize()
        g.inputLut.normalize(); g.creativeLut.normalize()
        return g
    }
}

struct GradeCurves: Hashable, Codable {
    var master: [[Double]] = []; var r: [[Double]] = []; var g: [[Double]] = []; var b: [[Double]] = []
    enum K: String, CodingKey { case master, r, g, b }
    init() {}
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: K.self); master = c.get(.master, []); r = c.get(.r, []); g = c.get(.g, []); b = c.get(.b, []) }
    mutating func normalize() { master = Self.points(master, shift: false, monotone: true); r = Self.points(r, shift: false, monotone: true); g = Self.points(g, shift: false, monotone: true); b = Self.points(b, shift: false, monotone: true) }
    static func points(_ values: [[Double]], shift: Bool, monotone: Bool) -> [[Double]] {
        var out: [[Double]] = []
        for p in values where p.count == 2 {
            let x = p[0], y = p[1]
            if !x.isFinite || !y.isFinite { continue }
            out.append([min(1, max(0, x)), min(1, max(0, y))])
        }
        out.sort { $0[0] == $1[0] ? $0[1] < $1[1] : $0[0] < $1[0] }
        if monotone && out.count > 1 { for i in 1..<out.count { out[i][1] = max(out[i][1], out[i - 1][1]) } }
        return out
    }
}
struct GradeHue: Hashable, Codable {
    var sat: [[Double]] = []; var hue: [[Double]] = []; var lum: [[Double]] = []; var lumsat: [[Double]] = []
    enum K: String, CodingKey { case sat, hue, lum, lumsat }
    init() {}
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: K.self); sat = c.get(.sat, []); hue = c.get(.hue, []); lum = c.get(.lum, []); lumsat = c.get(.lumsat, []) }
    mutating func normalize() {
        sat = Self.points(sat, periodic: true, shift: false); hue = Self.points(hue, periodic: true, shift: true)
        lum = Self.points(lum, periodic: true, shift: false); lumsat = Self.points(lumsat, periodic: false, shift: false)
    }
    static func points(_ values: [[Double]], periodic: Bool, shift: Bool) -> [[Double]] {
        var out: [[Double]] = []
        for p in values where p.count == 2 {
            if !p[0].isFinite || !p[1].isFinite { continue }
            var x = p[0]; if periodic { x = x - 360 * floor(x / 360) } else { x = min(1, max(0, x)) }
            let y = shift ? min(180, max(-180, p[1])) : min(2, max(0, p[1]))
            out.append([x, y])
        }
        out.sort { $0[0] == $1[0] ? $0[1] < $1[1] : $0[0] < $1[0] }; return out
    }
}
struct GradeLUT: Hashable, Codable {
    var path = ""; var amount = 0.0
    enum K: String, CodingKey { case path, amount }
    init() {}
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: K.self); path = c.get(.path, ""); amount = c.get(.amount, 0) }
    mutating func normalize() { amount = amount.isFinite ? min(1, max(0, amount)) : 0 }
}

struct GradeWheels: Hashable, Codable {
    var lift: [Double] = [0, 0, 0]
    var gamma: [Double] = [0, 0, 0]
    var gain: [Double] = [0, 0, 0]
    var offset: [Double] = [0, 0, 0]
    enum K: String, CodingKey { case lift, gamma, gain, offset }
    init() {}
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: K.self); lift = c.get(.lift, [0, 0, 0]); gamma = c.get(.gamma, [0, 0, 0]); gain = c.get(.gain, [0, 0, 0]); offset = c.get(.offset, [0, 0, 0]) }
}

struct GradeBasic: Hashable, Codable {
    var temperature = 0.0, tint = 0.0, exposure = 0.0, contrast = 1.0, pivot = 0.5
    var highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0, saturation = 1.0, vibrance = 0.0
    enum K: String, CodingKey { case temperature, tint, exposure, contrast, pivot, highlights, shadows, whites, blacks, saturation, vibrance }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        temperature = c.get(.temperature, 0); tint = c.get(.tint, 0); exposure = c.get(.exposure, 0); contrast = c.get(.contrast, 1); pivot = c.get(.pivot, 0.5)
        highlights = c.get(.highlights, 0); shadows = c.get(.shadows, 0); whites = c.get(.whites, 0); blacks = c.get(.blacks, 0); saturation = c.get(.saturation, 1); vibrance = c.get(.vibrance, 0)
    }
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

    private struct Cube { let size: Int; let values: [SIMD3<Double>]; let lo: SIMD3<Double>; let hi: SIMD3<Double>; let oneD: Bool }
    private static let cubeLock = NSLock()
    private static var cubeCache: [String: Cube] = [:]
    private static func cube(_ path: String) -> Cube? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let date = attrs[.modificationDate] as? Date else { return nil }
        let key = url.path + "|" + String(date.timeIntervalSince1970)
        cubeLock.lock(); let cached = cubeCache[key]; cubeLock.unlock(); if let cached { return cached }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var size1: Int?; var size3: Int?; var lo = SIMD3<Double>(repeating: 0); var hi = SIMD3<Double>(repeating: 1); var rows: [SIMD3<Double>] = []
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if line.isEmpty || line.hasPrefix("TITLE") { continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard let head = parts.first else { continue }
            if head == "LUT_1D_SIZE", parts.count > 1 { size1 = Int(parts[1]); continue }
            if head == "LUT_3D_SIZE", parts.count > 1 { size3 = Int(parts[1]); continue }
            if (head == "DOMAIN_MIN" || head == "DOMAIN_MAX") && parts.count >= 4 {
                let v = SIMD3<Double>(Double(parts[1]) ?? 0, Double(parts[2]) ?? 0, Double(parts[3]) ?? 0)
                if head == "DOMAIN_MIN" { lo = v } else { hi = v }; continue
            }
            if parts.count >= 3, let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) { rows.append(SIMD3(r, g, b)) }
        }
        var result: Cube?
        if let n = size3, n > 1, rows.count >= n * n * n { result = Cube(size: n, values: Array(rows.suffix(n * n * n)), lo: lo, hi: hi, oneD: false) }
        else if let n = size1, n > 1, rows.count >= n { result = Cube(size: n, values: Array(rows.suffix(n)), lo: lo, hi: hi, oneD: true) }
        guard let result else { return nil }
        cubeLock.lock(); if cubeCache.count > 32 { cubeCache.removeAll() }; cubeCache[key] = result; cubeLock.unlock(); return result
    }
    private static func applyLUT(_ color: SIMD3<Double>, _ spec: GradeLUT) -> SIMD3<Double> {
        guard !spec.path.isEmpty, spec.amount > 0, let lut = cube(spec.path) else { return color }
        let span = simd_max(SIMD3(repeating: 1e-9), lut.hi - lut.lo)
        let q = simd_clamp((color - lut.lo) / span, SIMD3(repeating: 0), SIMD3(repeating: 1))
        let top = Double(lut.size - 1)
        let pos = q * top
        var out = SIMD3<Double>(repeating: 0)
        if lut.oneD {
            for c in 0..<3 {
                let x = c == 0 ? pos.x : (c == 1 ? pos.y : pos.z)
                let a = min(lut.size - 2, Int(x)); let f = x - Double(a)
                let va = lut.values[a]; let vb = lut.values[a + 1]
                let av = c == 0 ? va.x : (c == 1 ? va.y : va.z); let bv = c == 0 ? vb.x : (c == 1 ? vb.y : vb.z)
                let v = av + (bv - av) * f
                if c == 0 { out.x = v } else if c == 1 { out.y = v } else { out.z = v }
            }
        } else {
            let ix = SIMD3<Int>(Int(pos.x), Int(pos.y), Int(pos.z)); let j = SIMD3<Int>(min(lut.size - 2, ix.x), min(lut.size - 2, ix.y), min(lut.size - 2, ix.z))
            let f = SIMD3<Double>(pos.x - Double(j.x), pos.y - Double(j.y), pos.z - Double(j.z))
            for a in 0...1 { for b in 0...1 { for c in 0...1 {
                let rr = j.x + a; let gg = j.y + b; let bb = j.z + c
                let idx = bb * lut.size * lut.size + gg * lut.size + rr
                let wx = a == 1 ? f.x : 1 - f.x; let wy = b == 1 ? f.y : 1 - f.y; let wz = c == 1 ? f.z : 1 - f.z
                out += lut.values[idx] * (wx * wy * wz)
            } } }
        }
        return clamp01(color + (out - color) * spec.amount)
    }
    private static func mono(_ x: Double, _ points: [[Double]]) -> Double {
        if points.isEmpty { return x }
        var p: [[Double]] = [[0, 0]]; p.append(contentsOf: points); p.append([1, 1]); p.sort { $0[0] == $1[0] ? $0[1] < $1[1] : $0[0] < $1[0] }
        var clean: [[Double]] = []
        for pair in p { if let last = clean.last, pair[0] <= last[0] + 1e-8 { continue }; clean.append([pair[0], min(1, max(0, pair[1]))]) }
        if clean.count < 2 { return x }
        let n = clean.count; var d = [Double](repeating: 0, count: n - 1); var m = [Double](repeating: 0, count: n)
        for i in 0..<(n - 1) { d[i] = (clean[i + 1][1] - clean[i][1]) / max(1e-9, clean[i + 1][0] - clean[i][0]) }
        m[0] = d[0]; m[n - 1] = d[n - 2]
        if n > 2 { for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : 2 * d[i - 1] * d[i] / (d[i - 1] + d[i]) } }
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0 }
            else { let a = m[i] / d[i]; let b = m[i + 1] / d[i]; let s = a * a + b * b
                if s > 9 { let t = 3 / sqrt(s); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] } }
        }
        let z = min(clean[n - 1][0], max(clean[0][0], x)); var j = n - 2
        for i in 0..<(n - 1) { if z < clean[i + 1][0] { j = i; break } }
        let h = clean[j + 1][0] - clean[j][0]; let t = (z - clean[j][0]) / h
        let t2 = t * t; let t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * clean[j][1] + (t3 - 2 * t2 + t) * h * m[j] + (-2 * t3 + 3 * t2) * clean[j + 1][1] + (t3 - t2) * h * m[j + 1]
    }
    private static func periodic(_ x: Double, _ points: [[Double]], _ neutral: Double) -> Double {
        guard let first = points.first, let last = points.last else { return neutral }
        let xx = fmod360(x); var left = [last[0] - 360, last[1]]; var right = [first[0] + 360, first[1]]
        for p in points { if p[0] <= xx { left = p }; if p[0] > xx { right = p; break } }
        let a = left[0] > xx ? last[0] - 360 : left[0]; let b = right[0] < xx ? first[0] + 360 : right[0]
        let y0 = left[1]; let y1 = right[1]; return y0 + (y1 - y0) * ((xx - a) / max(1e-9, b - a))
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
        base = applyLUT(base, g.inputLut)
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
        if !g.curves.master.isEmpty || !g.curves.r.isEmpty || !g.curves.g.isEmpty || !g.curves.b.isEmpty {
            base = SIMD3(mono(base.x, g.curves.master), mono(base.y, g.curves.master), mono(base.z, g.curves.master))
            base = SIMD3(mono(base.x, g.curves.r), mono(base.y, g.curves.g), mono(base.z, g.curves.b))
        }
        if !g.hue.sat.isEmpty || !g.hue.hue.isEmpty || !g.hue.lum.isEmpty || !g.hue.lumsat.isEmpty {
            var (h, s, val) = hsv(clamp01(base))
            let chroma = smooth(0.04, 0.22, s)
            let sat = periodic(h, g.hue.sat, 1)
            let shift = periodic(h, g.hue.hue, 0)
            let lum = periodic(h, g.hue.lum, 1)
            let lumaSat = periodic(simd_dot(base, luma), g.hue.lumsat, 1)
            h += shift * chroma
            s = min(1, max(0, s * (1 + (sat - 1) * chroma) * (1 + (lumaSat - 1) * chroma)))
            val = min(1, max(0, val * (1 + (lum - 1) * chroma)))
            base = rgb(h, s, val)
        }
        if g.look != "none", g.amount > 0, let L = looks[g.look] {
            let out = look(base, L)
            base = clamp01(base + (out - base) * g.amount)
        }
        return applyLUT(base, g.creativeLut)
    }

    // MARK: LUT

    private static let lock = NSLock()
    private static var tables: [String: [SIMD3<Float>]] = [:]

    /// size³ entries, red fastest (same order as .cube).
    static func table(_ grade: Grade) -> [SIMD3<Float>] {
        let g = grade.normalized
        func stamp(_ spec: GradeLUT) -> String {
            guard !spec.path.isEmpty, let attrs = try? FileManager.default.attributesOfItem(atPath: (spec.path as NSString).expandingTildeInPath), let date = attrs[.modificationDate] as? Date else { return "missing" }
            return String(date.timeIntervalSince1970)
        }
        let key = String(describing: g) + "|" + stamp(g.inputLut) + "|" + stamp(g.creativeLut)
        lock.lock(); if let t = tables[key] { lock.unlock(); return t }; lock.unlock()
        let n = size; var out = [SIMD3<Float>](); out.reserveCapacity(n * n * n)
        for b in 0..<n { for gg in 0..<n { for r in 0..<n {
            let v = apply(SIMD3(Double(r), Double(gg), Double(b)) / Double(n - 1), g)
            out.append(SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)))
        } } }
        lock.lock(); if tables.count > 32 { tables.removeAll() }; tables[key] = out; lock.unlock()
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
                let i0 = SIMD3<Int>(Int(p.x), Int(p.y), Int(p.z))
                let i1 = SIMD3<Int>(min(i0.x + 1, n - 1), min(i0.y + 1, n - 1), min(i0.z + 1, n - 1))
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
    @Published var wheels = GradeWheels()
    @Published var curves = GradeCurves()
    @Published var hue = GradeHue()
    @Published var inputLut = GradeLUT()
    @Published var creativeLut = GradeLUT()
    @Published var bypass = false
    @Published var scope = "Waveform"
    @Published var scopeImage: CGImage?
    @Published var selectedCurvePoint: Int?
    @Published var correct = true
    @Published var match = true
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
            wheels = g.wheels; curves = g.curves; hue = g.hue; inputLut = g.inputLut; creativeLut = g.creativeLut
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
        g.basic = basic; g.wheels = wheels; g.curves = curves; g.hue = hue; g.inputLut = inputLut; g.creativeLut = creativeLut
        if let existing = clip(id)?.effects.grade { g.auto = existing.auto }
        else if let p = media(id)?.url.path { g.auto = (autos ?? self.autos())[p] ?? GradeAuto() }
        return g
    }

    func apply(field: String = "all", ids overrideIDs: [ID]? = nil) {
        guard !targets.isEmpty, !busy else { return }
        let all = autos()
        let ids = overrideIDs ?? targets
        let grades = Dictionary(uniqueKeysWithValues: ids.map { ($0, grade(for: $0, autos: all)) })
        editor.edit("grade.\(field)") { p in for i in p.clips.indices { if let g = grades[p.clips[i].id] { p.clips[i].effects.grade = g } } }
        info = "Applicato «\(Grading.name(look))» al \(Int((amount * 100).rounded()))% su \(targets.count) clip. Trascina la linea gialla per confrontare. ⌘Z annulla."
        Task { await refresh(thumbnails: false) }
    }

    func choose(_ l: String) { guard l != look else { return }; look = l; apply() }

    func applyAll() { let ids = editor.project.clips.filter { !$0.isTitle && editor.project.media($0.mediaID)?.hasVideo == true }.map(\.id); apply(field: "allClips", ids: ids) }
    func applyTrack() { guard let id = focus, let c = clip(id) else { return }; let ids = editor.project.clips.filter { $0.track == c.track && !$0.isTitle && editor.project.media($0.mediaID)?.hasVideo == true }.map(\.id); apply(field: "track", ids: ids) }
    func copyGrade() { guard let id = focus, let c = clip(id) else { return }; Self.copied = c.effects.grade ?? grade(for: id) }
    func pasteGrade() {
        guard let source = Self.copied else { return }
        var prepared: [ID: Grade] = [:]
        for id in targets { var g = source; if let old = clip(id)?.effects.grade { g.auto = old.auto }; prepared[id] = g }
        editor.edit("grade.paste") { p in for i in p.clips.indices { if let g = prepared[p.clips[i].id] { p.clips[i].effects.grade = g } } }
        if let g = prepared[focus ?? ""] { look = g.look; amount = g.amount; correct = g.correct; basic = g.basic; wheels = g.wheels; curves = g.curves; hue = g.hue; inputLut = g.inputLut; creativeLut = g.creativeLut }
        Task { await refresh(thumbnails: false) }
    }
    private static var copied: Grade?
    func reset(_ tab: String) {
        switch tab {
        case "Automatico": look = Grading.defaultLook; amount = 1; correct = true; match = true; apply(field: "auto")
        case "Primarie": basic = GradeBasic(); wheels = GradeWheels(); apply(field: "basic")
        case "Curve": curves = GradeCurves(); apply(field: "curves")
        case "Curve HSL": hue = GradeHue(); apply(field: "hue")
        default: inputLut = GradeLUT(); creativeLut = GradeLUT(); apply(field: "lut")
        }
    }
    func chooseLUT(input: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if input { inputLut.path = url.path; if inputLut.amount == 0 { inputLut.amount = 1 }; apply(field: "inputLut") }
        else { creativeLut.path = url.path; if creativeLut.amount == 0 { creativeLut.amount = 1 }; apply(field: "creativeLut") }
        Task { await refresh(thumbnails: false) }
    }
    func savePreset() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Look.json"; panel.allowedContentTypes = [.json]
        panel.directoryURL = Self.presetsURL; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url, let id = focus else { return }
        guard url.deletingLastPathComponent().standardizedFileURL == Self.presetsURL.standardizedFileURL else { info = "I preset vanno salvati nella cartella grades."; return }
        var g = grade(for: id); g.auto = GradeAuto(); g.match = false
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(g.normalized)
            var object = (try JSONSerialization.jsonObject(with: encoded)) as? [String: Any] ?? [:]
            object.removeValue(forKey: "auto")
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch { info = "Preset non salvato: \(error.localizedDescription)" }
    }
    func loadPreset() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.directoryURL = Self.presetsURL
        guard panel.runModal() == .OK, let url = panel.url, Self.isPreset(url), let data = try? Data(contentsOf: url), let g = try? JSONDecoder().decode(Grade.self, from: data) else { return }
        look = g.look; amount = g.amount; correct = g.correct; basic = g.basic; wheels = g.wheels; curves = g.curves; hue = g.hue; inputLut = g.inputLut; creativeLut = g.creativeLut
        apply(field: "preset"); Task { await refresh(thumbnails: false) }
    }
    func deletePreset() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.directoryURL = Self.presetsURL
        guard panel.runModal() == .OK, let url = panel.url, Self.isPreset(url) else { return }; try? FileManager.default.removeItem(at: url)
    }
    private static var presetsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/EliteStudio/grades", isDirectory: true) }
    private static func isPreset(_ url: URL) -> Bool { url.standardizedFileURL.deletingLastPathComponent() == presetsURL.standardizedFileURL }

    func remove() {
        let ids = Set(targets)
        editor.edit("grade.remove") { p in for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].effects.grade = nil } }
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
        let g = bypass || c.effects.grade == nil ? nil : grade(for: id, amount: previewAmount)
        before = src
        after = await Task.detached { Grading.render(src, g) }.value
        let rendered = after
        let scopeName = scope
        scopeImage = await Task.detached { rendered.flatMap { ScopeRenderer.render($0, kind: scopeName) } }.value
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
    @State private var tab = "Automatico"
    @State private var sliding = 1.0
    @State private var wheelName = "lift"
    @State private var wheelMaster = 0.0
    @State private var curveName = "master"
    @State private var hueName = "sat"
    @State private var presetName = ""
    private let tabs = ["Automatico", "Primarie", "Curve", "Curve HSL", "LUT"]
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                CompareView(model: model).frame(minWidth: 560, minHeight: 300)
                HStack { Toggle("Bypass anteprima", isOn: $model.bypass).toggleStyle(.switch); Picker("Scope", selection: $model.scope) { Text("Waveform").tag("Waveform"); Text("Parade").tag("Parade"); Text("Vectorscope").tag("Vectorscope"); Text("Istogramma").tag("Istogramma") }.frame(width: 220) }
                if let image = model.scopeImage { Image(decorative: image, scale: 1).resizable().interpolation(.none).frame(height: 105).background(Color.black) }
                Text(model.info).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                ScrollView(.horizontal) { HStack(spacing: 8) { ForEach(Grading.order, id: \.self) { l in Button { model.choose(l) } label: { VStack(spacing: 4) { Group { if let t = model.thumbs[l] { Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill) } else { Color(white: 0.12) } }.frame(width: 144, height: 80).clipped().overlay(RoundedRectangle(cornerRadius: 3).stroke(model.look == l ? Color.yellow : .clear, lineWidth: 2)); Text(Grading.name(l)).font(.caption).lineLimit(1) } }.buttonStyle(.plain) } } }.frame(height: 110)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("COLORE").font(.headline).foregroundStyle(.yellow); Spacer(); Button("Reset") { model.reset(tab) } }
                Text("Clip coinvolte").font(.caption).foregroundStyle(.secondary)
                List(model.targets, id: \.self, selection: Binding(get: { model.focus }, set: { model.focus = $0; model.focusChanged() })) { id in Text("\(model.media(id)?.name ?? "?") · \(model.note(id))").font(.caption).lineLimit(1) }.frame(height: 90)
                Picker("Sezione colore", selection: $tab) { ForEach(tabs, id: \.self) { Text($0) } }.pickerStyle(.segmented)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if tab == "Automatico" {
                            Toggle("Correzione automatica", isOn: $model.correct).onChange(of: model.correct) { _, _ in model.apply(field: "correct") }
                            Toggle("Uniforma le clip", isOn: $model.match).onChange(of: model.match) { _, _ in model.apply(field: "match") }
                            Text("Intensità look: \(Int((sliding * 100).rounded()))%").font(.caption)
                            Slider(value: $sliding, in: 0...1.5, onEditingChanged: { if !$0 { model.amount = sliding; model.apply(field: "amount") } }).onChange(of: sliding) { _, v in model.amount = v; Task { await model.refresh(thumbnails: false, previewAmount: v) } }
                            ForEach(Grading.order, id: \.self) { name in if name != "none" { Button(Grading.name(name)) { model.choose(name) } } }
                        } else if tab == "Primarie" {
                            Picker("Ruota", selection: $wheelName) { Text("Lift").tag("lift"); Text("Gamma").tag("gamma"); Text("Gain").tag("gain"); Text("Offset").tag("offset") }
                            ColorWheel(value: wheelBinding, onChange: { model.apply(field: "wheels.\(wheelName)") })
                            GradeSlider(title: "Master", value: masterBinding, range: 0...1) { model.apply(field: "wheels.\(wheelName).master") }
                            GradeSlider(title: "Temperatura", value: $model.basic.temperature, range: -1...1) { model.apply(field: "basic.temperature") }
                            GradeSlider(title: "Tinta", value: $model.basic.tint, range: -1...1) { model.apply(field: "basic.tint") }
                            GradeSlider(title: "Esposizione", value: $model.basic.exposure, range: -5...5) { model.apply(field: "basic.exposure") }
                            GradeSlider(title: "Contrasto", value: $model.basic.contrast, range: 0...2) { model.apply(field: "basic.contrast") }
                            GradeSlider(title: "Luci", value: $model.basic.highlights, range: -1...1) { model.apply(field: "basic.highlights") }
                            GradeSlider(title: "Ombre", value: $model.basic.shadows, range: -1...1) { model.apply(field: "basic.shadows") }
                            GradeSlider(title: "Bianchi", value: $model.basic.whites, range: -1...1) { model.apply(field: "basic.whites") }
                            GradeSlider(title: "Neri", value: $model.basic.blacks, range: -1...1) { model.apply(field: "basic.blacks") }
                            GradeSlider(title: "Saturazione", value: $model.basic.saturation, range: 0...2) { model.apply(field: "basic.saturation") }
                            GradeSlider(title: "Vividezza", value: $model.basic.vibrance, range: -1...1) { model.apply(field: "basic.vibrance") }
                        } else if tab == "Curve" {
                            Picker("Canale", selection: $curveName) { Text("Master").tag("master"); Text("Rosso").tag("r"); Text("Verde").tag("g"); Text("Blu").tag("b") }
                            CurveEditor(points: curveBinding, hueBackground: false, selected: $model.selectedCurvePoint, onChange: { model.apply(field: "curves.\(curveName)") })
                            Button("Rimuovi punto") { removeCurvePoint() }
                        } else if tab == "Curve HSL" {
                            Picker("Canale HSL", selection: $hueName) { Text("Saturazione").tag("sat"); Text("Tonalità").tag("hue"); Text("Luminanza").tag("lum"); Text("Lum/Sat").tag("lumsat") }
                            CurveEditor(points: hueBinding, hueBackground: true, periodic: hueName != "lumsat", shiftValues: hueName == "hue", selected: $model.selectedCurvePoint, onChange: { model.apply(field: "hue.\(hueName)") })
                            Button("Rimuovi punto") { removeHuePoint() }
                        } else {
                            lutRow("LUT ingresso", spec: $model.inputLut, input: true)
                            lutRow("LUT creativa", spec: $model.creativeLut, input: false)
                            HStack { Button("Salva preset…") { model.savePreset() }; Button("Carica…") { model.loadPreset() }; Button("Elimina…") { model.deletePreset() } }
                        }
                    }
                }
                HStack { Button("Applica a tutte le clip") { model.applyAll() }; Button("Applica alla traccia") { model.applyTrack() } }
                Button("Applica di nuovo / rianalizza") { model.start(force: true) }
                Button("Esporta LUT .cube…") { model.exportCube() }; Button("Rimuovi grading") { model.remove() }
            }.frame(width: 310)
        }.padding(14).frame(minWidth: 1000, minHeight: 600).onAppear { sliding = model.amount; let p = wheelBinding.wrappedValue; wheelMaster = min(1, sqrt(p.x * p.x + p.y * p.y)); model.start() }
            .onChange(of: model.bypass) { _, _ in Task { await model.refresh(thumbnails: false) } }
            .onChange(of: model.scope) { _, _ in Task { await model.refresh(thumbnails: false) } }
            .onChange(of: wheelName) { _, _ in let p = wheelBinding.wrappedValue; wheelMaster = min(1, sqrt(p.x * p.x + p.y * p.y)) }
    }
    private var wheelBinding: Binding<CGPoint> { Binding(get: { let a = wheelArray; return CGPoint(x: a[0] / 0.25, y: a[1] / 0.25) }, set: { wheelSet($0); wheelMaster = min(1, sqrt($0.x * $0.x + $0.y * $0.y)) }) }
    private var wheelArray: [Double] { switch wheelName { case "gamma": return model.wheels.gamma; case "gain": return model.wheels.gain; case "offset": return model.wheels.offset; default: return model.wheels.lift } }
    private func wheelSet(_ p: CGPoint) { let x = min(1, max(-1, p.x)); let y = min(1, max(-1, p.y)); let z = -(0.2126 * x + 0.7152 * y) / 0.0722; let v = [Double(0.25 * x), Double(0.25 * y), Double(0.25 * z)]; switch wheelName { case "gamma": model.wheels.gamma = v; case "gain": model.wheels.gain = v; case "offset": model.wheels.offset = v; default: model.wheels.lift = v } }
    private var masterBinding: Binding<Double> { Binding(get: { wheelMaster }, set: { v in let old = wheelBinding.wrappedValue; let length = sqrt(old.x * old.x + old.y * old.y); let dx = length > 1e-9 ? old.x / length : 1; let dy = length > 1e-9 ? old.y / length : 0; wheelMaster = v; wheelSet(CGPoint(x: dx * v, y: dy * v)) }) }
    private var curveBinding: Binding<[[Double]]> { Binding(get: { curveName == "master" ? model.curves.master : curveName == "r" ? model.curves.r : curveName == "g" ? model.curves.g : model.curves.b }, set: { v in if curveName == "master" { model.curves.master = v } else if curveName == "r" { model.curves.r = v } else if curveName == "g" { model.curves.g = v } else { model.curves.b = v } }) }
    private var hueBinding: Binding<[[Double]]> { Binding(get: { hueName == "sat" ? model.hue.sat : hueName == "hue" ? model.hue.hue : hueName == "lum" ? model.hue.lum : model.hue.lumsat }, set: { v in if hueName == "sat" { model.hue.sat = v } else if hueName == "hue" { model.hue.hue = v } else if hueName == "lum" { model.hue.lum = v } else { model.hue.lumsat = v } }) }
    private func removeCurvePoint() { guard let index = model.selectedCurvePoint, curveBinding.wrappedValue.indices.contains(index) else { return }; var values = curveBinding.wrappedValue; values.remove(at: index); curveBinding.wrappedValue = values; model.selectedCurvePoint = nil; model.apply(field: "curves.\(curveName)") }
    private func removeHuePoint() { guard let index = model.selectedCurvePoint, hueBinding.wrappedValue.indices.contains(index) else { return }; var values = hueBinding.wrappedValue; values.remove(at: index); hueBinding.wrappedValue = values; model.selectedCurvePoint = nil; model.apply(field: "hue.\(hueName)") }
    @ViewBuilder private func lutRow(_ title: String, spec: Binding<GradeLUT>, input: Bool) -> some View {
        Text(title).font(.subheadline.bold()); HStack { Button("Scegli .cube…") { model.chooseLUT(input: input) }; Button("Pulisci") { spec.wrappedValue = GradeLUT(); model.apply(field: input ? "inputLut" : "creativeLut") } }
        Text(spec.wrappedValue.path.isEmpty ? "Nessuna LUT" : URL(fileURLWithPath: spec.wrappedValue.path).lastPathComponent).font(.caption).lineLimit(1)
        if !spec.wrappedValue.path.isEmpty && !FileManager.default.fileExists(atPath: spec.wrappedValue.path) { Text("File LUT mancante").foregroundStyle(.red).font(.caption) }
        GradeSlider(title: "Intensità", value: spec.amount, range: 0...1) { model.apply(field: input ? "inputLut.amount" : "creativeLut.amount") }
    }
}

struct ColorWheel: View {
    @Binding var value: CGPoint
    let onChange: () -> Void
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: side / 2, y: side / 2)
            let radius = side * 0.44
            ZStack {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, Color(red: 1, green: 0, blue: 1), .red], center: .center)).overlay(Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: radius))).frame(width: radius * 2, height: radius * 2)
                Circle().stroke(.white.opacity(0.6), lineWidth: 1).frame(width: radius * 2, height: radius * 2)
                Circle().fill(.white).frame(width: 12, height: 12).overlay(Circle().stroke(.black, lineWidth: 1)).position(x: center.x + value.x * radius, y: center.y - value.y * radius)
            }.frame(width: side, height: side).contentShape(Circle()).gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let dx = (v.location.x - center.x) / radius; let dy = (center.y - v.location.y) / radius
                let length = sqrt(dx * dx + dy * dy); let factor = length > 1 ? 1 / length : 1
                value = CGPoint(x: dx * factor, y: dy * factor); onChange()
            })
        }.frame(height: 180)
    }
}

struct CurveEditor: View {
    @Binding var points: [[Double]]
    let hueBackground: Bool
    var periodic = false
    var shiftValues = false
    @Binding var selected: Int?
    let onChange: () -> Void
    private func plotY(_ value: Double) -> Double { shiftValues ? (value + 180) / 360 : value / 2 }
    private func dataY(_ value: Double) -> Double { shiftValues ? value * 360 - 180 : value * 2 }
    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            Canvas { context, size in
                context.fill(Path(rect), with: .color(Color.black.opacity(hueBackground ? 0.08 : 0.35)))
                for i in 1...3 {
                    let x = size.width * CGFloat(i) / 4; let y = size.height * CGFloat(i) / 4
                    var grid = Path(); grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); context.stroke(grid, with: .color(.white.opacity(0.15)), lineWidth: 1)
                }
                var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
                let sorted = points.sorted { $0[0] < $1[0] }
                for p in sorted { let xx = periodic ? p[0] / 360 : p[0]; let yy = hueBackground ? plotY(p[1]) : p[1]; path.addLine(to: CGPoint(x: xx * size.width, y: size.height - yy * size.height)) }
                path.addLine(to: CGPoint(x: size.width, y: 0)); context.stroke(path, with: .color(.white), lineWidth: 2)
                for (i, p) in sorted.enumerated() { let xx = periodic ? p[0] / 360 : p[0]; let yy = hueBackground ? plotY(p[1]) : p[1]; let r = CGRect(x: xx * size.width - 5, y: size.height - yy * size.height - 5, width: 10, height: 10); context.fill(Path(ellipseIn: r), with: .color(selected == i ? .yellow : .white)) }
            }
            .background { if hueBackground { AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, Color(red: 1, green: 0, blue: 1), .red], center: .center).opacity(0.35) } }
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                let px = min(1, max(0, v.location.x / max(1, geo.size.width))); let py = min(1, max(0, 1 - v.location.y / max(1, geo.size.height)))
                var sorted = points.sorted { $0[0] < $1[0] }
                var nearest: Int?; var distance = 16.0
                for i in sorted.indices { let xx = periodic ? sorted[i][0] / 360 : sorted[i][0]; let yy = hueBackground ? plotY(sorted[i][1]) : sorted[i][1]; let dx = Double(xx * geo.size.width) - Double(v.location.x); let dy = Double(geo.size.height) * (1 - Double(yy)) - Double(v.location.y); let d = dx * dx + dy * dy; if d < distance { distance = d; nearest = i } }
                if let nearest { let x = periodic ? Double(px) * 360 : Double(px); let y = hueBackground ? dataY(Double(py)) : Double(py); sorted[nearest] = [x, y]; selected = nearest }
                else { let x = periodic ? Double(px) * 360 : Double(px); let y = hueBackground ? dataY(Double(py)) : Double(py); sorted.append([x, y]); sorted.sort { $0[0] < $1[0] }; selected = sorted.firstIndex { abs($0[0] - x) < 0.0001 } }
                points = sorted; onChange()
            })
        }.frame(height: 190).overlay(Rectangle().stroke(.white.opacity(0.35), lineWidth: 1))
    }
}

private enum ScopeRenderer {
    static func render(_ source: CGImage, kind: String) -> CGImage? {
        let w = min(480, source.width); let h = max(1, Int(Double(source.height) * Double(w) / Double(max(1, source.width))))
        guard let input = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        input.interpolationQuality = .medium; input.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h)); guard let data = input.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4); let outW = 480; let outH = 180
        guard let out = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: outW * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        out.setFillColor(NSColor.black.cgColor); out.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        out.setLineWidth(1)
        if kind == "Istogramma" {
            var hist = [[Int]](repeating: [Int](repeating: 0, count: outW), count: 3)
            for i in 0..<(w * h) { for c in 0..<3 { let bin = min(outW - 1, Int(pixels[i * 4 + c]) * outW / 256); hist[c][bin] += 1 } }
            let maxCount = max(1, hist.flatMap { $0 }.max() ?? 1)
            for c in 0..<3 { out.setStrokeColor([NSColor.red, NSColor.green, NSColor.blue][c].withAlphaComponent(0.7).cgColor); var path = CGMutablePath(); path.move(to: CGPoint(x: 0, y: outH)); for x in 0..<outW { let y = outH - Int(Double(hist[c][x]) / Double(maxCount) * Double(outH - 1)); path.addLine(to: CGPoint(x: x, y: y)) }; out.addPath(path); out.strokePath() }
        } else {
            for y in 0..<h { for x in 0..<w {
                let i = (y * w + x) * 4; let r = Double(pixels[i]) / 255; let g = Double(pixels[i + 1]) / 255; let b = Double(pixels[i + 2]) / 255
                var px = x; var py = outH - 1 - Int(Double(y) / Double(max(1, h - 1)) * Double(outH - 1)); var color = NSColor.white.withAlphaComponent(0.12)
                if kind == "Parade" { let channel = x % 3; px = channel * (outW / 3) + Int((Double(x / 3) / Double(max(1, w / 3))) * Double(outW / 3 - 1)); py = outH - 1 - Int([r, g, b][channel] * Double(outH - 1)); color = [NSColor.red, NSColor.green, NSColor.blue][channel].withAlphaComponent(0.35) }
                else if kind == "Vectorscope" { let u = (b - (r + g) * 0.5); let v = (r - g) * 0.866; px = outW / 2 + Int(u * Double(outH) * 0.8); py = outH / 2 - Int(v * Double(outH) * 0.8); color = NSColor(hue: CGFloat((atan2(v, u) / (2 * Double.pi) + 1).truncatingRemainder(dividingBy: 1)), saturation: 0.85, brightness: 1, alpha: 0.35) }
                else { px = Int(Double(x) / Double(max(1, w - 1)) * Double(outW - 1)); py = outH - 1 - Int((r * 0.2126 + g * 0.7152 + b * 0.0722) * Double(outH - 1)) }
                if px >= 0 && px < outW && py >= 0 && py < outH { out.setFillColor(color.cgColor); out.fill(CGRect(x: px, y: py, width: 2, height: 2)) }
            } }
        }
        return out.makeImage()
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
    static var activeModel: GradingModel?
    static func show(_ editor: Editor) {
        window?.close()
        editor.pause()
        let model = GradingModel(editor: editor)
        activeModel = model
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Colore"; w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: GradingView(model: model))
        w.center(); w.makeKeyAndOrderFront(nil); window = w
    }
    static func copyGrade() { activeModel?.copyGrade() }
    static func pasteGrade() { activeModel?.pasteGrade() }
}
