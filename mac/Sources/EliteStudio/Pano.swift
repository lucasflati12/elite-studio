import Foundation
import simd

// 360 support for Insta360 .insv clips (tested on the ONE R 360 mod, all three recording layouts).
//
// An .insv file is an MP4 with a metadata trailer at the end:
//   [records...][32 bytes padding][u32 trailer size][u32 version][32 byte magic]
// Records are read backwards, each followed by [u16 id][u32 size].
//   0x101 = protobuf metadata (camera, lens calibration "offset", timing)
//   0x300 = IMU samples (gyro + accelerometer)
// Public reference for the layout: github.com/AdrianEddy/telemetry-parser (MIT/Apache).
//
// Pipeline: gyro -> camera orientation -> horizon from the accelerometer -> smoothed heading
// -> per-frame rotation; the compositor then renders the reframed view straight from the fisheyes.

/// One fisheye lens of the rig, in the pixel space of the video file.
struct PanoLens {
    var cx: Double, cy: Double        // optical centre (px)
    var r100: Double                  // image radius at 100° from the axis (px)
    var alpha: Double                 // in-plane rotation of the picture (deg)
    var rotation: simd_double3x3      // lens -> camera
    var xOffset: Double = 0           // second lens in a side-by-side file
}

/// Everything read from a clip's trailer. Immutable; the stabilization tables are cached inside.
final class PanoData: @unchecked Sendable {
    let camera: String
    let lenses: [PanoLens]
    let pair: Bool                    // two files (…_00_… + …_10_…) instead of one side-by-side file
    let poly: [Double]                // r(θ°) ∝ c0 + c1 θ + … + c4 θ⁴
    let t: [Double]                   // IMU sample times, seconds of video
    let gyro: [SIMD3<Double>]         // rad/s, camera axes
    let acc: [SIMD3<Double>]          // g, camera axes
    private var tables: [String: StabTable] = [:]
    private let lock = NSLock()

    init(camera: String, lenses: [PanoLens], pair: Bool, poly: [Double], t: [Double], gyro: [SIMD3<Double>], acc: [SIMD3<Double>]) {
        self.camera = camera; self.lenses = lenses; self.pair = pair; self.poly = poly
        self.t = t; self.gyro = gyro; self.acc = acc
    }

    var hasIMU: Bool { t.count > 10 }

    /// Rotation that turns a view direction into a camera direction at video time `time`.
    func stabilization(at time: Double, lockDirection: Bool, smooth: Double) -> simd_quatf {
        guard hasIMU else { return simd_quatf(angle: 0, axis: [0, 1, 0]) }
        let key = "\(lockDirection)|\(round3(smooth))"
        lock.lock()
        let table: StabTable
        if let tb = tables[key] { table = tb } else {
            table = Stabilizer.compute(self, lockDirection: lockDirection, smooth: smooth)
            tables[key] = table
        }
        lock.unlock()
        return table.value(at: time)
    }
}

/// Rotations on a uniform time grid.
struct StabTable {
    let t0: Double, rate: Double
    let q: [simd_quatf]
    func value(at time: Double) -> simd_quatf {
        guard !q.isEmpty else { return simd_quatf(angle: 0, axis: [0, 1, 0]) }
        let x = (time - t0) * rate
        let i = Int(floor(x))
        if i < 0 { return q[0] }
        if i >= q.count - 1 { return q[q.count - 1] }
        var q1 = q[i + 1]
        if simd_dot(q[i], q1) < 0 { q1 = -q1 }
        return simd_slerp(q[i], q1, Float(x - Double(i)))
    }
}

// MARK: - reading the file

enum InsvReader {
    static let magic = Array("8db42d694ccc418790edff439fe026bf".utf8)

    static func isInsv(_ url: URL) -> Bool { url.pathExtension.lowercased() == "insv" }

    /// The other lens of a two-file recording (…_00_… -> …_10_…), if it exists.
    static func companion(of url: URL) -> URL? {
        let name = url.lastPathComponent
        guard name.contains("_00_") else { return nil }
        let other = url.deletingLastPathComponent().appendingPathComponent(name.replacingOccurrences(of: "_00_", with: "_10_"))
        return FileManager.default.fileExists(atPath: other.path) ? other : nil
    }

    /// Files to hide on import: the second lens of a pair and the low-res previews.
    static func isSecondary(_ url: URL) -> Bool {
        guard isInsv(url) else { return false }
        let name = url.lastPathComponent
        if name.hasPrefix("LRV_") { return true }
        if name.contains("_10_") {
            let first = url.deletingLastPathComponent().appendingPathComponent(name.replacingOccurrences(of: "_10_", with: "_00_"))
            return FileManager.default.fileExists(atPath: first.path)
        }
        return false
    }

    static func records(_ url: URL) throws -> [Int: Data] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let size = try fh.seekToEnd()
        guard size > 72 else { throw err("file troppo corto") }
        try fh.seek(toOffset: size - 72)
        let foot = [UInt8](fh.readData(ofLength: 72))
        guard Array(foot[40..<72]) == magic else { throw err("non è un file Insta360") }
        let tsize = UInt64(u32(foot, 32))
        guard tsize < size, tsize > 72 else { throw err("metadati Insta360 danneggiati") }
        try fh.seek(toOffset: size - tsize)
        let all = [UInt8](fh.readData(ofLength: Int(tsize)))
        var out: [Int: Data] = [:]
        var end = all.count - 72
        while end > 6 {
            let id = Int(all[end - 6]) | Int(all[end - 5]) << 8
            let len = Int(u32(all, end - 4))
            let start = end - 6 - len
            guard len >= 0, start >= 0 else { break }
            out[id] = Data(all[start..<(end - 6)])
            end = start
        }
        return out
    }

    static func load(_ url: URL, fileWidth: Double, fileHeight: Double) throws -> PanoData {
        let recs = try records(url)
        guard let infoData = recs[0x101] else { throw err("metadati Insta360 mancanti") }
        let info = Proto(infoData)
        let camera = info.string(2) ?? "Insta360"
        let pair = fileWidth < fileHeight * 1.5
        let lensSize = pair ? fileWidth : fileHeight

        // lens calibration ("offset", version 1): n_[radius_cx_cy_yaw_pitch_roll]×n_width_height_flags
        var lenses: [PanoLens] = []
        var poly: [Double] = [0, 1, 0, 0, 0]   // fallback: equidistant
        if let off = info.string(5)?.split(separator: "_").compactMap({ Double($0) }), off.count >= 10, off[0] == 2 {
            let n = 2, w = off[1 + n * 6], flags = Int(off[3 + n * 6])
            // the calibration frame is 3040 px per lens; files are a centred 2880 crop of it, maybe scaled down
            let crop = Proto(info.bytes(27) ?? Data())
            let src = Double(crop.int(1) ?? 3040), dst = Double(crop.int(3) ?? 2880)
            let scale = lensSize / dst
            for i in 0..<n {
                let b = 1 + i * 6
                let r = off[b], cx = off[b + 1] - Double(i) * w / Double(n), cy = off[b + 2]
                let yaw = off[b + 3], pitch = off[b + 4], roll = off[b + 5]
                var lens = PanoLens(cx: (cx - (src - dst) / 2) * scale, cy: (cy - (src - dst) / 2) * scale, r100: r * scale,
                                    alpha: i == 0 ? 90 + (roll + 180) : -90 + roll,
                                    rotation: (i == 0 ? matrix_identity_double3x3 : rotY(180)) * rotY(-yaw) * rotX(pitch))
                if !pair && i == 1 { lens.xOffset = lensSize }
                lenses.append(lens)
            }
            if let p = lensPolynomials[flags & 0xff] { poly = p }
        } else {
            // no calibration: assume centred lenses of a typical 200° pair
            let r = lensSize / 2 * 0.975
            lenses = [PanoLens(cx: lensSize / 2, cy: lensSize / 2, r100: r, alpha: 90, rotation: matrix_identity_double3x3),
                      PanoLens(cx: lensSize / 2, cy: lensSize / 2, r100: r, alpha: -90, rotation: rotY(180), xOffset: pair ? 0 : lensSize)]
        }

        // IMU
        var ts: [Double] = [], gy: [SIMD3<Double>] = [], ac: [SIMD3<Double>] = []
        if let g = recs[0x300] {
            let raw = (info.int(62) ?? 0) != 0
            let fft = Double(info.int(24) ?? 0)
            let gyroOffset = (info.int(29) ?? 0) != 0 ? (info.double(28) ?? 0) / 1000 : 0
            let cfg = Proto(info.bytes(65) ?? Data())
            let accRange = Double(cfg.int(1) ?? 16), gyroRange = Double(cfg.int(2) ?? 2000)
            let bytes = [UInt8](g)
            let item = raw ? 20 : 56
            let n = bytes.count / item
            ts.reserveCapacity(n); gy.reserveCapacity(n); ac.reserveCapacity(n)
            bytes.withUnsafeBytes { p in
                for i in 0..<n {
                    let o = i * item
                    let stamp = Double(p.loadUnaligned(fromByteOffset: o, as: UInt64.self))
                    var a = SIMD3<Double>(), w = SIMD3<Double>()
                    if raw {
                        func v(_ k: Int) -> Double { Double(p.loadUnaligned(fromByteOffset: o + 8 + k * 2, as: UInt16.self)) - 32768 }
                        a = SIMD3(v(0), v(1), v(2)) * (accRange / 32768)
                        w = SIMD3(v(3), v(4), v(5)) * (gyroRange / 32768 * .pi / 180)
                        ts.append((stamp - fft) / 1_000_000 - gyroOffset)
                    } else {
                        func v(_ k: Int) -> Double { p.loadUnaligned(fromByteOffset: o + 8 + k * 8, as: Double.self) }
                        a = SIMD3(v(0), v(1), v(2))
                        w = SIMD3(v(3), v(4), v(5))
                        ts.append((stamp - fft) / 1000 - gyroOffset)
                    }
                    // IMU axes -> camera axes (x right, y up, z = lens 0), found by matching gyro rotation to the picture
                    ac.append(SIMD3(a.z, -a.x, -a.y))
                    gy.append(SIMD3(w.z, -w.x, -w.y))
                }
            }
            // keep samples in strictly increasing time order (a few files repeat a timestamp)
            if zip(ts, ts.dropFirst()).contains(where: { $0 >= $1 }) {
                let order = ts.indices.sorted { ts[$0] < ts[$1] }
                var nts: [Double] = [], ngy: [SIMD3<Double>] = [], nac: [SIMD3<Double>] = []
                for idx in order {
                    if let last = nts.last, ts[idx] <= last + 1e-7 { continue }
                    nts.append(ts[idx]); ngy.append(gy[idx]); nac.append(ac[idx])
                }
                ts = nts; gy = ngy; ac = nac
            }
        }
        return PanoData(camera: camera, lenses: lenses, pair: pair, poly: poly, t: ts, gyro: gy, acc: ac)
    }

    /// r(θ) polynomials per lens type (θ in degrees), from the public reference above.
    static let lensPolynomials: [Int: [Double]] = [
        33: [0.0, 0.024134, -7.4557e-05, 2.0846e-06, -1.4576e-08],     // ONE R 360 / ONE X2
        38: [0.0, 0.024336, -7.55532e-05, 2.13171e-06, -1.5040305e-08],
        40: [0.0, 0.0259398, -7.3377467e-05, 2.2925e-06, -1.7776969e-08],
    ]

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    private static func err(_ s: String) -> NSError { NSError(domain: "EliteStudio", code: 360, userInfo: [NSLocalizedDescriptionKey: s]) }
}

/// Minimal protobuf reader: top-level fields of one message (last value wins).
struct Proto {
    private var fields: [Int: (wire: Int, value: UInt64, data: Data)] = [:]
    init(_ d: Data) {
        let b = [UInt8](d)
        var i = 0
        func varint() -> UInt64? {
            var r: UInt64 = 0, s: UInt64 = 0
            while i < b.count {
                let c = b[i]; i += 1
                if s < 64 { r |= UInt64(c & 0x7f) << s }
                s += 7
                if c < 0x80 { return r }
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { break }
            let fn = Int(key >> 3), wt = Int(key & 7)
            switch wt {
            case 0: guard let v = varint() else { return }; fields[fn] = (0, v, Data())
            case 1: guard i + 8 <= b.count else { return }
                var v: UInt64 = 0; for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }; i += 8; fields[fn] = (1, v, Data())
            case 2: guard let l = varint(), i + Int(l) <= b.count else { return }
                fields[fn] = (2, 0, Data(b[i..<(i + Int(l))])); i += Int(l)
            case 5: guard i + 4 <= b.count else { return }
                var v: UInt64 = 0; for k in 0..<4 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }; i += 4; fields[fn] = (5, v, Data())
            default: return
            }
        }
    }
    func int(_ f: Int) -> Int? { fields[f].flatMap { $0.wire == 0 ? Int(truncatingIfNeeded: $0.value) : nil } }
    func double(_ f: Int) -> Double? { fields[f].flatMap { $0.wire == 1 ? Double(bitPattern: $0.value) : nil } }
    func bytes(_ f: Int) -> Data? { fields[f].flatMap { $0.wire == 2 ? $0.data : nil } }
    func string(_ f: Int) -> String? { bytes(f).flatMap { String(data: $0, encoding: .utf8) } }
}

func rotX(_ deg: Double) -> simd_double3x3 {
    let a = deg * .pi / 180, c = cos(a), s = sin(a)
    return simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, c, -s), SIMD3(0, s, c)])
}
func rotY(_ deg: Double) -> simd_double3x3 {
    let a = deg * .pi / 180, c = cos(a), s = sin(a)
    return simd_double3x3(rows: [SIMD3(c, 0, s), SIMD3(0, 1, 0), SIMD3(-s, 0, c)])
}
func rotZ(_ deg: Double) -> simd_double3x3 {
    let a = deg * .pi / 180, c = cos(a), s = sin(a)
    return simd_double3x3(rows: [SIMD3(c, -s, 0), SIMD3(s, c, 0), SIMD3(0, 0, 1)])
}

// MARK: - stabilization (horizon lock + smoothed heading, like FlowState)

enum Stabilizer {
    static let rate = 200.0                      // table resolution (Hz)
    static let horizonSmoothing = 2.0            // s: how slowly the horizon estimate follows the accelerometer

    static func compute(_ d: PanoData, lockDirection: Bool, smooth: Double) -> StabTable {
        let n = d.t.count
        // 1. integrate the gyro: camera -> world (world = camera at the first sample)
        var q = [simd_quatd](repeating: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), count: n)
        for i in 1..<n {
            let dt = min(0.05, max(0, d.t[i] - d.t[i - 1]))
            let w = (d.gyro[i] + d.gyro[i - 1]) * 0.5
            let ang = simd_length(w) * dt
            let step = ang > 1e-12 ? simd_quatd(angle: ang, axis: w / simd_length(w)) : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
            q[i] = simd_normalize(q[i - 1] * step)
        }
        // 2. resample on a uniform grid
        let t0 = d.t[0], t1 = d.t[n - 1]
        let m = max(2, Int((t1 - t0) * rate) + 1)
        var gq = [simd_quatd](), up = [SIMD3<Double>]()
        gq.reserveCapacity(m); up.reserveCapacity(m)
        var j = 0
        for k in 0..<m {
            let t = t0 + Double(k) / rate
            while j < n - 2 && d.t[j + 1] < t { j += 1 }
            let span = d.t[j + 1] - d.t[j]
            let f = span > 0 ? min(1, max(0, (t - d.t[j]) / span)) : 0
            var qB = q[j + 1]
            if simd_dot(q[j], qB) < 0 { qB = -qB }
            let r = simd_slerp(q[j], qB, f)
            gq.append(r)
            // the accelerometer reads gravity (down): "up" is the opposite, rotated into the world frame
            up.append(r.act(-(d.acc[j] * (1 - f) + d.acc[j + 1] * f)))
        }
        // 3. horizon: a long average of "up" cancels hand movement, and follows slow gyro drift
        let ups = blur3(up, width: Int(horizonSmoothing * 2 * rate)).map { simd_length($0) > 1e-9 ? simd_normalize($0) : SIMD3(0, 1, 0) }
        // 4. level camera orientation and its heading
        var level = [simd_quatd](), heading = [SIMD3<Double>]()
        level.reserveCapacity(m); heading.reserveCapacity(m)
        for k in 0..<m {
            // (from:to: is undefined for opposite vectors: camera started upside down)
            let lq = simd_dot(ups[k], SIMD3(0, 1, 0)) < -0.9999 ? simd_quatd(angle: .pi, axis: SIMD3(1, 0, 0))
                                                               : simd_quatd(from: ups[k], to: SIMD3(0, 1, 0))
            let c = simd_normalize(lq * gq[k])
            level.append(c)
            let f = c.act(SIMD3(0, 0, 1))
            let hLen = sqrt(f.x * f.x + f.z * f.z)
            heading.append(hLen > 1e-6 ? SIMD3(f.x / hLen, 0, f.z / hLen) : (heading.last ?? SIMD3(0, 0, 1)))
        }
        let hs = blur3(heading, width: max(1, Int(max(0.05, smooth) * 2 * rate)))
        let k0 = min(m - 1, max(0, Int(-t0 * rate)))  // video time 0
        let lockYaw = atan2(hs[k0].x, hs[k0].z)
        var out = [simd_quatf]()
        out.reserveCapacity(m)
        for k in 0..<m {
            let yaw = lockDirection ? lockYaw : atan2(hs[k].x, hs[k].z)
            let b = simd_quatd(angle: yaw, axis: SIMD3(0, 1, 0))
            let s = simd_normalize(level[k].inverse * b)
            var qVal = simd_quatf(ix: Float(s.imag.x), iy: Float(s.imag.y), iz: Float(s.imag.z), r: Float(s.real))
            if let prev = out.last, simd_dot(prev, qVal) < 0 {
                qVal = -qVal
            }
            out.append(qVal)
        }
        return StabTable(t0: t0, rate: rate, q: out)
    }

    /// Three box-filter passes ≈ a Gaussian with σ ≈ width / 2.
    static func blur3(_ v: [SIMD3<Double>], width: Int) -> [SIMD3<Double>] {
        var a = v
        let r = max(1, width / 2)
        guard a.count > 2 else { return a }
        for _ in 0..<3 {
            var pre = [SIMD3<Double>](repeating: .zero, count: a.count + 1)
            for i in 0..<a.count { pre[i + 1] = pre[i] + a[i] }
            var b = a
            for i in 0..<a.count {
                let lo = max(0, i - r), hi = min(a.count - 1, i + r)
                b[i] = (pre[hi + 1] - pre[lo]) / Double(hi - lo + 1)
            }
            a = b
        }
        return a
    }
}

// MARK: - reframing (stored on the clip)

/// One view: where the virtual camera looks and how wide.
struct PanoView: Hashable, Codable {
    var yaw = 0.0          // degrees, + = right
    var pitch = 0.0        // degrees, + = up
    var roll = 0.0
    var fov = 100.0        // horizontal field of view, degrees
    var distance = 0.0     // 0 = normal lens, 1 = wide/stereographic (little planet when looking down)

    static func lerp(_ a: PanoView, _ b: PanoView, _ f: Double) -> PanoView {
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        return PanoView(yaw: l(a.yaw, b.yaw), pitch: l(a.pitch, b.pitch), roll: l(a.roll, b.roll), fov: l(a.fov, b.fov), distance: l(a.distance, b.distance))
    }
}

struct PanoKey: Hashable, Codable {
    var t: Double          // seconds inside the media file (so cuts and trims keep keys in place)
    var view: PanoView
}

struct Reframe: Hashable {
    var view = PanoView()
    var keys: [PanoKey] = []        // sorted by t; when present they drive the view
    var stabilize = true
    var lockDirection = false
    var smooth = 1.0                // seconds: how gently the view follows the camera's turns

    func view(atMedia t: Double) -> PanoView {
        guard let first = keys.first else { return view }
        if keys.count == 1 || t <= first.t { return first.view }
        guard let last = keys.last, t < last.t else { return keys.last!.view }
        let i = keys.lastIndex { $0.t <= t } ?? 0
        let a = keys[i], b = keys[i + 1]
        let f = (t - a.t) / max(1e-6, b.t - a.t)
        return PanoView.lerp(a.view, b.view, f * f * (3 - 2 * f))   // ease in/out
    }

    /// Changes the view at media time t: moves the key there (or the only view when there are no keys).
    mutating func set(_ v: PanoView, atMedia t: Double, tolerance: Double) {
        if keys.isEmpty { view = v; return }
        if let i = keys.firstIndex(where: { abs($0.t - t) <= tolerance }) { keys[i].view = v } else {
            keys.append(PanoKey(t: t, view: v)); keys.sort { $0.t < $1.t }
        }
    }
}

extension Reframe: Codable {
    enum K: String, CodingKey { case yaw, pitch, roll, fov, distance, keys, stabilize, lockDirection, smooth }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let def = PanoView()
        view = PanoView(yaw: c.get(.yaw, def.yaw), pitch: c.get(.pitch, def.pitch), roll: c.get(.roll, def.roll),
                        fov: c.get(.fov, def.fov), distance: c.get(.distance, def.distance))
        keys = c.get(.keys, [PanoKey]()).sorted { $0.t < $1.t }
        stabilize = c.get(.stabilize, true); lockDirection = c.get(.lockDirection, false); smooth = c.get(.smooth, 1.0)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(round3(view.yaw), forKey: .yaw); try c.encode(round3(view.pitch), forKey: .pitch)
        if view.roll != 0 { try c.encode(round3(view.roll), forKey: .roll) }
        try c.encode(round3(view.fov), forKey: .fov)
        if view.distance != 0 { try c.encode(round3(view.distance), forKey: .distance) }
        if !keys.isEmpty { try c.encode(keys, forKey: .keys) }
        try c.encode(stabilize, forKey: .stabilize)
        if lockDirection { try c.encode(true, forKey: .lockDirection) }
        if smooth != 1 { try c.encode(smooth, forKey: .smooth) }
    }
}
