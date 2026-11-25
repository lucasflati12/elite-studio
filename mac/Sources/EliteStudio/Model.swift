import Foundation
import CoreGraphics

// The project file (.elitestudio) is plain JSON, designed to be easy to write by hand or by a script.
// See FORMAT.md. Every field except the essentials is optional when reading.

typealias ID = String
func newID() -> ID { String(UUID().uuidString.prefix(8)).lowercased() }

/// A file in the project bin.
struct MediaItem: Identifiable, Hashable {
    var id: ID = newID()
    var url: URL
    var name: String
    var duration: Double = 0      // 0 = not probed yet
    var hasVideo = true
    var hasAudio = true
    var width: Double = 0         // display size (rotation applied)
    var height: Double = 0
    var still = false             // made from a photo (a short silent video generated on import)
    var pano = false              // Insta360 360 clip (.insv): reframed in the app
}

/// Lower-third name card (same look as the old Interview Studio cards).
struct TitleCard: Hashable {
    var style = "card"
    var names = "Nome Cognome"                   // one person per line
    var label = "COPPA \u{00C9}LITE  /  WINTER EDITION"
    var showLabel = true
    var tag = "MVP"                              // empty = no gold tag
    var x = 60.0 / 1080.0                        // left edge, fraction of frame width
    var y = 1330.0 / 1920.0                      // top of the name box, fraction of frame height
    var size = 1.0
    var fade = 0.4
    var animationIn = "Nessuna"
    var animationOut = "Nessuna"
    var stylePreset = "Normale"
}

struct TimelineMarker: Codable, Hashable { var t = 0.0; var name = ""; var color = "#e4ca4a" }
struct Crop: Codable, Hashable {
    var left = 0.0; var right = 0.0; var top = 0.0; var bottom = 0.0
    enum K: String, CodingKey { case left, right, top, bottom }
    init() {}
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: K.self); left = c.get(.left, 0); right = c.get(.right, 0); top = c.get(.top, 0); bottom = c.get(.bottom, 0) }
}
struct ClipBackground: Codable, Hashable {
    var type = "blur"; var amount = 12.0
    enum K: String, CodingKey { case type, amount }
    init() {}
    init(type: String = "blur", amount: Double = 12) { self.type = type; self.amount = amount }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: K.self); type = c.get(.type, "blur"); amount = c.get(.amount, 12) }
}
struct ClipTransition: Codable, Hashable {
    var type = "Dissolvenza al nero"; var duration = 0.5
    enum K: String, CodingKey { case type, duration }
    init() {}
    init(type: String = "Dissolvenza al nero", duration: Double = 0.5) { self.type = type; self.duration = duration }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: K.self); type = c.get(.type, "Dissolvenza al nero"); duration = max(0.05, c.get(.duration, 0.5)) }
}
struct ChromaKey: Codable, Hashable {
    var color = "#00ff00"; var tolerance = 0.12; var softness = 0.08
    enum K: String, CodingKey { case color, tolerance, softness }
    init() {}
    init(color: String = "#00ff00", tolerance: Double = 0.12, softness: Double = 0.08) { self.color = color; self.tolerance = tolerance; self.softness = softness }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: K.self); color = c.get(.color, "#00ff00"); tolerance = min(0.5, max(0.001, c.get(.tolerance, 0.12))); softness = min(0.5, max(0.001, c.get(.softness, 0.08))) }
}
struct SpeedRamp: Codable, Hashable {
    var preset = "Montagna"; var segment = 0; var points: [Double] = [1, 1, 1]
    enum K: String, CodingKey { case preset, segment, points }
    init() {}
    init(preset: String, segment: Int, points: [Double]) { self.preset = preset; self.segment = segment; self.points = points }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: K.self); preset = c.get(.preset, "Montagna"); segment = c.get(.segment, 0); points = c.get(.points, [1, 1, 1]) }
}
struct FreezeSource: Codable, Hashable { var media: String; var time: Double }
struct ReverseSource: Codable, Hashable { var media: String; var `in`: Double; var duration: Double }

/// Track: 0 = V1/A1 (main), 1 = V2/A2 (overlay), 2 = titles.
enum TrackIndex {
    static let main = 0
    static let overlay = 1
    static let titles = 2
}

struct Clip: Identifiable, Hashable {
    var id: ID = newID()
    var mediaID: ID?              // nil for titles
    var title: TitleCard?
    var track = 0
    var start = 0.0               // position on the timeline (s)
    var duration = 0.0
    var sourceIn = 0.0            // where the clip starts inside the media file (s)
    var volume = 1.0
    var opacity = 1.0
    var scale = 1.0
    var fill = false              // true = fill the frame (crop), false = fit
    var offsetX = 0.0             // fraction of frame
    var offsetY = 0.0
    var speed = 1.0               // 2 = twice as fast (the clip covers twice as much of the file)
    var pitch = true
    var speedRamp: SpeedRamp?
    var freezeFrame = false
    var freezeSource: FreezeSource?
    var reversed = false
    var reverseSource: ReverseSource?
    var crop: Crop?
    var flipH = false
    var flipV = false
    var background: ClipBackground?
    var transition: ClipTransition?
    var noiseReduction = false
    var chromaKey: ChromaKey?
    var audioDisabled = false
    var audioDetached = false
    var reframe: Reframe?         // 360 clips: where the virtual camera looks (nil = defaults)
    var effects = ClipEffects()

    var end: Double { start + duration }
    var isTitle: Bool { title != nil }
    /// How much of the media file the clip uses.
    var sourceDuration: Double { duration * speed }
    /// Position inside the media file at timeline time `t`.
    func sourceTime(at t: Double) -> Double { sourceIn + (t - start) * speed }
}

struct SequenceSettings: Hashable {
    var width = 1080
    var height = 1920
    var fps = 30
    var customized = false        // false = follow the first clip's orientation

    var size: CGSize { CGSize(width: width, height: height) }
}

struct TrackState: Hashable {
    var videoHidden = [false, false]
    var audioMuted = [false, false]
    var titlesHidden = false
    var captionsHidden = false
}

struct Project: Hashable {
    var media: [MediaItem] = []
    var clips: [Clip] = []
    var settings = SequenceSettings()
    var tracks = TrackState()
    var captions: [Caption] = []          // automatic subtitles, timeline seconds (see Captions.swift)
    var captionStyle = CaptionStyle()
    var markers: [TimelineMarker] = []
    var lanes: [Int] { Array(0..<max(2, tracks.videoHidden.count)).filter { $0 != 2 } }
    static func trackNumber(_ lane: Int) -> Int { lane < 2 ? lane + 1 : lane }

    func media(_ id: ID?) -> MediaItem? {
        guard let id else { return nil }
        return media.first { $0.id == id }
    }

    var duration: Double { clips.map(\.end).max() ?? 0 }

    var editPoints: [Double] {
        var s = Set<Double>([0])
        for c in clips { s.insert(round6(c.start)); s.insert(round6(c.end)) }
        return s.sorted()
    }
}

let minClipDuration = 1.0 / 30.0

func round6(_ v: Double) -> Double { (v * 1_000_000).rounded() / 1_000_000 }
func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

func formatTimecode(_ t: Double, fps: Int) -> String {
    let t = max(0, t)
    let total = Int(t)
    let f = Int(((t - Double(total)) * Double(fps)).rounded(.down))
    return String(format: "%02d:%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60, min(f, fps - 1))
}

func formatShort(_ t: Double) -> String {
    let total = Int(max(0, t))
    let m = total / 60, s = total % 60
    if m >= 60 { return String(format: "%d:%02d:%02d", m / 60, m % 60, s) }
    return String(format: "%d:%02d", m, s)
}

// MARK: - JSON file format

extension KeyedDecodingContainer {
    func get<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

enum ProjectFile {
    /// Reads a project. Relative media paths are resolved against `base` (the project's folder).
    static func decode(_ data: Data, base: URL?) throws -> Project {
        let raw = try JSONDecoder().decode(RawProject.self, from: data)
        var p = Project()
        p.settings = raw.settings ?? SequenceSettings()
        p.tracks = raw.tracks ?? TrackState()
        p.captions = (raw.captions ?? []).filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        p.captionStyle = raw.captionStyle ?? CaptionStyle()
        p.markers = (raw.markers ?? []).map { var m = $0; m.t = max(0, m.t); return m }.sorted { $0.t < $1.t }
        var byPath: [String: ID] = [:]
        for m in raw.media ?? [] {
            let url = resolve(m.path, base: base)
            var item = MediaItem(url: url, name: m.name ?? url.lastPathComponent)
            if let id = m.id { item.id = id }
            item.duration = m.duration ?? 0
            item.hasVideo = m.hasVideo ?? true
            item.hasAudio = m.hasAudio ?? true
            item.width = m.width ?? 0
            item.height = m.height ?? 0
            item.still = m.still ?? false
            item.pano = m.pano ?? false
            p.media.append(item)
            byPath[url.standardizedFileURL.path] = item.id
        }
        var trackEnd: [Int: Double] = [:]
        for rc in raw.clips ?? [] {
            var c = Clip()
            if let id = rc.id { c.id = id }
            if let t = rc.title {
                c.title = t
                c.track = TrackIndex.titles
            } else if let ref = rc.media {
                // a clip may point to a media id or directly to a file path
                if p.media.contains(where: { $0.id == ref }) {
                    c.mediaID = ref
                } else {
                    let url = resolve(ref, base: base)
                    if let id = byPath[url.standardizedFileURL.path] { c.mediaID = id } else {
                        let item = MediaItem(url: url, name: url.lastPathComponent)
                        p.media.append(item)
                        byPath[url.standardizedFileURL.path] = item.id
                        c.mediaID = item.id
                    }
                }
                c.track = min(8, max(0, rc.track ?? 0))
                if c.track == 2 { c.track = 0 }
            } else { continue }
            c.sourceIn = max(0, rc.in ?? 0)
            c.speed = min(16, max(0.1, rc.speed ?? 1))
            // `out` is a position in the file, so with a speed change the clip lasts (out - in) / speed on the timeline
            if let d = rc.duration { c.duration = d } else if let out = rc.out { c.duration = (out - c.sourceIn) / c.speed } else if c.isTitle { c.duration = 3 }
            // no start = right after the previous clip on the same track
            c.start = max(0, rc.start ?? trackEnd[c.track] ?? 0)
            c.volume = rc.volume ?? 1
            c.opacity = rc.opacity ?? 1
            c.scale = rc.scale ?? 1
            c.fill = rc.fill ?? false
            c.offsetX = rc.x ?? 0
            c.offsetY = rc.y ?? 0
            c.reframe = rc.pano
            c.effects = rc.effects ?? ClipEffects()
            c.pitch = rc.pitch ?? true; c.speedRamp = rc.speedRamp
            c.freezeFrame = rc.freezeFrame ?? false; c.freezeSource = rc.freezeSource
            c.reversed = rc.reversed ?? false; c.reverseSource = rc.reverseSource
            c.crop = rc.crop; c.flipH = rc.flipH ?? false; c.flipV = rc.flipV ?? false
            c.background = rc.background; c.transition = rc.transition
            c.noiseReduction = rc.noiseReduction ?? false; c.chromaKey = rc.chromaKey
            c.audioDisabled = rc.audioDisabled ?? false; c.audioDetached = rc.audioDetached ?? false
            p.clips.append(c)          // duration 0 = "to the end of the file", filled in after probing
            trackEnd[c.track] = c.end
        }
        let count = min(9, max(2, max(p.tracks.videoHidden.count, (p.clips.filter { !$0.isTitle }.map(\.track).max() ?? 1) + 1)))
        p.tracks.videoHidden = Array((p.tracks.videoHidden + Array(repeating: false, count: count)).prefix(count))
        p.tracks.audioMuted = Array((p.tracks.audioMuted + Array(repeating: false, count: count)).prefix(count))
        return p
    }

    static func encode(_ p: Project, base: URL?) throws -> Data {
        var raw = RawProject()
        raw.format = "elitestudio/1"
        raw.settings = p.settings
        raw.tracks = p.tracks
        if !p.captions.isEmpty { raw.captions = p.captions.sorted { $0.start < $1.start } }
        raw.captionStyle = p.captionStyle
        if !p.markers.isEmpty { raw.markers = p.markers.sorted { $0.t < $1.t } }
        raw.media = p.media.map {
            RawMedia(id: $0.id, path: relative($0.url, base: base), name: $0.name, duration: round3($0.duration),
                     hasVideo: $0.hasVideo, hasAudio: $0.hasAudio, width: $0.width, height: $0.height, still: $0.still ? true : nil,
                     pano: $0.pano ? true : nil)
        }
        raw.clips = p.clips.sorted { ($0.track, $0.start) < ($1.track, $1.start) }.map { c in
            var r = RawClip()
            r.id = c.id
            r.media = c.mediaID
            r.title = c.title
            r.track = c.track
            r.start = round3(c.start)
            r.in = c.isTitle ? nil : round3(c.sourceIn)
            r.duration = round3(c.duration)
            if c.volume != 1 { r.volume = c.volume }
            if c.opacity != 1 { r.opacity = c.opacity }
            if c.scale != 1 { r.scale = c.scale }
            if c.fill { r.fill = true }
            if c.offsetX != 0 { r.x = c.offsetX }
            if c.offsetY != 0 { r.y = c.offsetY }
            if c.speed != 1 { r.speed = c.speed }
            r.pano = c.reframe
            r.pitch = c.pitch == false ? false : nil; r.speedRamp = c.speedRamp
            r.freezeFrame = c.freezeFrame ? true : nil; r.freezeSource = c.freezeSource
            r.reversed = c.reversed ? true : nil; r.reverseSource = c.reverseSource
            r.crop = c.crop; r.flipH = c.flipH ? true : nil; r.flipV = c.flipV ? true : nil
            r.background = c.background; r.transition = c.transition
            r.noiseReduction = c.noiseReduction ? true : nil; r.chromaKey = c.chromaKey
            r.audioDisabled = c.audioDisabled ? true : nil; r.audioDetached = c.audioDetached ? true : nil
            if c.effects != ClipEffects() { r.effects = c.effects }
            return r
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(raw)
    }

    static func resolve(_ path: String, base: URL?) -> URL {
        let p = (path as NSString).expandingTildeInPath
        if p.hasPrefix("/") || base == nil { return URL(fileURLWithPath: p) }
        return base!.appendingPathComponent(p).standardizedFileURL
    }

    /// Paths inside the project folder are stored relative, so the folder can be moved.
    static func relative(_ url: URL, base: URL?) -> String {
        let path = url.standardizedFileURL.path
        if let base {
            let b = base.standardizedFileURL.path + "/"
            if path.hasPrefix(b) { return String(path.dropFirst(b.count)) }
        }
        return path
    }
}

private struct RawProject: Codable {
    var format: String?
    var settings: SequenceSettings?
    var tracks: TrackState?
    var media: [RawMedia]?
    var clips: [RawClip]?
    var captions: [Caption]?
    var captionStyle: CaptionStyle?
    var markers: [TimelineMarker]?
}

private struct RawMedia: Codable {
    var id: String?
    var path: String
    var name: String?
    var duration: Double?
    var hasVideo: Bool?
    var hasAudio: Bool?
    var width: Double?
    var height: Double?
    var still: Bool?
    var pano: Bool?
}

private struct RawClip: Codable {
    var id: String?
    var media: String?
    var title: TitleCard?
    var track: Int?
    var start: Double?
    var `in`: Double?
    var out: Double?
    var duration: Double?
    var volume: Double?
    var opacity: Double?
    var scale: Double?
    var fill: Bool?
    var x: Double?
    var y: Double?
    var speed: Double?
    var pano: Reframe?
    var effects: ClipEffects?
    var pitch: Bool?; var speedRamp: SpeedRamp?; var freezeFrame: Bool?; var freezeSource: FreezeSource?
    var reversed: Bool?; var reverseSource: ReverseSource?; var crop: Crop?; var flipH: Bool?; var flipV: Bool?
    var background: ClipBackground?; var transition: ClipTransition?; var noiseReduction: Bool?; var chromaKey: ChromaKey?
    var audioDisabled: Bool?; var audioDetached: Bool?
}

extension TitleCard: Codable {
    enum K: String, CodingKey { case names, label, showLabel, tag, x, y, size, fade, style, animationIn, animationOut, stylePreset }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let def = TitleCard()
        style = c.get(.style, "card")
        // "names" may be a string (one name per line) or an array
        if let arr = try? c.decode([String].self, forKey: .names) { names = arr.joined(separator: "\n") } else { names = c.get(.names, def.names) }
        label = c.get(.label, def.label); showLabel = c.get(.showLabel, def.showLabel); tag = c.get(.tag, def.tag)
        x = c.get(.x, def.x); y = c.get(.y, def.y); size = c.get(.size, def.size); fade = c.get(.fade, def.fade)
        animationIn = c.get(.animationIn, "Nessuna"); animationOut = c.get(.animationOut, "Nessuna"); stylePreset = c.get(.stylePreset, "Normale")
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(names, forKey: .names); try c.encode(label, forKey: .label); try c.encode(showLabel, forKey: .showLabel)
        try c.encode(tag, forKey: .tag); try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        try c.encode(size, forKey: .size); try c.encode(fade, forKey: .fade)
        try c.encode(style, forKey: .style)
        if animationIn != "Nessuna" { try c.encode(animationIn, forKey: .animationIn) }
        if animationOut != "Nessuna" { try c.encode(animationOut, forKey: .animationOut) }
        if stylePreset != "Normale" { try c.encode(stylePreset, forKey: .stylePreset) }
    }
}

extension SequenceSettings: Codable {
    enum K: String, CodingKey { case width, height, fps, customized }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let def = SequenceSettings()
        width = c.get(.width, def.width); height = c.get(.height, def.height); fps = c.get(.fps, def.fps)
        // a file that states its size is treated as a deliberate choice
        customized = c.get(.customized, c.contains(.width) || c.contains(.height))
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(width, forKey: .width); try c.encode(height, forKey: .height); try c.encode(fps, forKey: .fps)
        try c.encode(customized, forKey: .customized)
    }
}

extension TrackState: Codable {
    enum K: String, CodingKey { case videoHidden, audioMuted, titlesHidden, captionsHidden }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let def = TrackState()
        videoHidden = c.get(.videoHidden, def.videoHidden); audioMuted = c.get(.audioMuted, def.audioMuted)
        titlesHidden = c.get(.titlesHidden, def.titlesHidden)
        captionsHidden = c.get(.captionsHidden, def.captionsHidden)
        if videoHidden.count < 2 { videoHidden = def.videoHidden }
        if audioMuted.count < 2 { audioMuted = def.audioMuted }
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(videoHidden, forKey: .videoHidden); try c.encode(audioMuted, forKey: .audioMuted)
        try c.encode(titlesHidden, forKey: .titlesHidden)
        try c.encode(captionsHidden, forKey: .captionsHidden)
    }
}
