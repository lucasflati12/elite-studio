import Foundation
import AVFoundation
import CoreText
import Speech

// Automatic captions (CapCut style): the timeline audio is transcribed on the Mac (Apple Speech, on device),
// split into short phrases and drawn big in the middle of the frame. The "negativo" look has no colour of its own:
// the text shows the video inverted, so it changes colour with whatever is behind it.
// Captions are drawn by the GPU compositor (PanoCompositor), so the viewer and the export look the same.

/// One spoken word, in timeline seconds.
struct CaptionWord: Hashable, Codable {
    var w: String
    var s: Double
    var e: Double
}

/// One phrase on screen (1–4 words), in timeline seconds.
struct Caption: Identifiable, Hashable {
    var id: ID = newID()
    var start = 0.0
    var end = 0.0
    var words: [CaptionWord] = []

    var text: String { words.map(\.w).joined(separator: " ") }
    var duration: Double { end - start }

    /// New text: same number of words keeps the timings, otherwise the words are spread evenly.
    mutating func setText(_ s: String) {
        let toks = s.split(whereSeparator: \.isWhitespace).map(String.init)
        if toks.count == words.count {
            for i in toks.indices { words[i].w = toks[i] }
            return
        }
        let n = Double(max(1, toks.count)), d = max(0.01, end - start)
        words = toks.enumerated().map { i, w in
            CaptionWord(w: w, s: start + d * Double(i) / n, e: start + d * Double(i + 1) / n)
        }
    }

    /// Moves / stretches the caption to a new range, keeping each word at the same relative place.
    mutating func retime(_ s: Double, _ e: Double) {
        let s0 = start, d0 = max(0.001, end - start), d1 = e - s
        let map = { (t: Double) in s + (t - s0) / d0 * d1 }
        words = words.map { CaptionWord(w: $0.w, s: map($0.s), e: map($0.e)) }
        start = s; end = e
    }

    mutating func shift(_ d: Double) { retime(start + d, end + d) }
}

enum CaptionLook: String, Codable, CaseIterable {
    case negative = "negativo"     // text = the video inverted
    case white = "bianco"          // white with a black outline
    case gold = "oro"              // white with outline, the word being spoken in Coppa Élite gold

    var label: String {
        switch self {
        case .negative: return "Negativo"
        case .white: return "Bianco"
        case .gold: return "Oro"
        }
    }
}

struct CaptionStyle: Hashable {
    var look = CaptionLook.negative
    var y = 0.62                  // vertical centre of the text, fraction of frame height
    var size = 1.0
    var uppercase = true
    var pop = true                // each phrase pops in
    var maxWords = 3              // words per phrase when (re)grouping
    var language = "it-IT"
}

extension CaptionStyle: Codable {
    enum K: String, CodingKey { case look, y, size, uppercase, pop, maxWords, language }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let def = CaptionStyle()
        look = c.get(.look, def.look); y = c.get(.y, def.y); size = c.get(.size, def.size)
        uppercase = c.get(.uppercase, def.uppercase); pop = c.get(.pop, def.pop)
        maxWords = min(8, max(1, c.get(.maxWords, def.maxWords))); language = c.get(.language, def.language)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(look, forKey: .look); try c.encode(y, forKey: .y); try c.encode(size, forKey: .size)
        try c.encode(uppercase, forKey: .uppercase); try c.encode(pop, forKey: .pop)
        try c.encode(maxWords, forKey: .maxWords); try c.encode(language, forKey: .language)
    }
}

extension Caption: Codable {
    enum K: String, CodingKey { case id, start, end, duration, text, words }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = c.get(.id, newID())
        start = try c.decode(Double.self, forKey: .start)
        words = c.get(.words, [CaptionWord]())
        if let e = try? c.decode(Double.self, forKey: .end) { end = e }
        else if let du = try? c.decode(Double.self, forKey: .duration) { end = start + du }
        else { end = words.last?.e ?? start + 1.5 }
        // a written `text` wins over the words (hand edits); timings are kept when the word count matches
        let text: String = c.get(.text, "")
        if !text.isEmpty && text != self.text { setText(text) }
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(round3(start), forKey: .start); try c.encode(round3(end), forKey: .end)
        try c.encode(text, forKey: .text)
        try c.encode(words.map { CaptionWord(w: $0.w, s: round3($0.s), e: round3($0.e)) }, forKey: .words)
    }
}

// MARK: - grouping words into phrases

enum Captions {
    /// Splits a word list into short phrases: at most `maxWords` words, a new phrase after punctuation or a pause.
    static func chunks(_ words: [CaptionWord], maxWords: Int, maxChars: Int = 20) -> [Caption] {
        var out: [Caption] = []
        var cur: [CaptionWord] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            out.append(Caption(start: f.s, end: l.e, words: cur))
            cur = []
        }
        for raw in words {
            let w = clean(raw.w)
            guard !w.isEmpty else { continue }
            let word = CaptionWord(w: w, s: raw.s, e: max(raw.e, raw.s + 0.05))
            if let last = cur.last {
                let chars = cur.reduce(0) { $0 + $1.w.count + 1 } + w.count
                let pause = word.s - last.e > 0.6
                if cur.count >= maxWords || chars > maxChars || pause { flush() }
            }
            cur.append(word)
            // a phrase also ends after a full stop / question mark, or a comma once it has two words
            let t = raw.w.trimmingCharacters(in: .whitespaces)
            if let ch = t.last, ".?!".contains(ch) || (",;:".contains(ch) && cur.count >= 2) { flush() }
        }
        flush()
        // hold each phrase until the next one when the gap is short, so the text doesn't flicker
        for i in out.indices {
            let next = i + 1 < out.count ? out[i + 1].start : .infinity
            let hold = next - out[i].end < 0.5 ? next : min(out[i].end + 0.3, next)
            out[i].end = min(max(out[i].start + 0.25, hold), next)
        }
        return out
    }

    /// Joins every caption's words again and makes new phrases (after changing "words per phrase").
    static func regroup(_ caps: [Caption], maxWords: Int) -> [Caption] {
        chunks(caps.sorted { $0.start < $1.start }.flatMap(\.words), maxWords: maxWords)
    }

    /// Drops trailing commas / full stops (they look bad big on screen), keeps ? and !.
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let l = t.last, ",.;:".contains(l) { t.removeLast() }
        return t
    }
}

// MARK: - drawing

enum CaptionRender {
    struct Bitmap {
        let bytes: [UInt8]           // RGBA, premultiplied, top row first
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let rect: CGRect             // where it goes in the frame (pixels, top-left origin)
    }

    static let gold = CGColor(srgbRed: 1, green: 210 / 255, blue: 63 / 255, alpha: 1)

    static func font(_ size: CGFloat) -> CTFont { CTFontCreateWithName("ArchivoBlack-Regular" as CFString, size, nil) }

    static func display(_ w: String, _ s: CaptionStyle) -> String { s.uppercase ? w.uppercased(with: Locale(identifier: s.language)) : w }

    private static func line(_ s: String, _ f: CTFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f]))
    }

    private static func width(_ s: String, _ f: CTFont) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line(s, f), nil, nil, nil)) }

    /// Glyph outlines of a word with its baseline starting at `o` (Core Graphics coordinates).
    private static func path(_ s: String, _ f: CTFont, at o: CGPoint) -> CGPath {
        let p = CGMutablePath()
        for run in CTLineGetGlyphRuns(line(s, f)) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let rf = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? f
            var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &pos)
            for i in 0..<n {
                if let g = CTFontCreatePathForGlyph(rf, glyphs[i], nil) {
                    p.addPath(g, transform: CGAffineTransform(translationX: o.x + pos[i].x, y: o.y + pos[i].y))
                }
            }
        }
        return p
    }

    /// Draws a phrase. `active` = index of the word being spoken (used by the gold look).
    static func bitmap(_ c: Caption, active: Int?, style s: CaptionStyle, frame: CGSize) -> Bitmap? {
        let toks = c.words.map { display($0.w, s) }
        guard !toks.isEmpty, frame.width > 0 else { return nil }
        let k = min(frame.width, frame.height) / 1080
        let maxW = frame.width * 0.86
        var fs = 88 * k * CGFloat(s.size)
        var lines: [[Int]] = [Array(toks.indices)]
        var widths: [CGFloat] = []
        var space: CGFloat = 0
        // one line if it fits, otherwise two balanced lines; shrink the font if even that is too wide
        for _ in 0..<12 {
            let f = font(fs)
            widths = toks.map { width($0, f) }
            space = fs * 0.24
            func w(_ r: Range<Int>) -> CGFloat { r.isEmpty ? 0 : widths[r].reduce(0, +) + space * CGFloat(r.count - 1) }
            let n = toks.count
            if w(0..<n) <= maxW { lines = [Array(0..<n)]; break }
            if n > 1 {
                let i = (1..<n).min { max(w(0..<$0), w($0..<n)) < max(w(0..<$1), w($1..<n)) }!
                lines = [Array(0..<i), Array(i..<n)]
                if max(w(0..<i), w(i..<n)) <= maxW { break }
            }
            fs *= 0.9
        }
        let f = font(fs)
        let lineW = lines.map { l in l.map { widths[$0] }.reduce(0, +) + space * CGFloat(l.count - 1) }
        let outline = s.look == .negative ? 0 : fs * 0.11
        let pad = ceil(outline + fs * 0.3)
        let lineH = fs * 1.06
        let capH = CTFontGetCapHeight(f)
        let w = Int(ceil((lineW.max() ?? 0) + pad * 2))
        let h = Int(ceil(lineH * CGFloat(lines.count) + pad * 2))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // word outlines, placed line by line (capitals centred in each line)
        var paths: [(Int, CGPath)] = []
        for (li, l) in lines.enumerated() {
            var x = (CGFloat(w) - lineW[li]) / 2
            let baselineFromTop = pad + lineH * CGFloat(li) + (lineH + capH) / 2
            let y = CGFloat(h) - baselineFromTop
            for i in l {
                paths.append((i, path(toks[i], f, at: CGPoint(x: x, y: y))))
                x += widths[i] + space
            }
        }
        if outline > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -fs * 0.04), blur: fs * 0.18, color: CGColor(gray: 0, alpha: 0.55))
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(outline * 2)
            ctx.setLineJoin(.round)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for (_, p) in paths { ctx.addPath(p); ctx.drawPath(using: .fillStroke) }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        for (i, p) in paths {
            ctx.setFillColor(s.look == .gold && i == active ? gold : CGColor(gray: 1, alpha: 1))
            ctx.addPath(p)
            ctx.fillPath()
        }
        guard let data = ctx.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * h))
        let cy = CGFloat(s.y) * frame.height
        let top = min(max(0, cy - CGFloat(h) / 2), max(0, frame.height - CGFloat(h)))
        return Bitmap(bytes: bytes, width: w, height: h, bytesPerRow: ctx.bytesPerRow,
                      rect: CGRect(x: (frame.width - CGFloat(w)) / 2, y: top, width: CGFloat(w), height: CGFloat(h)))
    }
}

/// The captions of one video composition, read by the GPU compositor on its own thread.
final class CaptionTrack: @unchecked Sendable {
    let captions: [Caption]
    let style: CaptionStyle
    let frame: CGSize
    private let styleKey: String
    private let lock = NSLock()
    private var cache: [String: CaptionRender.Bitmap] = [:]

    struct State {
        let key: String
        let bitmap: CaptionRender.Bitmap
        let scale: Float
        let alpha: Float
        let difference: Bool
        var dx: CGFloat = 0
        var dy: CGFloat = 0
    }

    init(captions: [Caption], style: CaptionStyle, frame: CGSize) {
        self.captions = captions.sorted { $0.start < $1.start }
        self.style = style
        self.frame = frame
        styleKey = "\(style.hashValue)|\(frame.width)x\(frame.height)"
    }

    func state(at t: Double) -> State? {
        // last caption starting at or before t
        var lo = 0, hi = captions.count
        while lo < hi { let m = (lo + hi) / 2; if captions[m].start <= t { lo = m + 1 } else { hi = m } }
        guard lo > 0 else { return nil }
        let c = captions[lo - 1]
        guard t < c.end, !c.words.isEmpty else { return nil }
        let active = style.look == .gold ? (c.words.lastIndex { $0.s <= t + 0.02 } ?? 0) : nil
        let key = "\(c.hashValue)|\(active ?? -1)|\(styleKey)"
        lock.lock()
        var bmp = cache[key]
        lock.unlock()
        if bmp == nil {
            bmp = CaptionRender.bitmap(c, active: active, style: style, frame: frame)
            lock.lock()
            if cache.count > 400 { cache.removeAll() }
            cache[key] = bmp
            lock.unlock()
        }
        guard let bitmap = bmp else { return nil }
        var scale: Float = 1, alpha: Float = 1
        if style.pop {
            // quick pop with a little overshoot, like CapCut
            let x = min(1, max(0, (t - c.start) / 0.16))
            let c1 = 1.70158, c3 = c1 + 1
            let back = 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
            scale = Float(0.7 + 0.3 * back)
            alpha = Float(min(1, max(0, (t - c.start) / 0.05 + 0.2)))
        }
        return State(key: key, bitmap: bitmap, scale: scale, alpha: alpha, difference: style.look == .negative)
    }
}

/// Titles for exports that go through the GPU compositor (same images and animation as the viewer).
final class OverlayTrack: @unchecked Sendable {
    private struct Item {
        let key: String
        let bitmap: CaptionRender.Bitmap
        let start: Double, duration: Double
        let delay: Double, fade: Double, unit: CGFloat
        let animated: Bool
        let animationIn: String
        let animationOut: String
    }
    private let items: [Item]

    @MainActor
    init?(project p: Project) {
        let frame = p.settings.size
        var items: [Item] = []
        if !p.tracks.titlesHidden {
            for c in p.clips where c.isTitle {
                guard let card = c.title else { continue }
                for (i, e) in Overlay.elements(for: card, frame: frame).enumerated() {
                    guard let b = OverlayTrack.bitmap(e.image, rect: e.rect) else { continue }
                    items.append(Item(key: "title|\(card.hashValue)|\(i)|\(frame.width)", bitmap: b, start: c.start, duration: c.duration,
                                      delay: e.delay, fade: card.fade, unit: Overlay.unit(frame) * CGFloat(card.size), animated: true,
                                      animationIn: card.animationIn, animationOut: card.animationOut))
                }
            }
        }
        if items.isEmpty { return nil }
        self.items = items
    }

    private static func bitmap(_ img: CGImage, rect: CGRect) -> CaptionRender.Bitmap? {
        let w = img.width, h = img.height
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = { ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.data }() else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * h))
        return CaptionRender.Bitmap(bytes: bytes, width: w, height: h, bytesPerRow: ctx.bytesPerRow, rect: rect)
    }

    func states(at t: Double) -> [CaptionTrack.State] {
        items.compactMap { it in
            guard t >= it.start, t < it.start + it.duration else { return nil }
            if !it.animated { return CaptionTrack.State(key: it.key, bitmap: it.bitmap, scale: 1, alpha: 1, difference: false) }
            let a = Overlay.animation(t: t - it.start, dur: it.duration, delay: it.delay, fade: it.fade, unit: it.unit)
            let local = t - it.start
            let animDuration = min(0.7, max(0.05, it.fade))
            var alpha = a.alpha
            var dy: CGFloat = 0
            if it.animationIn == "Dissolvenza" || it.animationIn == "Macchina da scrivere" { alpha *= min(1, max(0, local / animDuration)) }
            if it.animationIn == "Scorri su" { let progress = min(1, max(0, local / animDuration)); dy += CGFloat(1 - progress) * it.unit * 80 }
            if it.animationIn == "Pop/Scala" { alpha *= min(1, max(0, local / animDuration)) }
            if it.animationOut != "Nessuna" {
                let out = min(1, max(0, (it.start + it.duration - t) / animDuration))
                if it.animationOut == "Dissolvenza" || it.animationOut == "Pop/Scala" { alpha *= out }
                if it.animationOut == "Scorri su" { dy += CGFloat(1 - out) * it.unit * 80 }
            }
            guard alpha > 0 else { return nil }
            return CaptionTrack.State(key: it.key, bitmap: it.bitmap, scale: 1, alpha: Float(alpha), difference: false, dx: a.dx, dy: dy)
        }
    }
}

// MARK: - transcription (Apple Speech, on device)

enum Transcriber {
    static let languages: [(id: String, name: String)] = [("it-IT", "Italiano"), ("en-US", "English"), ("es-ES", "Español"), ("fr-FR", "Français"), ("de-DE", "Deutsch")]

    static func error(_ s: String) -> NSError { NSError(domain: "EliteStudio", code: 20, userInfo: [NSLocalizedDescriptionKey: s]) }

    /// Transcribes everything you hear on the timeline (both audio tracks, with their volumes). Word times are timeline times.
    @MainActor
    static func words(project p: Project, language: String, status: @escaping @MainActor (String) -> Void) async throws -> [CaptionWord] {
        let cache = MediaCache.shared
        for m in p.media where cache.runtimes[m.id] == nil { _ = await cache.prepare(m, background: false) }
        let b = CompositionBuilder.build(p, cache: cache)
        let tracks = b.audioTrackIDs.values.compactMap { b.composition.track(withTrackID: $0) }
        guard !tracks.isEmpty else { throw error("Nella timeline non c'è audio da trascrivere") }
        let mix = CompositionBuilder.audioMix(b, project: p)
        let total = max(0.1, b.composition.duration.seconds)

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw error("Lingua non supportata dal riconoscimento vocale: \(language)")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status("Scarico il modello vocale (\(locale.identifier))…")
            try await req.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw error("Formato audio non disponibile per il riconoscimento")
        }

        let reader = try AVAssetReader(asset: b.composition)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: format.settings)
        out.audioMix = mix
        guard reader.canAdd(out) else { throw error("Impossibile leggere l'audio della timeline") }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? error("Impossibile leggere l'audio della timeline") }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let collect = Task { () throws -> [CaptionWord] in
            var words: [CaptionWord] = []
            for try await r in transcriber.results {
                for run in r.text.runs {
                    guard let tr = run.audioTimeRange else { continue }
                    let s = String(r.text[run.range].characters)
                    let toks = s.split(whereSeparator: \.isWhitespace).map(String.init)
                    guard !toks.isEmpty else { continue }
                    // a run normally holds one word; if it holds more, share its time evenly
                    let d = tr.duration.seconds / Double(toks.count)
                    for (i, w) in toks.enumerated() {
                        words.append(CaptionWord(w: w, s: tr.start.seconds + d * Double(i), e: tr.start.seconds + d * Double(i + 1)))
                    }
                }
            }
            return words
        }
        try await analyzer.start(inputSequence: stream)
        status("Trascrivo l'audio… 0%")
        var lastPct = 0
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
            guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { continue }
            buf.frameLength = n
            try sb.copyPCMData(fromRange: 0..<Int(n), into: buf.mutableAudioBufferList)
            input.yield(AnalyzerInput(buffer: buf))
            let pct = Int(CMSampleBufferGetPresentationTimeStamp(sb).seconds / total * 100)
            if pct >= lastPct + 5 { lastPct = pct; status("Trascrivo l'audio… \(min(99, pct))%"); await Task.yield() }
        }
        input.finish()
        if reader.status == .failed { throw reader.error ?? error("Lettura audio non riuscita") }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collect.value.sorted { $0.s < $1.s }
    }
}

// MARK: - editor actions

extension Editor {
    func generateCaptions() {
        guard !transcribing else { return }
        transcribing = true
        status = "Trascrivo l'audio…"
        let p = project
        Task {
            defer { self.transcribing = false }
            do {
                let words = try await Transcriber.words(project: p, language: p.captionStyle.language) { [weak self] s in self?.status = s }
                guard !words.isEmpty else { status = "Nessuna parola riconosciuta"; return }
                let caps = Captions.chunks(words, maxWords: p.captionStyle.maxWords)
                edit { $0.captions = caps; $0.tracks.captionsHidden = false }
                selectedCaption = nil
                status = "Sottotitoli pronti: \(caps.count) frasi, \(words.count) parole"
            } catch {
                status = "Sottotitoli non riusciti: \(error.localizedDescription)"
            }
        }
    }

    func updateCaption(_ id: ID, key: String? = nil, _ change: (inout Caption) -> Void) {
        edit(key) { p in
            if let i = p.captions.firstIndex(where: { $0.id == id }) { change(&p.captions[i]) }
        }
    }

    func deleteCaption(_ id: ID) {
        edit { $0.captions.removeAll { $0.id == id } }
        if selectedCaption == id { selectedCaption = nil }
    }

    /// Razor on the captions lane: the words before `t` stay, the rest become a new caption.
    func splitCaption(_ id: ID, at t: Double) {
        guard let c = project.captions.first(where: { $0.id == id }), t > c.start + 0.05, t < c.end - 0.05 else { return }
        let left = c.words.filter { ($0.s + $0.e) / 2 < t }, right = c.words.filter { ($0.s + $0.e) / 2 >= t }
        guard !left.isEmpty, !right.isEmpty else { return }
        edit { p in
            guard let i = p.captions.firstIndex(where: { $0.id == id }) else { return }
            p.captions[i].words = left
            p.captions[i].end = t
            p.captions.append(Caption(start: t, end: c.end, words: right))
        }
    }

    func setCaptionWords(_ n: Int) {
        edit { p in
            p.captionStyle.maxWords = n
            if !p.captions.isEmpty { p.captions = Captions.regroup(p.captions, maxWords: n) }
        }
        selectedCaption = nil
    }

    func toggleCaptions() { edit { $0.tracks.captionsHidden.toggle() } }
}

extension Project {
    /// Captions that will be drawn (nil when hidden or none).
    var visibleCaptions: [Caption]? { tracks.captionsHidden || captions.isEmpty ? nil : captions }

    /// Ripple edits: remove `a..<b` from the captions and pull the later ones back.
    mutating func extractCaptions(_ a: Double, _ b: Double) {
        let d = b - a
        guard d > 1e-6 else { return }
        var out: [Caption] = []
        for var c in captions {
            if c.end <= a + 1e-6 { out.append(c); continue }
            if c.start >= b - 1e-6 { c.shift(-d); out.append(c); continue }
            c.words = c.words.compactMap { w in
                if (w.s + w.e) / 2 < a { return CaptionWord(w: w.w, s: w.s, e: min(w.e, a)) }
                if (w.s + w.e) / 2 >= b { return CaptionWord(w: w.w, s: max(w.s, b) - d, e: w.e - d) }
                return nil
            }
            guard !c.words.isEmpty else { continue }
            c.start = c.start < a ? c.start : a
            c.end = c.end > b ? c.end - d : a
            if c.end - c.start > 0.05 { out.append(c) }
        }
        captions = out
    }

    /// Shifts captions that start at or after `t` (speed changes).
    mutating func shiftCaptions(after t: Double, by d: Double) {
        for i in captions.indices where captions[i].start >= t - 1e-6 { captions[i].shift(d) }
    }

    /// Room a caption can move / grow into without touching its neighbours.
    func captionNeighbours(of c: Caption) -> (prevEnd: Double, nextStart: Double) {
        let others = captions.filter { $0.id != c.id }
        let prev = others.filter { $0.end <= c.start + 1e-6 }.map(\.end).max() ?? 0
        let next = others.filter { $0.start >= c.end - 1e-6 }.map(\.start).min() ?? .infinity
        return (prev, next)
    }
}
