import AppKit
import SwiftUI
import Combine

enum Lane: Equatable {
    case caption, title, video(Int), audio(Int)

    var track: Int {
        switch self {
        case .caption: return -1
        case .title: return TrackIndex.titles
        case .video(let i), .audio(let i): return i
        }
    }
}

/// Premiere-style timeline: ruler, S (captions) / T / V2 / V1 / A1 / A2 lanes, playhead, scrollbar.
final class TimelineNSView: NSView {
    let editor: Editor
    private var bag: Set<AnyCancellable> = []

    // layout
    private let headerW: CGFloat = 64
    private let rulerH: CGFloat = 24
    private let barH: CGFloat = 12
    private var lanes: [(Lane, CGFloat)] {
        [(Lane.caption, CGFloat(24)), (Lane.title, CGFloat(30))] + editor.project.lanes.reversed().map { (Lane.video($0), CGFloat($0 == 0 ? 56 : 46)) }
            + editor.project.lanes.map { (Lane.audio($0), CGFloat(40)) }
    }
    var requiredHeight: CGFloat { rulerH + barH + gapBetweenAV + lanes.reduce(0) { $0 + $1.1 } }
    private let gapBetweenAV: CGFloat = 6

    private var scrollT: Double = 0
    private var pps: Double { editor.pixelsPerSecond }
    private var lastPlayheadX: CGFloat = -1

    private enum Drag {
        case none, scrub, scrollbar(startX: CGFloat, startScroll: Double)
        case move(orig: [ID: Clip], anchorT: Double, anchorLane: Lane?, changed: Bool)
        case trim(orig: Clip, left: Bool, anchorT: Double, changed: Bool)
        /// rubber-band selection; the start is kept as a time so it stays put while the view auto-scrolls
        case marquee(startT: Double, startY: CGFloat, base: Set<ID>)
        case captionMove(orig: Caption, anchorT: Double, changed: Bool)
        case captionTrim(orig: Caption, left: Bool, anchorT: Double, changed: Bool)
    }
    private var marqueeRect: CGRect?
    private var drag: Drag = .none
    private var snapLine: Double?
    private var ghost: (start: Double, duration: Double, lane: Lane)?

    // colors
    private let bg = NSColor(srgbRed: 0.03, green: 0.07, blue: 0.11, alpha: 1)
    private let laneBG = NSColor(srgbRed: 0.05, green: 0.11, blue: 0.18, alpha: 1)
    private let headerBG = NSColor(srgbRed: 0.04, green: 0.09, blue: 0.15, alpha: 1)
    private let videoColor = NSColor(srgbRed: 0.20, green: 0.38, blue: 0.65, alpha: 1)
    private let audioColor = NSColor(srgbRed: 0.12, green: 0.45, blue: 0.30, alpha: 1)
    private let titleColor = NSColor(srgbRed: 0.62, green: 0.48, blue: 0.10, alpha: 1)
    private let captionColor = NSColor(srgbRed: 0.46, green: 0.30, blue: 0.72, alpha: 1)
    private let gold = NSColor(srgbRed: 1, green: 0.82, blue: 0.25, alpha: 1)
    private let playheadColor = NSColor(srgbRed: 0.90, green: 0.20, blue: 0.18, alpha: 1)

    init(editor: Editor) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.string, .fileURL])
        editor.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.syncHeight(); self?.needsDisplay = true } }.store(in: &bag)
        MediaCache.shared.$revision.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true } }.store(in: &bag)
        editor.clock.$time.sink { [weak self] t in self?.playheadMoved(t) }.store(in: &bag)
        editor.fitTimeline = { [weak self] in self?.fit() }
        editor.zoomTimeline = { [weak self] f in guard let self else { return }; self.setZoom(self.pps * f) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Keeps the view as tall as all its lanes, so the enclosing scroll view can scroll down to the last track
    /// (the number of lanes changes when a project with more tracks is opened).
    func syncHeight() {
        guard let sv = enclosingScrollView else { return }
        let h = max(sv.contentSize.height, requiredHeight)
        let w = max(100, sv.contentSize.width)
        if abs(frame.height - h) > 0.5 || abs(frame.width - w) > 0.5 { setFrameSize(NSSize(width: w, height: h)) }
    }

    private var scrollBag: Set<AnyCancellable> = []
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scrollBag.removeAll()
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        // ruler and scrollbar are pinned to the visible area: redraw while scrolling vertically
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: clip)
            .sink { [weak self] _ in self?.needsDisplay = true }.store(in: &scrollBag)
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: clip)
            .sink { [weak self] _ in self?.syncHeight(); self?.needsDisplay = true }.store(in: &scrollBag)
        DispatchQueue.main.async { [weak self] in self?.syncHeight() }
    }

    /// Top / bottom of the part of the timeline that is on screen (the view can be taller than its scroll view).
    private var topY: CGFloat { visibleRect.height > 0 ? visibleRect.minY : 0 }
    private var bottomY: CGFloat { visibleRect.height > 0 ? visibleRect.maxY : bounds.height }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - geometry

    private func x(_ t: Double) -> CGFloat { headerW + CGFloat((t - scrollT) * pps) }
    private func t(_ x: CGFloat) -> Double { Double(x - headerW) / pps + scrollT }
    private var visibleSeconds: Double { Double(bounds.width - headerW) / pps }
    private var contentSeconds: Double { max(editor.duration + visibleSeconds * 0.5, visibleSeconds) }

    private func laneRect(_ lane: Lane) -> CGRect {
        var y = rulerH
        for (l, h) in lanes {
            if case .audio(0) = l { y += gapBetweenAV }
            if l == lane { return CGRect(x: headerW, y: y, width: bounds.width - headerW, height: h) }
            y += h
        }
        return .zero
    }

    private func laneAt(_ y: CGFloat) -> Lane? {
        for (l, _) in lanes {
            let r = laneRect(l)
            if y >= r.minY && y < r.maxY { return l }
        }
        return nil
    }

    private var scrollbarRect: CGRect { CGRect(x: headerW, y: bottomY - barH, width: bounds.width - headerW, height: barH) }

    private func lanes(of c: Clip) -> [Lane] {
        if c.isTitle { return [.title] }
        guard let m = editor.project.media(c.mediaID) else { return [] }
        var out: [Lane] = []
        if m.hasVideo { out.append(.video(c.track)) }
        if m.hasAudio { out.append(.audio(c.track)) }
        return out
    }

    private func clipRect(_ c: Clip, _ lane: Lane) -> CGRect {
        let r = laneRect(lane)
        return CGRect(x: x(c.start), y: r.minY + 1, width: max(2, CGFloat(c.duration * pps)), height: r.height - 2)
    }

    private func captionRect(_ c: Caption) -> CGRect {
        let r = laneRect(.caption)
        return CGRect(x: x(c.start), y: r.minY + 1, width: max(2, CGFloat(c.duration * pps)), height: r.height - 2)
    }

    private func hitCaption(_ p: CGPoint) -> Caption? {
        guard laneAt(p.y) == .caption else { return nil }
        return editor.project.captions.last { captionRect($0).insetBy(dx: -3, dy: 0).contains(p) }
    }

    private func hitClip(_ p: CGPoint) -> Clip? {
        guard let lane = laneAt(p.y) else { return nil }
        return editor.project.clips.last { lanes(of: $0).contains(lane) && clipRect($0, lane).insetBy(dx: -3, dy: 0).contains(p) }
    }

    // MARK: - zoom / scroll

    /// Zoom always centred on the playhead (the time being played), whatever started it: pinch, ⌘/⌥-scroll,
    /// the zoom slider or the = / - keys. The playhead keeps its place on screen; if it was off screen it ends up
    /// in the middle of the timeline. `anchorX` is ignored on purpose.
    func setZoom(_ newPPS: Double, anchorX: CGFloat? = nil) {
        let ph = editor.clock.time
        let phx = x(ph)
        let ax = (phx >= headerW && phx <= bounds.width) ? phx : headerW + (bounds.width - headerW) / 2
        editor.pixelsPerSecond = min(800, max(1, newPPS))
        scrollT = max(0, ph - Double(ax - headerW) / pps)
        needsDisplay = true
    }

    func fit() {
        let w = Double(bounds.width - headerW - 30)
        guard w > 50 else { return }
        editor.pixelsPerSecond = min(800, max(1, w / max(editor.duration, 5)))
        scrollT = 0
        needsDisplay = true
    }

    private func clampScroll() { scrollT = max(0, min(scrollT, contentSeconds - visibleSeconds * 0.5)) }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
            let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
            setZoom(pps * exp(Double(d) * 0.01), anchorX: convert(e.locationInWindow, from: nil).x)
            return
        }
        if editor.project.lanes.count > 2 && abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX) && !e.modifierFlags.contains(.shift) {
            super.scrollWheel(with: e); return
        }
        var d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        if !e.hasPreciseScrollingDeltas { d *= 12 }
        scrollT -= Double(d) / pps
        clampScroll()
        needsDisplay = true
    }

    override func magnify(with e: NSEvent) {
        setZoom(pps * (1 + Double(e.magnification)), anchorX: convert(e.locationInWindow, from: nil).x)
    }

    private func playheadMoved(_ time: Double) {
        if editor.clock.isPlaying, bounds.width > headerW {
            let px = x(time)
            if px > bounds.width - 20 || px < headerW { scrollT = max(0, time - visibleSeconds * 0.1) }
        }
        let px = x(time).rounded()
        if px != lastPlayheadX { lastPlayheadX = px; needsDisplay = true }
    }

    // MARK: - snapping

    private func snapPoints(excluding ids: Set<ID>) -> [Double] {
        var pts = [0.0, editor.clock.time]
        for c in editor.project.clips where !ids.contains(c.id) { pts.append(c.start); pts.append(c.end) }
        return pts
    }

    /// Smallest correction that puts one of `edges` on a snap point, if within 8 px.
    private func snap(_ edges: [Double], excluding ids: Set<ID>) -> (delta: Double, at: Double)? {
        guard editor.snapping else { return nil }
        let limit = 8 / pps
        var best: (Double, Double)?
        for p in snapPoints(excluding: ids) {
            for e in edges where abs(p - e) < limit && abs(p - e) < abs(best?.0 ?? .infinity) { best = (p - e, p) }
        }
        return best
    }

    // MARK: - mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        snapLine = nil

        if scrollbarRect.contains(p) {
            let total = contentSeconds
            let thumbW = max(30, scrollbarRect.width * CGFloat(visibleSeconds / total))
            let thumbX = scrollbarRect.minX + (scrollbarRect.width - thumbW) * CGFloat(scrollT / max(0.001, total - visibleSeconds))
            if p.x < thumbX || p.x > thumbX + thumbW {   // click on the track: jump there
                scrollT = max(0, total * Double((p.x - scrollbarRect.minX) / scrollbarRect.width) - visibleSeconds / 2)
                clampScroll()
            }
            drag = .scrollbar(startX: p.x, startScroll: scrollT)
            needsDisplay = true
            return
        }
        if p.x < headerW { if p.y >= topY + rulerH { headerClick(p) }; return }
        if p.y < topY + rulerH {
            editor.pause()
            editor.seek(max(0, t(p.x)))
            drag = .scrub
            return
        }
        if laneAt(p.y) == .caption { captionMouseDown(p, e); return }
        if editor.selectedCaption != nil { editor.selectedCaption = nil }

        let clip = hitClip(p)
        if editor.tool == .razor {
            guard let clip else { return }
            var at = t(p.x)
            if editor.snapping, abs(x(editor.clock.time) - p.x) < 8 { at = editor.clock.time }
            editor.razor(clip.id, at: at, allTracks: e.modifierFlags.contains(.shift))
            return
        }

        let additive = e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.command)

        guard let clip else {
            // empty spot: a click selects the gap, a drag draws a selection rectangle
            if !additive { editor.selection = [] }
            if !additive, let lane = laneAt(p.y), let g = editor.project.gap(track: lane.track, at: t(p.x)) {
                editor.gap = GapSelection(track: lane.track, start: g.0, end: g.1)
            } else { editor.gap = nil }
            drag = .marquee(startT: t(p.x), startY: p.y, base: editor.selection)
            return
        }
        editor.gap = nil
        if e.clickCount == 2 { editor.selection = [clip.id]; editor.seek(max(clip.start, min(t(p.x), clip.end))); return }

        // edges trim, body moves
        let lane = laneAt(p.y)!
        let r = clipRect(clip, lane)
        let edge: CGFloat = min(7, r.width / 3)
        if abs(p.x - r.minX) <= edge || abs(p.x - r.maxX) <= edge {
            editor.selection = [clip.id]
            editor.beginInteraction()
            drag = .trim(orig: clip, left: abs(p.x - r.minX) < abs(p.x - r.maxX), anchorT: t(p.x), changed: false)
            return
        }
        if additive {
            if editor.selection.contains(clip.id) { editor.selection.remove(clip.id); drag = .none; return }
            editor.selection.insert(clip.id)
        } else if !editor.selection.contains(clip.id) {
            editor.selection = [clip.id]
        }
        let moving = editor.project.clips.filter { editor.selection.contains($0.id) }
        editor.beginInteraction()
        drag = .move(orig: Dictionary(uniqueKeysWithValues: moving.map { ($0.id, $0) }), anchorT: t(p.x), anchorLane: lane, changed: false)
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .none: break
        case .scrub:
            editor.seek(max(0, t(p.x)))
        case .scrollbar(let sx, let ss):
            scrollT = ss + Double(p.x - sx) / Double(scrollbarRect.width) * contentSeconds
            clampScroll()
            needsDisplay = true
        case .trim(let o, let left, let anchor, _):
            trimDrag(o, left: left, dt: t(p.x) - anchor)
            drag = .trim(orig: o, left: left, anchorT: anchor, changed: true)
        case .move(let orig, let anchor, let anchorLane, _):
            moveDrag(orig, dt: t(p.x) - anchor, from: anchorLane, to: laneAt(p.y))
            drag = .move(orig: orig, anchorT: anchor, anchorLane: anchorLane, changed: true)
        case .marquee(let startT, let startY, let base):
            marqueeDrag(to: p, startT: startT, startY: startY, base: base)
        case .captionMove(let o, let anchor, _):
            captionMoveDrag(o, dt: t(p.x) - anchor)
            drag = .captionMove(orig: o, anchorT: anchor, changed: true)
        case .captionTrim(let o, let left, let anchor, _):
            captionTrimDrag(o, left: left, dt: t(p.x) - anchor)
            drag = .captionTrim(orig: o, left: left, anchorT: anchor, changed: true)
        }
    }

    // MARK: - captions lane

    private func captionMouseDown(_ p: CGPoint, _ e: NSEvent) {
        guard let c = hitCaption(p) else {
            editor.selectedCaption = nil; editor.selection = []; editor.gap = nil
            return
        }
        if editor.tool == .razor {
            var at = t(p.x)
            if editor.snapping, abs(x(editor.clock.time) - p.x) < 8 { at = editor.clock.time }
            editor.splitCaption(c.id, at: at)
            return
        }
        editor.selectedCaption = c.id
        let r = captionRect(c)
        let edge: CGFloat = min(7, r.width / 3)
        editor.beginInteraction()
        if abs(p.x - r.minX) <= edge || abs(p.x - r.maxX) <= edge {
            drag = .captionTrim(orig: c, left: abs(p.x - r.minX) < abs(p.x - r.maxX), anchorT: t(p.x), changed: false)
        } else {
            drag = .captionMove(orig: c, anchorT: t(p.x), changed: false)
        }
    }

    private func captionMoveDrag(_ o: Caption, dt raw: Double) {
        guard let i = editor.project.captions.firstIndex(where: { $0.id == o.id }) else { return }
        let n = editor.project.captionNeighbours(of: o)
        var dt = raw
        if let sn = snap([o.start + dt, o.end + dt], excluding: []) { dt += sn.delta; snapLine = sn.at } else { snapLine = nil }
        dt = min(max(dt, n.prevEnd - o.start), n.nextStart - o.end)
        var c = o
        c.shift(dt)
        editor.project.captions[i] = c
    }

    private func captionTrimDrag(_ o: Caption, left: Bool, dt: Double) {
        guard let i = editor.project.captions.firstIndex(where: { $0.id == o.id }) else { return }
        let n = editor.project.captionNeighbours(of: o)
        var c = o
        if left {
            var s = o.start + dt
            if let sn = snap([s], excluding: []) { s += sn.delta; snapLine = sn.at } else { snapLine = nil }
            c.start = min(max(s, n.prevEnd), o.end - 0.1)
        } else {
            var en = o.end + dt
            if let sn = snap([en], excluding: []) { en += sn.delta; snapLine = sn.at } else { snapLine = nil }
            c.end = max(min(en, n.nextStart), o.start + 0.1)
        }
        // words keep their times, just kept inside the caption
        c.words = c.words.map { CaptionWord(w: $0.w, s: min(max($0.s, c.start), c.end), e: min(max($0.e, c.start), c.end)) }
        editor.project.captions[i] = c
    }

    private func marqueeDrag(to p: CGPoint, startT: Double, startY: CGFloat, base: Set<ID>) {
        // scroll when the pointer goes past the left / right edge
        let edge: CGFloat = 16
        if p.x > bounds.width - edge { scrollT += Double(p.x - (bounds.width - edge) + 2) / pps }
        if p.x < headerW + edge { scrollT -= Double(headerW + edge - p.x + 2) / pps }
        clampScroll()

        let sx = x(startT)
        let px = min(max(p.x, headerW), bounds.width)
        let top = topY + rulerH, bottom = bottomY - barH
        let r = CGRect(x: min(sx, px), y: max(top, min(startY, p.y)),
                       width: abs(px - sx), height: abs(min(max(p.y, top), bottom) - startY))
        // ignore tiny wiggles so a plain click still selects the gap
        guard marqueeRect != nil || r.width > 3 || r.height > 3 else { return }
        marqueeRect = r
        editor.gap = nil
        let t0 = t(r.minX), t1 = t(r.maxX)
        var hit = Set<ID>()
        for c in editor.project.clips where c.end > t0 && c.start < t1 {
            if lanes(of: c).contains(where: { clipRect(c, $0).intersects(r) }) { hit.insert(c.id) }
        }
        let sel = base.union(hit)
        if sel != editor.selection { editor.selection = sel }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        switch drag {
        case .move(let orig, _, _, let changed):
            let moved = changed && orig.values.contains { o in editor.project.clips.first { $0.id == o.id } != o }
            if moved { editor.commitMove(Set(orig.keys)) }
            editor.endInteraction(changed: moved)
        case .trim(let o, _, _, let changed):
            editor.endInteraction(changed: changed && editor.project.clips.first { $0.id == o.id } != o)
        case .captionMove(let o, _, let changed), .captionTrim(let o, _, _, let changed):
            let now = editor.project.captions.first { $0.id == o.id }
            let moved = changed && now != o
            editor.endInteraction(changed: moved)
            // a plain click shows the caption in the viewer
            if !moved, let c = now, !(c.start..<c.end).contains(editor.clock.time) {
                editor.pause()
                editor.seek(c.start + min(0.25, c.duration / 2))
            }
        default: break
        }
        drag = .none
        marqueeRect = nil
        snapLine = nil
        needsDisplay = true
    }

    private func trimDrag(_ o: Clip, left: Bool, dt: Double) {
        guard let i = editor.project.clips.firstIndex(where: { $0.id == o.id }) else { return }
        let n = editor.project.neighbours(of: o)
        let media = editor.project.media(o.mediaID)
        var c = o
        if left {
            var s = o.start + dt
            if let sn = snap([s], excluding: [o.id]) { s += sn.delta; snapLine = sn.at } else { snapLine = nil }
            let lo = max(n.prevEnd, media == nil ? 0 : o.start - o.sourceIn / o.speed)
            s = min(max(s, lo), o.end - minClipDuration)
            c.start = s
            c.duration = o.end - s
            if media != nil { c.sourceIn = o.sourceTime(at: s) }
        } else {
            var en = o.end + dt
            if let sn = snap([en], excluding: [o.id]) { en += sn.delta; snapLine = sn.at } else { snapLine = nil }
            var hi = n.nextStart
            if let m = media { hi = min(hi, o.start + (m.duration - o.sourceIn) / o.speed) }
            en = max(min(en, hi), o.start + minClipDuration)
            c.duration = en - o.start
        }
        editor.project.clips[i] = c
    }

    private func moveDrag(_ orig: [ID: Clip], dt rawDT: Double, from: Lane?, to: Lane?) {
        let earliest = orig.values.map(\.start).min() ?? 0
        var dt = max(rawDT, -earliest)
        let edges = orig.values.flatMap { [$0.start + dt, $0.end + dt] }
        if let sn = snap(edges, excluding: Set(orig.keys)) { dt = max(dt + sn.delta, -earliest); snapLine = sn.at } else { snapLine = nil }

        var dTrack = 0
        switch (from, to) {
        case (.video(let a)?, .video(let b)?), (.audio(let a)?, .audio(let b)?):
            dTrack = (editor.project.lanes.firstIndex(of: b) ?? 0) - (editor.project.lanes.firstIndex(of: a) ?? 0)
        default: break
        }
        let media = orig.values.filter { !$0.isTitle }
        if dTrack != 0, media.contains(where: { let i = editor.project.lanes.firstIndex(of: $0.track) ?? 0; return i + dTrack < 0 || i + dTrack >= editor.project.lanes.count }) { dTrack = 0 }

        var clips = editor.project.clips
        for i in clips.indices {
            guard let o = orig[clips[i].id] else { continue }
            clips[i].start = round6(o.start + dt)
            if !o.isTitle { clips[i].track = editor.project.lanes[(editor.project.lanes.firstIndex(of: o.track) ?? 0) + dTrack] }
        }
        editor.project.clips = clips
    }

    private func headerClick(_ p: CGPoint) {
        guard let lane = laneAt(p.y) else { return }
        switch lane {
        case .caption: editor.toggleCaptions()
        case .title: editor.toggleTitles()
        case .video(let i): editor.toggleVideo(i)
        case .audio(let i): editor.toggleAudio(i)
        }
    }

    // MARK: - cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func mouseMoved(with e: NSEvent) { updateCursor(convert(e.locationInWindow, from: nil)) }
    override func cursorUpdate(with e: NSEvent) { updateCursor(convert(e.locationInWindow, from: nil)) }

    private func updateCursor(_ p: CGPoint) {
        if p.x > headerW, let c = hitCaption(p) {
            if editor.tool == .razor { NSCursor.crosshair.set(); return }
            let r = captionRect(c)
            let edge: CGFloat = min(7, r.width / 3)
            (abs(p.x - r.minX) <= edge || abs(p.x - r.maxX) <= edge ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            return
        }
        guard p.x > headerW, p.y > topY + rulerH, let c = hitClip(p), let lane = laneAt(p.y) else { NSCursor.arrow.set(); return }
        if editor.tool == .razor { NSCursor.crosshair.set(); return }
        let r = clipRect(c, lane)
        let edge: CGFloat = min(7, r.width / 3)
        if abs(p.x - r.minX) <= edge || abs(p.x - r.maxX) <= edge { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
    }

    // MARK: - context menu

    override func menu(for e: NSEvent) -> NSMenu? {
        let p = convert(e.locationInWindow, from: nil)
        if let cap = hitCaption(p) {
            editor.selectedCaption = cap.id
            let at = t(p.x)
            let m = NSMenu()
            m.addItem(BlockMenuItem("Dividi qui") { [weak self] in self?.editor.splitCaption(cap.id, at: at) })
            m.addItem(BlockMenuItem("Elimina sottotitolo") { [weak self] in self?.editor.deleteCaption(cap.id) })
            return m
        }
        guard let c = hitClip(p) else { return nil }
        if !editor.selection.contains(c.id) { editor.selection = [c.id] }
        let at = t(p.x)
        let m = NSMenu()
        m.addItem(BlockMenuItem("Taglia qui") { [weak self] in self?.editor.razor(c.id, at: at, allTracks: false) })
        m.addItem(BlockMenuItem("Elimina") { [weak self] in self?.editor.deleteSelection(ripple: false) })
        m.addItem(BlockMenuItem("Elimina e chiudi lo spazio") { [weak self] in self?.editor.deleteSelection(ripple: true) })
        m.addItem(.separator())
        m.addItem(BlockMenuItem("Copia") { [weak self] in self?.editor.copy() })
        return m
    }

    // MARK: - drag & drop from the bin / Finder

    private func dropInfo(_ s: NSDraggingInfo) -> (media: MediaItem?, urls: [URL], start: Double, lane: Lane)? {
        let p = convert(s.draggingLocation, from: nil)
        var lane = laneAt(p.y) ?? .video(0)
        if lane == .title || lane == .caption { lane = .video(0) }
        var start = max(0, t(p.x))
        var media: MediaItem?
        if let str = s.draggingPasteboard.string(forType: .string), str.hasPrefix("elitemedia:") {
            media = editor.project.media(String(str.dropFirst("elitemedia:".count)))
        }
        let urls = (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if media == nil && urls.isEmpty { return nil }
        if let m = media, let sn = snap([start, start + m.duration], excluding: []) { start = max(0, start + sn.delta); snapLine = sn.at } else { snapLine = nil }
        return (media, urls, start, lane)
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }

    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        guard let d = dropInfo(s) else { ghost = nil; needsDisplay = true; return [] }
        ghost = (d.start, d.media?.duration ?? 2, d.lane)
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ s: NSDraggingInfo?) { ghost = nil; snapLine = nil; needsDisplay = true }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        defer { ghost = nil; snapLine = nil; needsDisplay = true }
        guard let d = dropInfo(s) else { return false }
        if let m = d.media {
            editor.place(m.id, at: d.start, track: d.lane.track)
            return true
        }
        let editor = self.editor
        Task { @MainActor in
            var at = d.start
            for id in await editor.importMedia(d.urls) {
                guard let m = editor.project.media(id) else { continue }
                editor.place(id, at: at, track: d.lane.track)
                at += m.duration
            }
        }
        return true
    }

    // MARK: - drawing

    override func draw(_ dirty: NSRect) {
        bg.setFill(); bounds.fill()
        let p = editor.project
        let tracks = p.tracks

        // lanes
        for (lane, _) in lanes {
            let r = laneRect(lane)
            laneBG.setFill()
            r.insetBy(dx: 0, dy: 0.5).fill()
        }

        if let g = editor.gap {
            let lane: Lane = g.track == TrackIndex.titles ? .title : .video(g.track)
            let r = laneRect(lane)
            NSColor(white: 1, alpha: 0.12).setFill()
            CGRect(x: x(g.start), y: r.minY, width: CGFloat((g.end - g.start) * pps), height: r.height).fill()
        }

        // clips
        let vis0 = scrollT, vis1 = scrollT + visibleSeconds
        NSGraphicsContext.current?.saveGraphicsState()
        CGRect(x: headerW, y: 0, width: bounds.width - headerW, height: bounds.height).clip()
        for c in p.clips where c.end >= vis0 && c.start <= vis1 {
            for lane in lanes(of: c) {
                let dim: Bool
                switch lane {
                case .caption: dim = tracks.captionsHidden
                case .title: dim = tracks.titlesHidden
                case .video(let i): dim = tracks.videoHidden[i]
                case .audio(let i): dim = tracks.audioMuted[i]
                }
                drawClip(c, lane: lane, dim: dim)
            }
        }
        for c in p.captions where c.end >= vis0 && c.start <= vis1 { drawCaption(c, dim: tracks.captionsHidden) }
        if let g = ghost {
            let r = laneRect(g.lane)
            let gr = CGRect(x: x(g.start), y: r.minY + 1, width: CGFloat(g.duration * pps), height: r.height - 2)
            gold.withAlphaComponent(0.25).setFill(); gr.fill()
            gold.setStroke(); NSBezierPath(rect: gr).stroke()
        }
        if let s = snapLine {
            gold.setFill()
            CGRect(x: x(s) - 0.5, y: topY + rulerH, width: 1, height: bottomY - topY - rulerH - barH).fill()
        }
        if let m = marqueeRect {
            NSColor(white: 1, alpha: 0.08).setFill(); m.fill()
            NSColor(white: 1, alpha: 0.7).setStroke()
            let b = NSBezierPath(rect: m.insetBy(dx: 0.5, dy: 0.5))
            b.lineWidth = 1
            b.setLineDash([4, 3], count: 2, phase: 0)
            b.stroke()
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        drawHeaders()
        drawRuler()
        drawScrollbar()

        // playhead
        let px = x(editor.clock.time)
        if px >= headerW {
            playheadColor.setFill()
            let y0 = topY
            CGRect(x: px - 0.5, y: y0 + rulerH - 6, width: 1.5, height: bottomY - y0 - rulerH - barH + 6).fill()
            let head = NSBezierPath()
            head.move(to: CGPoint(x: px - 6, y: y0 + 2)); head.line(to: CGPoint(x: px + 6, y: y0 + 2))
            head.line(to: CGPoint(x: px + 6, y: y0 + rulerH - 10)); head.line(to: CGPoint(x: px, y: y0 + rulerH - 4))
            head.line(to: CGPoint(x: px - 6, y: y0 + rulerH - 10)); head.close()
            head.fill()
        }
    }

    private func drawClip(_ c: Clip, lane: Lane, dim: Bool) {
        let r = clipRect(c, lane)
        let selected = editor.selection.contains(c.id)
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        let alpha: CGFloat = dim ? 0.35 : 1
        let media = editor.project.media(c.mediaID)

        switch lane {
        case .caption: break
        case .title:
            titleColor.withAlphaComponent(alpha).setFill(); r.fill()
            let name = c.title?.names.replacingOccurrences(of: "\n", with: " · ") ?? ""
            label("T  " + name, in: r, color: .white)
        case .video:
            videoColor.withAlphaComponent(alpha).setFill(); r.fill()
            if let m = media, m.width > 0 {
                let tileW = max(24, min(140, r.height * CGFloat(m.width / m.height)))
                var tx = r.minX
                let ctx = NSGraphicsContext.current!.cgContext
                while tx < r.maxX {
                    if tx + tileW >= headerW && tx <= bounds.width,
                       let img = MediaCache.shared.thumbnail(m.id, at: c.sourceIn + Double(tx - r.minX) / pps * c.speed) {
                        let tr = CGRect(x: tx, y: r.minY, width: tileW, height: r.height)
                        ctx.saveGState()
                        ctx.translateBy(x: 0, y: tr.maxY + tr.minY); ctx.scaleBy(x: 1, y: -1)   // CGImage draws upside-down in a flipped view
                        ctx.setAlpha(alpha * 0.9)
                        ctx.draw(img, in: aspectFill(img, tr))
                        ctx.restoreGState()
                    }
                    tx += tileW
                }
            }
            label((c.speed != 1 ? "\(speedLabel(c.speed))  " : "") + (media?.name ?? "offline"), in: r, color: .white)
        case .audio:
            audioColor.withAlphaComponent(alpha).setFill(); r.fill()
            if let m = media, MediaCache.shared.hasPeaks(m.id) {
                NSColor(srgbRed: 0.6, green: 0.95, blue: 0.7, alpha: 0.85 * alpha).setFill()
                let mid = r.midY, half = (r.height - 6) / 2
                let x0 = max(r.minX, headerW), x1 = min(r.maxX, bounds.width)
                var xx = x0
                let gain = CGFloat(min(2, c.volume))
                while xx < x1 {
                    let s0 = c.sourceIn + Double(xx - r.minX) / pps * c.speed
                    let v = CGFloat(MediaCache.shared.peak(m.id, from: s0, to: s0 + 2 * c.speed / pps)) * gain
                    let h = max(0.5, min(1, v) * half)
                    CGRect(x: xx, y: mid - h, width: 1.5, height: h * 2).fill()
                    xx += 2
                }
            }
            if media?.hasVideo == false { label(media?.name ?? "", in: r, color: .white) }
            var tags: [String] = []
            if c.volume != 1 { tags.append("\(Int((c.volume * 100).rounded()))%") }
            if !tags.isEmpty { label(tags.joined(separator: " · "), in: r.offsetBy(dx: 0, dy: r.height - 16), color: .white) }
        }
        NSGraphicsContext.current?.restoreGraphicsState()
        (selected ? NSColor.white : NSColor(white: 0, alpha: 0.5)).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()
    }

    private func drawCaption(_ c: Caption, dim: Bool) {
        let r = captionRect(c)
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        captionColor.withAlphaComponent(dim ? 0.35 : 1).setFill(); r.fill()
        label(c.text, in: r, color: .white)
        NSGraphicsContext.current?.restoreGraphicsState()
        let selected = editor.selectedCaption == c.id
        (selected ? NSColor.white : NSColor(white: 0, alpha: 0.5)).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()
    }

    private func aspectFill(_ img: CGImage, _ r: CGRect) -> CGRect {
        let s = max(r.width / CGFloat(img.width), r.height / CGFloat(img.height))
        let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    private func label(_ s: String, in r: CGRect, color: NSColor) {
        guard r.width > 24 else { return }
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: color]
        let str = s as NSString
        let size = str.size(withAttributes: a)
        let lx = max(r.minX, headerW) + 4
        let w = min(size.width + 6, r.maxX - lx)
        guard w > 10 else { return }
        NSColor(white: 0, alpha: 0.45).setFill()
        CGRect(x: lx - 2, y: r.minY + 2, width: w, height: size.height + 1).fill()
        str.draw(in: CGRect(x: lx + 1, y: r.minY + 2, width: w - 4, height: size.height + 1), withAttributes: a)
    }

    private func drawHeaders() {
        headerBG.setFill()
        CGRect(x: 0, y: 0, width: headerW, height: bounds.height).fill()
        let t = editor.project.tracks
        for (lane, _) in lanes {
            let r = laneRect(lane)
            let hr = CGRect(x: 0, y: r.minY, width: headerW, height: r.height)
            let name: String, symbol: String, off: Bool
            switch lane {
            case .caption: name = "S"; off = t.captionsHidden; symbol = off ? "eye.slash" : "eye"
            case .title: name = "T"; off = t.titlesHidden; symbol = off ? "eye.slash" : "eye"
            case .video(let i): name = "V\(Project.trackNumber(i))"; off = t.videoHidden[i]; symbol = off ? "eye.slash" : "eye"
            case .audio(let i): name = "A\(Project.trackNumber(i))"; off = t.audioMuted[i]; symbol = off ? "speaker.slash" : "speaker.wave.2"
            }
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor(white: 1, alpha: 0.8)]
            (name as NSString).draw(at: CGPoint(x: 8, y: hr.midY - 7), withAttributes: a)
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let tinted = img.withSymbolConfiguration(.init(pointSize: 11, weight: .medium).applying(.init(paletteColors: [off ? playheadColor : NSColor(white: 1, alpha: 0.55)])))
                tinted?.draw(in: CGRect(x: 34, y: hr.midY - 7, width: 18, height: 14))
            }
            NSColor(white: 1, alpha: 0.06).setFill()
            CGRect(x: 0, y: hr.maxY - 1, width: headerW, height: 1).fill()
        }
    }

    private func drawRuler() {
        let y0 = topY          // the ruler stays at the top of the visible area
        headerBG.setFill()
        CGRect(x: 0, y: y0, width: bounds.width, height: rulerH).fill()
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.55)]
        let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        let major = steps.first { $0 * pps >= 70 } ?? 3600
        let minor = major / 5
        NSColor(white: 1, alpha: 0.3).setFill()
        var i = Int((scrollT / minor).rounded(.down))
        let end = scrollT + visibleSeconds
        while Double(i) * minor <= end {
            let tt = Double(i) * minor
            let px = x(tt)
            let isMajor = i % 5 == 0
            if px >= headerW {
                CGRect(x: px, y: y0 + (isMajor ? rulerH - 10 : rulerH - 4), width: 1, height: isMajor ? 10 : 4).fill()
                if isMajor {
                    let r = (tt * 100).rounded() / 100
                    let s = major < 1 ? String(format: "%@.%02d", formatShort(r), Int((r * 100).rounded()) % 100) : formatShort(r + 0.001)
                    (s as NSString).draw(at: CGPoint(x: px + 3, y: y0 + 3), withAttributes: a)
                }
            }
            i += 1
        }
        for marker in editor.project.markers where marker.t >= scrollT && marker.t <= end {
            let px = x(marker.t)
            let hex = marker.color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            let value = UInt32(hex, radix: 16) ?? 0xe4ca4a
            let color = NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                                green: CGFloat((value >> 8) & 255) / 255,
                                blue: CGFloat(value & 255) / 255, alpha: 1)
            color.setStroke()
            let line = NSBezierPath(); line.move(to: CGPoint(x: px, y: rulerH)); line.line(to: CGPoint(x: px, y: bounds.height - barH)); line.stroke()
            color.setFill()
            let triangle = NSBezierPath(); triangle.move(to: CGPoint(x: px - 5, y: 1)); triangle.line(to: CGPoint(x: px + 5, y: 1)); triangle.line(to: CGPoint(x: px, y: 9)); triangle.close(); triangle.fill()
            if !marker.name.isEmpty {
                (marker.name as NSString).draw(at: CGPoint(x: px + 6, y: 2), withAttributes: a)
            }
        }
        NSColor(white: 1, alpha: 0.15).setFill()
        CGRect(x: 0, y: y0 + rulerH - 1, width: bounds.width, height: 1).fill()
    }

    private func drawScrollbar() {
        let r = scrollbarRect
        headerBG.setFill(); CGRect(x: 0, y: r.minY, width: bounds.width, height: r.height).fill()
        let total = contentSeconds
        let w = max(30, r.width * CGFloat(min(1, visibleSeconds / total)))
        let xx = r.minX + (r.width - w) * CGFloat(min(1, scrollT / max(0.001, total - visibleSeconds)))
        NSColor(white: 1, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: CGRect(x: xx, y: r.minY + 3, width: w, height: r.height - 6), xRadius: 3, yRadius: 3).fill()
    }
}

func speedLabel(_ s: Double) -> String {
    let v = (s * 100).rounded() / 100
    return (v == v.rounded() ? String(Int(v)) : String(format: "%g", v)) + "×"
}

final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void
    init(_ title: String, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { block() }
}

struct TimelineView: NSViewRepresentable {
    let editor: Editor
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let v = TimelineNSView(editor: editor); v.frame = CGRect(x: 0, y: 0, width: 700, height: v.requiredHeight)
        v.autoresizingMask = [.width]; scroll.documentView = v
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let v = scroll.documentView as? TimelineNSView else { return }
        v.syncHeight()
        v.needsDisplay = true
    }
}
