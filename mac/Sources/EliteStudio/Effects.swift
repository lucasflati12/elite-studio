import Foundation
import SwiftUI

/// Shared with Windows/effects.py. Keys are in media seconds, so trimming and cuts preserve animation.
struct MotionKey: Hashable, Codable {
    var t = 0.0, scale = 1.0, x = 0.0, y = 0.0, opacity = 1.0, rotation = 0.0, volume = 1.0
    enum K: String, CodingKey { case t, scale, x, y, opacity, rotation, volume }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        t = c.get(.t, 0); scale = c.get(.scale, 1); x = c.get(.x, 0); y = c.get(.y, 0)
        opacity = c.get(.opacity, 1); rotation = c.get(.rotation, 0); volume = c.get(.volume, 1)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(t, forKey: .t); try c.encode(scale, forKey: .scale); try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        try c.encode(opacity, forKey: .opacity); try c.encode(rotation, forKey: .rotation); try c.encode(volume, forKey: .volume)
    }
}

struct ClipEffects: Hashable, Codable {
    var exposure = 0.0, contrast = 1.0, saturation = 1.0, temperature = 0.0
    var fadeIn = 0.0, fadeOut = 0.0, audioFadeIn = 0.0, audioFadeOut = 0.0, rotation = 0.0
    var ease = "smooth"
    var keys: [MotionKey] = []
    init() {}
    enum K: String, CodingKey { case exposure, contrast, saturation, temperature, fadeIn, fadeOut, audioFadeIn, audioFadeOut, rotation, ease, keys }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        exposure = min(3, max(-3, c.get(.exposure, 0))); contrast = min(2, max(0.2, c.get(.contrast, 1)))
        saturation = min(2, max(0, c.get(.saturation, 1))); temperature = min(1, max(-1, c.get(.temperature, 0)))
        fadeIn = max(0, c.get(.fadeIn, 0)); fadeOut = max(0, c.get(.fadeOut, 0))
        audioFadeIn = max(0, c.get(.audioFadeIn, 0)); audioFadeOut = max(0, c.get(.audioFadeOut, 0))
        rotation = c.get(.rotation, 0); ease = c.get(.ease, "smooth")
        keys = Array(c.get(.keys, [MotionKey]()).prefix(1000)).sorted { $0.t < $1.t }
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(exposure, forKey: .exposure); try c.encode(contrast, forKey: .contrast)
        try c.encode(saturation, forKey: .saturation); try c.encode(temperature, forKey: .temperature)
        try c.encode(fadeIn, forKey: .fadeIn); try c.encode(fadeOut, forKey: .fadeOut)
        try c.encode(audioFadeIn, forKey: .audioFadeIn); try c.encode(audioFadeOut, forKey: .audioFadeOut)
        try c.encode(rotation, forKey: .rotation); try c.encode(ease, forKey: .ease); try c.encode(keys, forKey: .keys)
    }
    var needsGPU: Bool { exposure != 0 || contrast != 1 || saturation != 1 || temperature != 0 || fadeIn > 0 || fadeOut > 0 || rotation != 0 || !keys.isEmpty }
}

extension Clip {
    mutating func recordMotion(_ property: WritableKeyPath<MotionKey, Double>, value: Double, at timeline: Double) {
        let position = min(max(timeline, start), max(start, end - 0.001))
        var key = motion(at: position); key.t = sourceTime(at: position); key[keyPath: property] = value
        effects.keys.removeAll { abs($0.t - key.t) < 0.01 }; effects.keys.append(key); effects.keys.sort { $0.t < $1.t }
    }
    func motion(at timeline: Double) -> MotionKey {
        var base = MotionKey(); base.t = sourceTime(at: timeline); base.scale = scale; base.x = offsetX; base.y = offsetY
        base.opacity = opacity; base.rotation = effects.rotation; base.volume = volume
        let keys = effects.keys.sorted { $0.t < $1.t }
        guard let first = keys.first, let last = keys.last else { return base }
        if base.t <= first.t { return first }; if base.t >= last.t { return last }
        guard let i = keys.firstIndex(where: { $0.t >= base.t }), i > 0 else { return base }
        let a = keys[i - 1], b = keys[i]
        var f = min(1, max(0, (base.t - a.t) / max(0.000001, b.t - a.t)))
        if effects.ease == "smooth" { f = f * f * (3 - 2 * f) }
        base.scale = a.scale + (b.scale - a.scale) * f; base.x = a.x + (b.x - a.x) * f; base.y = a.y + (b.y - a.y) * f
        base.opacity = a.opacity + (b.opacity - a.opacity) * f; base.rotation = a.rotation + (b.rotation - a.rotation) * f
        base.volume = a.volume + (b.volume - a.volume) * f
        return base
    }
    func envelope(at timeline: Double, audio: Bool = false) -> Double {
        let a = min(duration, audio ? effects.audioFadeIn : effects.fadeIn)
        let b = min(duration, audio ? effects.audioFadeOut : effects.fadeOut)
        let t = timeline - start
        return (a > 0 ? min(1, max(0, t / a)) : 1) * (b > 0 ? min(1, max(0, (duration - t) / b)) : 1)
    }
}

@MainActor
extension Editor {
    func addTrack() {
        guard project.lanes.count < 8 else { status = "Sono già disponibili otto tracce video/audio"; return }
        edit { p in
            let n = p.tracks.videoHidden.count == 2 ? 4 : p.tracks.videoHidden.count + 1
            p.tracks.videoHidden += Array(repeating: false, count: n - p.tracks.videoHidden.count)
            p.tracks.audioMuted += Array(repeating: false, count: n - p.tracks.audioMuted.count)
        }
    }
    func motionKey(_ id: ID) {
        edit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return }
            let position = min(max(self.clock.time, p.clips[i].start), max(p.clips[i].start, p.clips[i].end - 0.001))
            var key = p.clips[i].motion(at: position); key.t = p.clips[i].sourceTime(at: position)
            p.clips[i].effects.keys.removeAll { abs($0.t - key.t) < 0.01 }
            p.clips[i].effects.keys.append(key); p.clips[i].effects.keys.sort { $0.t < $1.t }
        }
    }
    func removeMotionKey(_ id: ID) {
        edit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }),
                  let near = p.clips[i].effects.keys.min(by: { abs($0.t - p.clips[i].sourceTime(at: self.clock.time)) < abs($1.t - p.clips[i].sourceTime(at: self.clock.time)) }) else { return }
            p.clips[i].effects.keys.removeAll { $0.t == near.t }
        }
    }
    func crossfadeSelection() {
        guard let id = selection.first, let b = project.clips.first(where: { $0.id == id }), !b.isTitle,
              let a = project.clips.first(where: { $0.id != id && !$0.isTitle && $0.track == b.track && abs($0.end - b.start) < 0.01 }),
              project.media(a.mediaID)?.hasVideo == true, project.media(b.mediaID)?.hasVideo == true else {
            status = "Seleziona la seconda di due clip video consecutive"; return
        }
        let d = min(0.35, min(a.duration / 2, b.duration / 2))
        guard d >= 1.0 / Double(max(1, project.settings.fps)) else { status = "Clip troppo brevi per questa transizione"; return }
        func shifted(_ c: Clip) -> Double { c.start >= b.start - 0.000001 ? c.start - d : c.start }
        func available(_ lane: Int) -> Bool {
            !project.clips.contains { c in
                c.id != a.id && c.id != b.id && c.track == lane && shifted(c) < b.start - d + b.duration && shifted(c) + c.duration > b.start - d
            }
        }
        var destination = project.lanes.first { $0 > b.track && available($0) }
        if destination == nil {
            guard project.lanes.count < 8 else { status = "Non ci sono tracce superiori libere per la transizione"; return }
            let next = (project.lanes.max() ?? 1) + 1
            destination = next == 2 ? 3 : next
        }
        guard let target = destination else { return }
        edit { p in
            if target >= p.tracks.videoHidden.count {
                p.tracks.videoHidden += Array(repeating: false, count: target + 1 - p.tracks.videoHidden.count)
                p.tracks.audioMuted += Array(repeating: false, count: target + 1 - p.tracks.audioMuted.count)
            }
            for i in p.clips.indices {
                if p.clips[i].start >= b.start - 0.000001 { p.clips[i].start -= d }
                if p.clips[i].id == a.id { p.clips[i].effects.fadeOut = 0; p.clips[i].effects.audioFadeOut = d }
                if p.clips[i].id == b.id { p.clips[i].effects.fadeIn = d; p.clips[i].effects.audioFadeIn = d; p.clips[i].track = target }
            }
            for i in p.captions.indices where p.captions[i].start >= b.start { p.captions[i].shift(-d) }
        }
        status = "Dissolvenza incrociata: sovrapposizione di \(String(format: "%.2f", d)) s"
    }
    func addPlainText() {
        addTitle()
        guard let id = selection.first else { return }
        edit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return }
            p.clips[i].title?.style = "text"; p.clips[i].title?.names = "Il tuo testo"
            p.clips[i].title?.x = 0.08; p.clips[i].title?.y = 0.45; p.clips[i].title?.tag = ""
        }
    }
}

struct EffectsInspector: View {
    @ObservedObject var editor: Editor
    @ObservedObject var clock: PlaybackClock
    let id: ID
    init(editor: Editor, id: ID) { self.editor = editor; self.clock = editor.clock; self.id = id }
    private func bind(_ key: WritableKeyPath<ClipEffects, Double>) -> Binding<Double> {
        Binding(get: {
            guard let c = editor.project.clips.first(where: { $0.id == id }) else { return 0 }
            return key == \ClipEffects.rotation && !c.effects.keys.isEmpty ? c.motion(at: clock.time).rotation : c.effects[keyPath: key]
        },
                set: { v in editor.edit("effects.\(id).\(key)") { p in
                    if let i = p.clips.firstIndex(where: { $0.id == id }) {
                        if key == \ClipEffects.rotation && !p.clips[i].effects.keys.isEmpty { p.clips[i].recordMotion(\.rotation, value: v, at: editor.clock.time) }
                        p.clips[i].effects[keyPath: key] = v
                    }
                } })
    }
    var body: some View {
        if let c = editor.project.clips.first(where: { $0.id == id }) {
            DisclosureGroup("Dissolvenze") {
                ValueSlider(title: "Video ingresso", value: bind(\.fadeIn), range: 0...3)
                ValueSlider(title: "Video uscita", value: bind(\.fadeOut), range: 0...3)
                ValueSlider(title: "Audio ingresso", value: bind(\.audioFadeIn), range: 0...3)
                ValueSlider(title: "Audio uscita", value: bind(\.audioFadeOut), range: 0...3)
                Button("Incrociata con precedente") { editor.crossfadeSelection() }
            }
            DisclosureGroup("Colore") {
                ValueSlider(title: "Esposizione", value: bind(\.exposure), range: -3...3)
                ValueSlider(title: "Contrasto", value: bind(\.contrast), range: 0.2...2)
                ValueSlider(title: "Saturazione", value: bind(\.saturation), range: 0...2)
                ValueSlider(title: "Temperatura", value: bind(\.temperature), range: -1...1)
            }
            DisclosureGroup("Animazione") {
                ValueSlider(title: "Rotazione", value: bind(\.rotation), range: -180...180)
                HStack {
                    Button("◆ Aggiungi") { editor.motionKey(id) }
                    Button("Rimuovi") { editor.removeMotionKey(id) }.disabled(c.effects.keys.isEmpty)
                }
                Text("\(c.effects.keys.count) keyframe. Sposta il cursore e modifica scala, posizione, opacità o volume.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Reimposta effetti") { editor.edit { p in if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].effects = ClipEffects() } } }
        }
    }
}
