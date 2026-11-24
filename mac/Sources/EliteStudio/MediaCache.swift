import Foundation
import AVFoundation
import AppKit

/// Loaded AVFoundation objects for a media file.
struct MediaRuntime {
    let asset: AVURLAsset
    var asset2: AVURLAsset? = nil
    let video: AVAssetTrack?
    let audio: AVAssetTrack?
    let transform: CGAffineTransform
    let natural: CGSize
    let videoRange: CMTimeRange?
    let audioRange: CMTimeRange?
    var lens2: AVAssetTrack? = nil        // 360 clip recorded as two files: the second lens
    var lens2Range: CMTimeRange? = nil
    var pano: PanoData? = nil
    var frameRate: Double = 0             // 360 clips: the gyro is sampled at the shown frame's own time
}

/// Thumbnails, waveforms and loaded assets, keyed by media id.
@MainActor
final class MediaCache: ObservableObject {
    static let shared = MediaCache()

    private(set) var runtimes: [ID: MediaRuntime] = [:]
    private(set) var strips: [ID: [(time: Double, image: CGImage)]] = [:]
    private(set) var peaks: [ID: [Float]] = [:]          // 100 values per second, 0...1
    @Published private(set) var revision = 0               // bumps when thumbnails/waveforms arrive
    private var loading: Set<ID> = []
    private(set) var failed: Set<ID> = []

    nonisolated static let peaksPerSecond = 100.0

    static let videoExtensions = ["mov", "mp4", "m4v", "3gp", "insv"]
    static let audioExtensions = ["mp3", "wav", "m4a", "aac", "aif", "aiff", "caf"]

    static func isSupported(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        if InsvReader.isSecondary(url) { return false }
        return videoExtensions.contains(e) || audioExtensions.contains(e) || StillMaker.isImage(url)
    }

    /// Reads a file and returns the bin item plus its runtime info.
    /// .insv files are MP4 inside, but AVFoundation only opens them when told so.
    nonisolated static func asset(_ url: URL) -> AVURLAsset {
        var o: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        if InsvReader.isInsv(url) { o[AVURLAssetOverrideMIMETypeKey] = "video/mp4" }
        return AVURLAsset(url: url, options: o)
    }

    func probe(_ url: URL) async throws -> MediaItem {
        let asset = Self.asset(url)
        let duration = try await asset.load(.duration).seconds
        let v = try await asset.loadTracks(withMediaType: .video).first
        let a = try await asset.loadTracks(withMediaType: .audio).first
        var w = 0.0, h = 0.0
        if let v {
            let (nat, tr) = try await v.load(.naturalSize, .preferredTransform)
            let r = CGRect(origin: .zero, size: nat).applying(tr)
            w = abs(r.width); h = abs(r.height)
        }
        guard duration.isFinite, duration > 0, v != nil || a != nil else {
            throw NSError(domain: "EliteStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent): formato non supportato"])
        }
        var item = MediaItem(url: url, name: url.lastPathComponent, duration: duration,
                             hasVideo: v != nil, hasAudio: a != nil, width: w, height: h)
        if InsvReader.isInsv(url), v != nil, (try? InsvReader.records(url)) != nil {
            // a 360 clip is shown reframed: treat it as a 16:9 picture
            item.pano = true; item.width = 1920; item.height = 1080
        }
        return item
    }

    /// Loads tracks for an item (once) and starts thumbnail/waveform generation in the background.
    func prepare(_ item: MediaItem, background: Bool = true) async -> MediaRuntime? {
        if let r = runtimes[item.id] { return r }
        let asset = Self.asset(item.url)
        do {
            let v = try await asset.loadTracks(withMediaType: .video).first
            let a = try await asset.loadTracks(withMediaType: .audio).first
            var tr = CGAffineTransform.identity, nat = CGSize.zero
            var vr: CMTimeRange?, ar: CMTimeRange?
            if let v { (nat, tr, vr) = try await v.load(.naturalSize, .preferredTransform, .timeRange) }
            if let a { ar = try await a.load(.timeRange) }
            var rt = MediaRuntime(asset: asset, video: v, audio: a, transform: tr, natural: nat, videoRange: vr, audioRange: ar)
            if item.pano {
                if let v, let fps = try? await v.load(.nominalFrameRate), fps > 0 { rt.frameRate = Double(fps) }
                if let other = InsvReader.companion(of: item.url) {
                    let a2 = Self.asset(other)
                    if let v2 = try await a2.loadTracks(withMediaType: .video).first {
                        rt.asset2 = a2
                        rt.lens2 = v2; rt.lens2Range = try await v2.load(.timeRange)
                    }
                }
                let url = item.url, size = nat
                rt.pano = try? await Task.detached { try InsvReader.load(url, fileWidth: size.width, fileHeight: size.height) }.value
                if rt.pano == nil { NSLog("EliteStudio: no 360 metadata in \(url.lastPathComponent)") }
            }
            runtimes[item.id] = rt
            if background { startBackgroundWork(item, rt) }
            return rt
        } catch {
            NSLog("EliteStudio: cannot load \(item.url.path): \(error)")
            failed.insert(item.id)
            return nil
        }
    }

    func forget(_ id: ID) {
        runtimes[id] = nil; strips[id] = nil; peaks[id] = nil; failed.remove(id)
    }

    // MARK: - lookups used by the timeline

    func thumbnail(_ id: ID, at t: Double) -> CGImage? {
        guard let s = strips[id], !s.isEmpty else { return nil }
        var lo = 0, hi = s.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if s[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        return s[lo].image
    }

    func posterFrame(_ id: ID) -> CGImage? {
        guard let s = strips[id], !s.isEmpty else { return nil }
        return s[min(s.count - 1, s.count / 5)].image
    }

    func peak(_ id: ID, from t0: Double, to t1: Double) -> Float {
        guard let p = peaks[id], !p.isEmpty else { return 0 }
        let a = max(0, Int(t0 * Self.peaksPerSecond))
        let b = min(p.count - 1, max(a, Int(t1 * Self.peaksPerSecond)))
        if a > b { return 0 }
        var m: Float = 0
        for i in a...b where p[i] > m { m = p[i] }
        return m
    }

    func hasPeaks(_ id: ID) -> Bool { peaks[id] != nil }

    // MARK: - background generation

    private func startBackgroundWork(_ item: MediaItem, _ rt: MediaRuntime) {
        guard !loading.contains(item.id) else { return }
        loading.insert(item.id)
        let id = item.id, dur = item.duration, asset = rt.asset
        if rt.video != nil {
            Task.detached(priority: .utility) {
                let frames = await Self.makeStrip(asset: asset, duration: dur)
                await MainActor.run {
                    self.strips[id] = frames
                    self.revision += 1
                }
            }
        }
        if let audio = rt.audio {
            Task.detached(priority: .utility) {
                let p = Self.makePeaks(asset: asset, track: audio)
                await MainActor.run {
                    self.peaks[id] = p
                    self.revision += 1
                }
            }
        }
    }

    nonisolated private static func makeStrip(asset: AVURLAsset, duration: Double) async -> [(time: Double, image: CGImage)] {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 200, height: 200)
        let tol = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let step = max(1.0, duration / 150.0)
        var times: [CMTime] = []
        var t = 0.0
        while t < duration { times.append(CMTime(seconds: t, preferredTimescale: 600)); t += step }
        var out: [(Double, CGImage)] = []
        for await r in gen.images(for: times) {
            if let img = try? r.image {
                out.append((r.requestedTime.seconds, img))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    nonisolated private static func makePeaks(asset: AVURLAsset, track: AVAssetTrack) -> [Float] {
        let rate = 8000.0
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: rate,
        ])
        guard reader.canAdd(out) else { return [] }
        reader.add(out)
        guard reader.startReading() else { return [] }
        let per = Int(rate / peaksPerSecond)
        var peaks: [Float] = []
        var cur: Int32 = 0, n = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
                  let ptr else { continue }
            let count = len / 2
            ptr.withMemoryRebound(to: Int16.self, capacity: count) { s in
                for i in 0..<count {
                    let v = abs(Int32(s[i]))
                    if v > cur { cur = v }
                    n += 1
                    if n == per { peaks.append(Float(cur) / 32768); cur = 0; n = 0 }
                }
            }
        }
        if n > 0 { peaks.append(Float(cur) / 32768) }
        // gentle curve so quiet speech is still visible
        let mx = max(peaks.max() ?? 1, 0.05)
        return peaks.map { sqrt($0 / mx) }
    }
}
