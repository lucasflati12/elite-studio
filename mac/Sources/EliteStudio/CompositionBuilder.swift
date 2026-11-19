import AVFoundation
import AppKit

/// One piece of a timeline clip placed into a composition track.
struct PlacedSegment {
    let clipID: ID
    let lane: Int
    let start: Int64      // ticks (1/600 s)
    let end: Int64
}

struct BuiltComposition {
    let composition: AVMutableComposition
    let videoTrackIDs: [Int: CMPersistentTrackID]
    let audioTrackIDs: [Int: CMPersistentTrackID]
    let video: [PlacedSegment]
    let audio: [PlacedSegment]
    var lensBTrackIDs: [Int: CMPersistentTrackID] = [:]   // second lens of two-file 360 clips, per lane
    var hasVideo: Bool { !video.isEmpty }
}

/// Turns the timeline into an AVComposition + video composition + audio mix.
@MainActor
enum CompositionBuilder {
    static let timescale: CMTimeScale = 600

    static func ticks(_ s: Double) -> Int64 { Int64((s * Double(timescale)).rounded()) }
    static func time(_ t: Int64) -> CMTime { CMTime(value: t, timescale: timescale) }

    static func build(_ p: Project, cache: MediaCache) -> BuiltComposition {
        let comp = AVMutableComposition()
        var vIDs: [Int: CMPersistentTrackID] = [:], aIDs: [Int: CMPersistentTrackID] = [:]
        var vSegs: [PlacedSegment] = [], aSegs: [PlacedSegment] = []
        var lensB: [Int: CMPersistentTrackID] = [:]

        for lane in p.lanes {
            let clips = p.clips.filter { $0.track == lane && !$0.isTitle }.sorted { $0.start < $1.start }

            if !p.tracks.videoHidden[lane],
               let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                var cursor: Int64 = 0
                for c in clips {
                    guard let m = p.media(c.mediaID), let rt = cache.runtimes[m.id], let src = rt.video, let range = rt.videoRange else { continue }
                    if let seg = insert(c, src: src, available: range, into: track, cursor: &cursor, lane: lane) { vSegs.append(seg) }
                }
                if vSegs.contains(where: { $0.lane == lane }) { vIDs[lane] = track.trackID } else { comp.removeTrack(track) }
            }

            // 360 clips recorded as two files: the second lens goes on its own track, at the same times
            if !p.tracks.videoHidden[lane], clips.contains(where: { p.media($0.mediaID).flatMap { cache.runtimes[$0.id]?.lens2 } != nil }),
               let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                var cursor: Int64 = 0, any = false
                for c in clips {
                    guard let m = p.media(c.mediaID), let rt = cache.runtimes[m.id], let src = rt.lens2, let range = rt.lens2Range else { continue }
                    if insert(c, src: src, available: range, into: track, cursor: &cursor, lane: lane) != nil { any = true }
                }
                if any { lensB[lane] = track.trackID } else { comp.removeTrack(track) }
            }

            if !p.tracks.audioMuted[lane],
               let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                var cursor: Int64 = 0
                for c in clips {
                    guard let m = p.media(c.mediaID), let rt = cache.runtimes[m.id], let src = rt.audio, let range = rt.audioRange else { continue }
                    if let seg = insert(c, src: src, available: range, into: track, cursor: &cursor, lane: lane) { aSegs.append(seg) }
                }
                if aSegs.contains(where: { $0.lane == lane }) { aIDs[lane] = track.trackID } else { comp.removeTrack(track) }
            }
        }
        return BuiltComposition(composition: comp, videoTrackIDs: vIDs, audioTrackIDs: aIDs, video: vSegs, audio: aSegs, lensBTrackIDs: lensB)
    }

    private static func insert(_ c: Clip, src: AVAssetTrack, available: CMTimeRange, into track: AVMutableCompositionTrack,
                               cursor: inout Int64, lane: Int) -> PlacedSegment? {
        var s = ticks(c.start)
        let e = ticks(c.end)
        if s < cursor { s = cursor }
        let srcStart = time(ticks(c.sourceIn))
        let availEnd = available.end
        // the clip reads `speed` seconds of file per second of timeline
        var srcDur = time(Int64((Double(e - s) * c.speed).rounded()))
        if CMTimeCompare(CMTimeAdd(srcStart, srcDur), availEnd) > 0 { srcDur = CMTimeSubtract(availEnd, srcStart) }
        guard srcDur.seconds > 0.001 else { return nil }
        let dur = c.speed == 1 ? srcDur : time(Int64((srcDur.seconds / c.speed * Double(timescale)).rounded()))
        do {
            if s > cursor { track.insertEmptyTimeRange(CMTimeRange(start: time(cursor), end: time(s))) }
            try track.insertTimeRange(CMTimeRange(start: srcStart, duration: srcDur), of: src, at: time(s))
            if c.speed != 1 { track.scaleTimeRange(CMTimeRange(start: time(s), duration: srcDur), toDuration: dur) }
            let realEnd = s + Int64((dur.seconds * Double(timescale)).rounded())
            cursor = realEnd
            return PlacedSegment(clipID: c.id, lane: lane, start: s, end: realEnd)
        } catch {
            NSLog("EliteStudio: insert failed for clip \(c.id), mediaType \(src.mediaType.rawValue), trackID \(track.trackID), srcRange: \(srcStart.seconds)...\(srcDur.seconds), avail: \(available.start.seconds)...\(available.duration.seconds): \(error)")
            return nil
        }
    }

    // MARK: - video composition

    static func transform(for c: Clip, runtime rt: MediaRuntime, frame: CGSize) -> CGAffineTransform {
        let r = CGRect(origin: .zero, size: rt.natural).applying(rt.transform)
        let dw = abs(r.width), dh = abs(r.height)
        guard dw > 0, dh > 0 else { return .identity }
        let fit = c.fill ? max(frame.width / dw, frame.height / dh) : min(frame.width / dw, frame.height / dh)
        let s = fit * CGFloat(c.scale)
        let tx = (frame.width - dw * s) / 2 + CGFloat(c.offsetX) * frame.width
        let ty = (frame.height - dh * s) / 2 + CGFloat(c.offsetY) * frame.height
        return rt.transform
            .concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY))
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    /// `burnOverlays`: export only. The viewer draws titles and logo itself on top of the video.
    static func videoComposition(_ b: BuiltComposition, project p: Project, cache: MediaCache, burnOverlays: Bool = false) -> AVMutableVideoComposition? {
        guard b.hasVideo else { return nil }
        let frame = p.settings.size
        let total = b.composition.duration
        let totalTicks = Int64((total.seconds * Double(timescale)).rounded())
        var bounds = Set<Int64>([0])
        for s in b.video { bounds.insert(s.start); bounds.insert(s.end) }
        let sorted = bounds.filter { $0 < totalTicks }.sorted()
        let clipsByID = Dictionary(uniqueKeysWithValues: p.clips.map { ($0.id, $0) })
        let hasPano = b.video.contains { s in clipsByID[s.clipID].flatMap { p.media($0.mediaID) }.flatMap { cache.runtimes[$0.id]?.pano } != nil }
        // 360 clips and captions need the GPU compositor (the "negativo" captions read the video under them)
        if hasPano || p.visibleCaptions != nil || p.clips.contains(where: { !$0.isTitle && $0.effects.needsGPU }) {
            return panoComposition(b, project: p, cache: cache, bounds: sorted, total: total, overlays: burnOverlays ? OverlayTrack(project: p) : nil)
        }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        for (i, s) in sorted.enumerated() {
            let startT = time(s)
            let endT = i + 1 < sorted.count ? time(sorted[i + 1]) : total
            guard CMTimeCompare(endT, startT) > 0 else { continue }
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = CMTimeRange(start: startT, end: endT)
            ins.backgroundColor = NSColor.black.cgColor
            var layers: [AVMutableVideoCompositionLayerInstruction] = []
            let mid = s + 1
            for lane in p.lanes.reversed() {
                guard let seg = b.video.first(where: { $0.lane == lane && $0.start <= mid && mid < $0.end }),
                      let tid = b.videoTrackIDs[lane], let ct = b.composition.track(withTrackID: tid),
                      let c = clipsByID[seg.clipID], let m = p.media(c.mediaID), let rt = cache.runtimes[m.id] else { continue }
                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: ct)
                var tr = transform(for: c, runtime: rt, frame: frame)
                // an untouched frame takes a pass-through path that comes out white once overlays are burned in
                if tr.isIdentity { tr = CGAffineTransform(translationX: 0.0001, y: 0) }
                li.setTransform(tr, at: startT)
                li.setOpacity(Float(c.opacity), at: startT)
                layers.append(li)
            }
            ins.layerInstructions = layers
            instructions.append(ins)
        }
        let vc = AVMutableVideoComposition()
        vc.renderSize = frame
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, p.settings.fps)))
        vc.instructions = instructions
        // tone-map iPhone HDR to standard video so preview and export look the same everywhere
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return vc
    }

    /// Same layout as above, drawn by `PanoCompositor` so 360 clips can be reframed and captions drawn.
    private static func panoComposition(_ b: BuiltComposition, project p: Project, cache: MediaCache, bounds sorted: [Int64], total: CMTime,
                                        overlays: OverlayTrack?) -> AVMutableVideoComposition {
        let frame = p.settings.size
        let clipsByID = Dictionary(uniqueKeysWithValues: p.clips.map { ($0.id, $0) })
        let captions = p.visibleCaptions.map { CaptionTrack(captions: $0, style: p.captionStyle, frame: frame) }
        var instructions: [CompInstruction] = []
        for (i, s) in sorted.enumerated() {
            let startT = time(s)
            let endT = i + 1 < sorted.count ? time(sorted[i + 1]) : total
            guard CMTimeCompare(endT, startT) > 0 else { continue }
            var layers: [CompLayer] = []
            let mid = s + 1
            for lane in p.lanes {   // bottom to top
                guard let seg = b.video.first(where: { $0.lane == lane && $0.start <= mid && mid < $0.end }),
                      let tid = b.videoTrackIDs[lane], let c = clipsByID[seg.clipID], let m = p.media(c.mediaID), let rt = cache.runtimes[m.id] else { continue }
                var l = CompLayer(kind: .flat, trackID: tid)
                l.opacity = Float(c.opacity)
                l.clip = c
                var neutral = c; neutral.scale = 1; neutral.offsetX = 0; neutral.offsetY = 0
                if let pano = rt.pano {
                    l.kind = .pano
                    l.pano = pano
                    l.reframe = c.reframe ?? Reframe()
                    l.clipStart = Double(seg.start) / Double(timescale)
                    l.sourceIn = c.sourceIn; l.speed = c.speed
                    if rt.lens2 != nil, let t2 = b.lensBTrackIDs[lane] { l.trackID2 = t2 }
                } else {
                    l.transform = transform(for: neutral, runtime: rt, frame: frame)
                }
                layers.append(l)
            }
            instructions.append(CompInstruction(timeRange: CMTimeRange(start: startT, end: endT), layers: layers, captions: captions, overlays: overlays))
        }
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = PanoCompositor.self
        vc.renderSize = frame
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, p.settings.fps)))
        vc.instructions = instructions
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return vc
    }

    static func audioMix(_ b: BuiltComposition, project p: Project) -> AVMutableAudioMix? {
        guard !b.audio.isEmpty else { return nil }
        let clipsByID = Dictionary(uniqueKeysWithValues: p.clips.map { ($0.id, $0) })
        var params: [AVMutableAudioMixInputParameters] = []
        for (lane, tid) in b.audioTrackIDs {
            guard let ct = b.composition.track(withTrackID: tid) else { continue }
            let ip = AVMutableAudioMixInputParameters(track: ct)
            for seg in b.audio where seg.lane == lane {
                guard let c = clipsByID[seg.clipID] else { continue }
                // keys that only move the picture (e.g. stabilization, one per frame) leave the volume flat
                let flatKeys = c.effects.keys.allSatisfy { abs($0.volume - (c.effects.keys.first?.volume ?? 1)) < 1e-6 }
                if c.effects.audioFadeIn == 0 && c.effects.audioFadeOut == 0 && (c.effects.keys.isEmpty || flatKeys) {
                    ip.setVolume(Float(c.effects.keys.first?.volume ?? c.volume), at: time(seg.start)); continue
                }
                let duration = Double(seg.end - seg.start) / Double(timescale)
                var boundaries = Set<Double>([0, duration, min(duration, c.effects.audioFadeIn), max(0, duration - c.effects.audioFadeOut)])
                for key in c.effects.keys {
                    let t = (key.t - c.sourceIn) / c.speed
                    if t > 0 && t < duration { boundaries.insert(t) }
                }
                let sorted = boundaries.sorted()
                var lastEnd = seg.start      // ramps must not overlap, even by a rounding tick
                for (a, b) in zip(sorted, sorted.dropFirst()) {
                    let steps = (c.effects.keys.isEmpty && c.effects.audioFadeIn + c.effects.audioFadeOut <= duration) || c.effects.keys.count > 50 ? 1 : 12
                    for step in 0..<steps {
                        let x = a + (b - a) * Double(step) / Double(steps)
                        let y = a + (b - a) * Double(step + 1) / Double(steps)
                        let s0 = max(lastEnd, seg.start + ticks(x)), e0 = min(seg.end, seg.start + ticks(y))
                        guard e0 > s0 else { continue }
                        let v0 = c.motion(at: c.start + x).volume * c.envelope(at: c.start + x, audio: true)
                        let v1 = c.motion(at: c.start + y).volume * c.envelope(at: c.start + y, audio: true)
                        ip.setVolumeRamp(fromStartVolume: Float(v0), toEndVolume: Float(v1), timeRange: CMTimeRange(start: time(s0), end: time(e0)))
                        lastEnd = e0
                    }
                }
            }
            params.append(ip)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return mix
    }

    // MARK: - export overlays (titles + logo burned in with Core Animation)

    static func addOverlays(to vc: AVMutableVideoComposition, project p: Project) {
        // with the GPU compositor the titles and logo are drawn by it (OverlayTrack); Core Animation on top of it comes out white
        guard vc.customVideoCompositorClass == nil else { return }
        let hasTitles = !p.tracks.titlesHidden && p.clips.contains(where: { $0.isTitle })
        guard p.settings.showLogo || hasTitles else { return }
        let frame = p.settings.size
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: frame)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        func layer(_ e: Overlay.Element) -> CALayer {
            let l = CALayer()
            l.contents = e.image
            l.contentsGravity = .resize
            // Core Animation here is bottom-left based; our rects are top-left based
            l.frame = CGRect(x: e.rect.minX, y: frame.height - e.rect.maxY, width: e.rect.width, height: e.rect.height)
            return l
        }

        if let logo = Overlay.logo(settings: p.settings) { parent.addSublayer(layer(logo)) }

        if !p.tracks.titlesHidden {
            let k = Overlay.unit(frame)
            for c in p.clips where c.isTitle {
                guard let card = c.title else { continue }
                for e in Overlay.elements(for: card, frame: frame) {
                    let l = layer(e)
                    l.opacity = 0
                    let steps = max(2, Int(c.duration * 30))
                    var times: [NSNumber] = [], alphas: [NSNumber] = [], xs: [NSNumber] = []
                    for i in 0...steps {
                        let t = c.duration * Double(i) / Double(steps)
                        let a = Overlay.animation(t: t, dur: c.duration, delay: e.delay, fade: card.fade, unit: k * CGFloat(card.size))
                        times.append(NSNumber(value: Double(i) / Double(steps)))
                        alphas.append(NSNumber(value: a.alpha))
                        xs.append(NSNumber(value: Double(l.position.x + a.dx)))
                    }
                    let fade = CAKeyframeAnimation(keyPath: "opacity")
                    fade.values = alphas
                    let slide = CAKeyframeAnimation(keyPath: "position.x")
                    slide.values = xs
                    for anim in [fade, slide] {
                        anim.keyTimes = times
                        anim.beginTime = AVCoreAnimationBeginTimeAtZero + c.start
                        anim.duration = c.duration
                        // export runs on the video's clock: animations must stay attached (Apple docs)
                        anim.isRemovedOnCompletion = false
                        anim.fillMode = .both
                        anim.calculationMode = .linear
                        l.add(anim, forKey: anim.keyPath)
                    }
                    parent.addSublayer(l)
                }
            }
        }
        vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
    }
}
