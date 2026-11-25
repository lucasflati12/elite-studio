import Foundation
import AVFoundation
import AppKit
import Combine
import UniformTypeIdentifiers
import ImageIO

/// Playhead + play state, kept apart so 30 fps updates don't redraw the whole window.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
    @Published var isPlaying = false
}

enum Tool { case select, razor }

struct GapSelection: Equatable { var track: Int; var start: Double; var end: Double }

struct ExportState {
    var url: URL
    var progress: Double = 0
    var done = false
    var error: String?
}

@MainActor
final class Editor: ObservableObject {
    static let shared = Editor()

    @Published var project = Project() { didSet { projectDidChange() } }
    @Published var selection: Set<ID> = [] {
        didSet {
            if !selection.isEmpty { selectedMediaID = nil; selectedCaption = nil }
        }
    }
    @Published var selectedMediaID: ID? = nil {
        didSet {
            if selectedMediaID != nil { selection = []; gap = nil; selectedCaption = nil }
        }
    }
    /// A caption picked on the captions lane (kept apart from clip selection).
    @Published var selectedCaption: ID? = nil {
        didSet {
            if selectedCaption != nil { selection = []; gap = nil; selectedMediaID = nil }
        }
    }
    @Published var transcribing = false
    @Published var gap: GapSelection?
    @Published var tool: Tool = .select
    @Published var snapping = true
    @Published var pixelsPerSecond: Double = 40
    @Published var projectURL: URL?
    @Published var export: ExportState?
    @Published var status = ""

    let clock = PlaybackClock()
    let player = AVPlayer()
    let cache = MediaCache.shared
    var fitTimeline: (() -> Void)?
    var zoomTimeline: ((Double) -> Void)?

    /// While a drag is in progress the player isn't rebuilt (only on mouse up).
    var interacting = false
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var coalesce: (key: String, at: Date)?
    private var built: BuiltComposition?
    private var builtStructure: [String] = []
    private var builtLook: [String] = []
    private var syncScheduled = false
    private var saveScheduled = false
    private var clipboard: [Clip] = []
    private var exportTask: Task<Void, Never>?
    private var bag: Set<AnyCancellable> = []

    static let fileType = UTType(filenameExtension: "elitestudio") ?? .json

    init() {
        player.actionAtItemEnd = .pause
        player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.seeking, self.seekTarget == nil, self.player.rate != 0 else { return }
                self.clock.time = t.seconds
            }
        }
        player.publisher(for: \.rate).receive(on: RunLoop.main).sink { [weak self] r in
            self?.clock.isPlaying = r != 0
        }.store(in: &bag)
    }

    var duration: Double { project.duration }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - undo / edits

    /// Saves an undo point. Calls with the same `key` within 1.5 s share one undo step (sliders, typing).
    func checkpoint(_ key: String? = nil) {
        if let key, let c = coalesce, c.key == key, Date().timeIntervalSince(c.at) < 1.5 {
            coalesce = (key, Date()); return
        }
        undoStack.append(project)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
        coalesce = key.map { ($0, Date()) }
    }

    func edit(_ key: String? = nil, _ change: (inout Project) -> Void) {
        checkpoint(key)
        change(&project)
        cleanSelection()
    }

    func undo() {
        guard let p = undoStack.popLast() else { return }
        redoStack.append(project); coalesce = nil
        project = p; cleanSelection()
    }

    func redo() {
        guard let p = redoStack.popLast() else { return }
        undoStack.append(project); coalesce = nil
        project = p; cleanSelection()
    }

    private func cleanSelection() {
        let ids = Set(project.clips.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        if let c = selectedCaption, !project.captions.contains(where: { $0.id == c }) { selectedCaption = nil }
    }

    func beginInteraction() { checkpoint(); interacting = true }
    func endInteraction(changed: Bool) {
        interacting = false
        if !changed { _ = undoStack.popLast() }
        scheduleSync()
    }

    // MARK: - player sync

    private func projectDidChange() {
        scheduleAutosave()
        if !interacting { scheduleSync() }
    }

    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.syncScheduled = false
            self?.syncPlayer()
        }
    }

    private func structureKey() -> [String] {
        let t = project.tracks
        return project.clips.filter { !$0.isTitle }.map {
            "\($0.id)|\($0.mediaID ?? "")|\($0.track)|\(CompositionBuilder.ticks($0.start))|\(CompositionBuilder.ticks($0.duration))|\(CompositionBuilder.ticks($0.sourceIn))|\($0.speed)"
        }.sorted() + ["\(t.videoHidden)\(t.audioMuted)", "\(project.media.map(\.id))", "\(cache.runtimes.count)"]
    }

    private func lookKey() -> [String] {
        project.clips.filter { !$0.isTitle }.map { "\($0.id)|\($0.volume)|\($0.opacity)|\($0.scale)|\($0.fill)|\($0.offsetX)|\($0.offsetY)|\($0.effects.hashValue)|\(String(describing: $0.reframe))" }.sorted()
            + ["\(project.settings.width)x\(project.settings.height)@\(project.settings.fps)",
               "\(project.visibleCaptions?.hashValue ?? 0)|\(project.captionStyle.hashValue)"]
    }

    private func syncPlayer() {
        let missing = project.media.filter { cache.runtimes[$0.id] == nil && !cache.failed.contains($0.id) }
        if !missing.isEmpty {
            Task {
                for m in missing { _ = await cache.prepare(m) }
                self.syncPlayer()
            }
            return
        }
        let s = structureKey(), l = lookKey()
        if s != builtStructure || built == nil {
            let b = CompositionBuilder.build(project, cache: cache)
            let item = AVPlayerItem(asset: b.composition)
            item.audioTimePitchAlgorithm = .spectral     // sped-up / slowed-down clips keep their pitch
            item.videoComposition = CompositionBuilder.videoComposition(b, project: project, cache: cache)
            item.audioMix = CompositionBuilder.audioMix(b, project: project)
            let rate = player.rate
            player.replaceCurrentItem(with: item)
            built = b
            builtStructure = s; builtLook = l
            seek(clock.time)
            if rate != 0 { player.rate = rate }
        } else if l != builtLook, let b = built, let item = player.currentItem {
            item.videoComposition = CompositionBuilder.videoComposition(b, project: project, cache: cache)
            item.audioMix = CompositionBuilder.audioMix(b, project: project)
            builtLook = l
            if player.rate == 0 { seek(clock.time) }   // redraw the paused frame
        }
    }

    // MARK: - transport

    private var seeking = false
    private var seekTarget: Double?

    func seek(_ t: Double) {
        let t = max(0, t)
        clock.time = t
        seekTarget = t
        if !seeking { performSeek() }
    }

    private func performSeek() {
        guard let t = seekTarget else { return }
        seekTarget = nil
        seeking = true
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seeking = false
                if self.seekTarget != nil { self.performSeek() }
            }
        }
    }

    func togglePlay() { player.rate == 0 ? play() : pause() }

    func play(rate: Float = 1) {
        if rate > 0, clock.time >= duration - 0.05 { seek(0) }
        if rate < 0, !(player.currentItem?.canPlayReverse ?? false) { return }
        player.rate = rate
    }

    func pause() { player.pause() }

    /// L / J: each press goes 1x → 2x → 4x in that direction.
    func shuttle(_ dir: Float) {
        let r = player.rate
        if r != 0, (r > 0) == (dir > 0) { play(rate: min(abs(r) * 2, 8) * dir) } else { play(rate: dir) }
    }

    func step(frames: Int) {
        pause()
        seek(clock.time + Double(frames) / Double(project.settings.fps))
    }

    func jumpEdit(forward: Bool) {
        pause()
        let t = clock.time, pts = project.editPoints
        if forward { seek(pts.first { $0 > t + 1e-4 } ?? t) } else { seek(pts.last { $0 < t - 1e-4 } ?? 0) }
    }

    // MARK: - media

    /// Imports files and folders (folders are scanned one level deep). Returns the ids, in order.
    @discardableResult
    func importMedia(_ urls: [URL]) async -> [ID] {
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let list = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                files += list.filter(MediaCache.isSupported).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if MediaCache.isSupported(u) { files.append(u) }
        }
        var ids: [ID] = []
        var added: [MediaItem] = []
        for f in files {
            do {
                // a photo is imported as a short video made from it
                let still = StillMaker.isImage(f)
                let file = still ? try await StillMaker.video(for: f, in: StillMaker.folder(projectFolder: projectURL?.deletingLastPathComponent())) : f
                if let m = project.media.first(where: { $0.url.standardizedFileURL == file.standardizedFileURL }) { ids.append(m.id); continue }
                var m = try await cache.probe(file)
                if still { m.still = true; m.name = f.lastPathComponent }
                added.append(m); ids.append(m.id)
            } catch { status = error.localizedDescription }
        }
        if !added.isEmpty {
            edit { $0.media += added }
            status = "Importati \(added.count) file"
        }
        return ids
    }

    func removeMedia(_ id: ID) {
        cache.forget(id)
        if selectedMediaID == id { selectedMediaID = nil }
        edit { p in
            p.media.removeAll { $0.id == id }
            p.clips.removeAll { $0.mediaID == id }
        }
    }

    func removeMissingMedia() {
        let missing = project.media.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        for m in missing {
            removeMedia(m.id)
        }
        if !missing.isEmpty {
            status = "Rimossi \(missing.count) file non trovati"
        }
    }

    func removeUnusedMedia() {
        let usedIDs = Set(project.clips.compactMap(\.mediaID))
        let unused = project.media.filter { !usedIDs.contains($0.id) }
        for m in unused {
            removeMedia(m.id)
        }
        if !unused.isEmpty {
            status = "Rimossi \(unused.count) file non utilizzati"
        }
    }

    // MARK: - placing clips

    private func adaptFormatIfNeeded(to m: MediaItem) {
        guard !project.settings.customized, project.clips.isEmpty, m.hasVideo, m.width > 0 else { return }
        let ar = m.width / m.height
        if ar < 0.9 { project.settings.width = 1080; project.settings.height = 1920 }
        else if ar > 1.1 { project.settings.width = 1920; project.settings.height = 1080 }
        else { project.settings.width = 1080; project.settings.height = 1080 }
    }

    /// Drops a media item on the timeline, overwriting whatever is there (like Premiere).
    @discardableResult
    func place(_ mediaID: ID, at t: Double, track: Int, sourceIn: Double = 0, duration: Double? = nil) -> ID? {
        guard let m = project.media(mediaID) else { return nil }
        let d = duration ?? (m.still ? min(StillMaker.defaultDuration, m.duration) : m.duration - sourceIn)
        guard d > minClipDuration else { return nil }
        var c = Clip(mediaID: mediaID, track: project.lanes.contains(track) ? track : 0, start: max(0, t), duration: d, sourceIn: sourceIn)
        c.start = round6(c.start)
        checkpoint()
        adaptFormatIfNeeded(to: m)
        project.overwrite(c.start, c.end, track: c.track)
        project.clips.append(c)
        selection = [c.id]
        return c.id
    }

    func append(_ mediaID: ID) {
        place(mediaID, at: project.trackEnd(TrackIndex.main), track: TrackIndex.main)
    }

    func addTitle() {
        let t = clock.time
        var c = Clip(title: TitleCard(), track: TrackIndex.titles, start: t, duration: 3)
        // reuse the style of the last title
        if let last = project.clips.last(where: { $0.isTitle })?.title {
            c.title = last
            c.title?.names = "Nome Cognome"
        }
        edit { p in
            p.overwrite(c.start, c.end, track: TrackIndex.titles)
            p.clips.append(c)
        }
        selection = [c.id]
    }

    /// After a drag: moved clips win over whatever they now overlap.
    func commitMove(_ ids: Set<ID>) {
        for c in project.clips.filter({ ids.contains($0.id) }) {
            project.overwrite(c.start, c.end, track: c.track, except: ids)
        }
    }

    // MARK: - cut / delete

    func clipsUnderPlayhead() -> [Clip] {
        let t = clock.time
        return project.clips.filter { $0.start < t - 1e-4 && $0.end > t + 1e-4 }
    }

    /// Cmd+K: cut the selected clips under the playhead, or every clip under it.
    func addEdit() {
        let under = clipsUnderPlayhead()
        let sel = under.filter { selection.contains($0.id) }
        let targets = sel.isEmpty ? under : sel
        guard !targets.isEmpty else { return }
        let t = clock.time
        edit { p in for c in targets { p.split(c.id, at: t) } }
    }

    func addMarker() {
        let marker = TimelineMarker(t: max(0, clock.time), name: "", color: "#e4ca4a")
        edit { p in p.markers.removeAll { abs($0.t - marker.t) < 0.03 }; p.markers.append(marker); p.markers.sort { $0.t < $1.t } }
    }

    func jumpMarker(_ forward: Bool) {
        let list = project.markers.map(\.t).sorted()
        guard !list.isEmpty else { return }
        let target = forward ? list.first(where: { $0 > clock.time + 0.02 }) ?? list[0] : list.last(where: { $0 < clock.time - 0.02 }) ?? list[list.count - 1]
        seek(target)
    }

    func editMarkerAtPlayhead() {
        guard let index = project.markers.indices.min(by: { abs(project.markers[$0].t - clock.time) < abs(project.markers[$1].t - clock.time) }),
              abs(project.markers[index].t - clock.time) < 0.5 else { status = "Nessun marker vicino al playhead"; return }
        var marker = project.markers[index]
        let name = NSTextField(string: marker.name); name.placeholderString = "Nome marker"
        let color = NSTextField(string: marker.color); color.placeholderString = "#e4ca4a"
        let box = NSStackView(views: [name, color]); box.orientation = .vertical; box.spacing = 8
        let alert = NSAlert(); alert.messageText = "Modifica marker"; alert.accessoryView = box
        alert.addButton(withTitle: "Salva"); alert.addButton(withTitle: "Elimina"); alert.addButton(withTitle: "Annulla")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            marker.name = name.stringValue; marker.color = color.stringValue
            edit { p in p.markers[index] = marker }
        case .alertSecondButtonReturn: edit { $0.markers.remove(at: index) }
        default: break
        }
    }

    func editSpeedAndRamp() {
        guard let c = project.clips.first(where: { selection.contains($0.id) && !$0.isTitle }) else { status = "Seleziona una clip"; return }
        let alert = NSAlert(); alert.messageText = "Velocità / Durata"; alert.informativeText = "La velocità viene salvata come moltiplicatore nel progetto condiviso."
        let box = NSStackView(); box.orientation = .vertical; box.spacing = 8; box.frame = CGRect(x: 0, y: 0, width: 260, height: 86)
        let speed = NSSlider(value: c.speed, minValue: 0.1, maxValue: 16, target: nil, action: nil)
        let label = NSTextField(labelWithString: speedLabel(c.speed)); speed.target = label; speed.action = #selector(NSTextField.takeFloatValueFrom(_:))
        let preset = NSPopUpButton(frame: .zero, pullsDown: false); preset.addItems(withTitles: ["Velocità costante", "Montagna", "Bullet", "Ingresso veloce", "Uscita veloce"])
        box.addArrangedSubview(speed); box.addArrangedSubview(label); box.addArrangedSubview(preset); alert.accessoryView = box
        alert.addButton(withTitle: "Applica"); alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let chosen = speed.doubleValue
        if preset.indexOfSelectedItem == 0 { edit { $0.setSpeed(c.id, chosen) }; return }
        let speeds: [Double]
        switch preset.titleOfSelectedItem {
        case "Montagna": speeds = [0.5, 2, 0.5]
        case "Bullet": speeds = [0.5, 4, 0.5]
        case "Ingresso veloce": speeds = [3, 1.5, 1]
        default: speeds = [1, 1.5, 3]
        }
        edit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == c.id }) else { return }
            let following = Set(p.clips.filter { $0.id != c.id && $0.start >= c.end - 1e-6 }.map(\.id))
            let sourceLength = c.sourceDuration, part = sourceLength / 3
            p.clips.remove(at: i)
            var cursor = c.start
            for n in 0..<3 {
                var seg = c; seg.id = n == 0 ? c.id : newID(); seg.sourceIn = c.sourceIn + Double(n) * part
                seg.speed = speeds[n]; seg.duration = part / speeds[n]; seg.start = cursor
                seg.speedRamp = SpeedRamp(preset: preset.titleOfSelectedItem ?? "Montagna", segment: n, points: speeds)
                cursor += seg.duration; p.clips.append(seg)
            }
            let delta = cursor - c.end
            for j in p.clips.indices where following.contains(p.clips[j].id) { p.clips[j].start += delta }
            p.shiftCaptions(after: c.end, by: delta)
        }
    }

    func toggleNoiseReduction() {
        guard let c = project.clips.first(where: { selection.contains($0.id) }) else { return }
        edit { p in if let i = p.clips.firstIndex(where: { $0.id == c.id }) { p.clips[i].noiseReduction.toggle() } }
        status = "Riduzione rumore disponibile solo export Windows"
    }

    func toggleAudioDisabled() {
        guard let c = project.clips.first(where: { selection.contains($0.id) }) else { return }
        edit { p in if let i = p.clips.firstIndex(where: { $0.id == c.id }) { p.clips[i].audioDisabled.toggle() } }
    }

    func addTransition() {
        guard let c = project.clips.first(where: { selection.contains($0.id) && !$0.isTitle }) else { return }
        let a = NSAlert(); a.messageText = "Transizione"; a.addButton(withTitle: "Applica"); a.addButton(withTitle: "Annulla")
        let menu = NSPopUpButton(frame: .zero, pullsDown: false)
        menu.addItems(withTitles: ["Dissolvenza al nero", "Scorrimento sinistra", "Scorrimento destra", "Scorrimento su", "Scorrimento giù", "Zoom", "Wipe", "Sfocatura"])
        let seconds = NSTextField(string: "0.5"); seconds.placeholderString = "Durata (s)"
        let box = NSStackView(views: [menu, seconds]); box.orientation = .vertical; box.spacing = 8; a.accessoryView = box
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let duration = max(0.05, Double(seconds.stringValue) ?? 0.5)
        edit { p in if let i = p.clips.firstIndex(where: { $0.id == c.id }) { p.clips[i].transition = ClipTransition(type: menu.titleOfSelectedItem ?? "Dissolvenza al nero", duration: duration) } }
    }

    func separateAudio() {
        guard let c = project.clips.first(where: { selection.contains($0.id) && !$0.isTitle }),
              let source = project.media(c.mediaID), source.hasAudio else { status = "La clip selezionata non contiene audio"; return }
        edit { p in
            var audio = source; audio.id = newID(); audio.hasVideo = false; audio.pano = false
            p.media.append(audio)
            var detached = c; detached.id = newID(); detached.mediaID = audio.id; detached.track = min(1, p.tracks.audioMuted.count - 1)
            detached.audioDetached = true; detached.audioDisabled = false
            if let index = p.clips.firstIndex(where: { $0.id == c.id }) { p.clips[index].audioDisabled = true }
            p.clips.append(detached)
        }
    }

    func selectRightOfPlayhead() {
        selection = Set(project.clips.filter { $0.start >= clock.time - 1e-6 }.map(\.id)); gap = nil
    }

    func nudgeSelection(_ direction: Int) {
        guard !selection.isEmpty else { return }
        let amount = Double(direction) / Double(max(1, project.settings.fps))
        edit { p in for i in p.clips.indices where selection.contains(p.clips[i].id) { p.clips[i].start = max(0, p.clips[i].start + amount) } }
    }

    func closeGaps() {
        let lane = project.clips.first(where: { selection.contains($0.id) })?.track ?? TrackIndex.main
        edit { p in
            var cursor = 0.0
            for i in p.clips.indices.filter({ p.clips[$0].track == lane }).sorted(by: { p.clips[$0].start < p.clips[$1].start }) {
                if p.clips[i].start > cursor { p.clips[i].start = cursor }
                cursor = max(cursor, p.clips[i].end)
            }
        }
    }

    func duckMusic() {
        let target = project.clips.first(where: { selection.contains($0.id) })?.track ?? TrackIndex.main
        let voice = project.clips.filter { $0.track != target && !$0.isTitle && !$0.audioDisabled && project.media($0.mediaID)?.hasAudio == true }
        let music = project.clips.filter { $0.track == target && !$0.isTitle && project.media($0.mediaID)?.hasAudio == true }
        guard !voice.isEmpty, !music.isEmpty else { status = "Servono una traccia voce e una musica su tracce diverse"; return }
        edit { p in
            for i in p.clips.indices where p.clips[i].track == target && !p.clips[i].isTitle {
                let c = p.clips[i]
                guard let values = cache.peaks[p.media(c.mediaID)?.id ?? ""] else { continue }
                let stride = max(20, Int(c.duration * 100 / 800)); var keys: [MotionKey] = []
                let sourceStart = max(0, Int(c.sourceIn * 100))
                let sourceEnd = min(values.count, Int((c.sourceIn + c.sourceDuration) * 100))
                for sample in Swift.stride(from: sourceStart, to: sourceEnd, by: stride) {
                    let local = Double(sample) / 100 - c.sourceIn; let timeline = c.start + local / c.speed
                    let active = voice.contains { v in
                        guard v.start <= timeline && timeline < v.end, let peaks = cache.peaks[p.media(v.mediaID)?.id ?? ""] else { return false }
                        let sourceIndex = Int((v.sourceIn + (timeline - v.start) * v.speed) * 100)
                        return sourceIndex >= 0 && sourceIndex < peaks.count && peaks[sourceIndex] > 0.08
                    }
                    var key = MotionKey(); key.t = c.sourceIn + local * c.speed; key.volume = c.volume * (active ? 0.28 : 1); keys.append(key)
                }
                p.clips[i].effects.keys = keys
            }
        }
    }

    func freezeFrame() {
        guard let c = project.clips.first(where: { selection.contains($0.id) && !$0.isTitle }),
              let media = project.media(c.mediaID), let runtime = cache.runtimes[media.id] else { status = "Seleziona una clip video caricata"; return }
        let sourceTime = min(max(0, c.sourceTime(at: clock.time)), max(0, media.duration - 0.01))
        let generator = AVAssetImageGenerator(asset: runtime.asset); generator.appliesPreferredTrackTransform = true
        do {
            let cg = try generator.copyCGImage(at: CMTime(seconds: sourceTime, preferredTimescale: 600), actualTime: nil)
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EliteStudio/Freeze", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("freeze-\(UUID().uuidString).png")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw NSError(domain: "EliteStudio", code: 40) }
            CGImageDestinationAddImage(dest, cg, nil); guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "EliteStudio", code: 41) }
            Task { @MainActor in
                do {
                    var still = try await cache.probe(url); still.still = true; still.hasAudio = false
                    _ = await cache.prepare(still)
                    let at = clock.time
                    checkpoint()
                    project.media.append(still)
                    let crossing = project.clips.filter { $0.start + 0.001 < at && $0.end - 0.001 > at }.map(\.id)
                    for id in crossing { _ = project.split(id, at: at) }
                    for i in project.clips.indices where project.clips[i].start >= at - 0.0001 { project.clips[i].start += 2 }
                    for i in project.captions.indices {
                        let cap = project.captions[i]
                        if cap.start >= at - 0.0001 { project.captions[i].start += 2; project.captions[i].end += 2 }
                        else if cap.end > at { project.captions[i].end += 2 }
                    }
                    let clip = Clip(mediaID: still.id, track: c.track, start: at, duration: 2)
                    var frozen = clip; frozen.freezeFrame = true; frozen.freezeSource = FreezeSource(media: media.id, time: sourceTime)
                    project.clips.append(frozen); selection = [frozen.id]
                    status = "Fermo immagine inserito (2 s)"
                } catch { status = "Fermo immagine non riuscito: \(error.localizedDescription)" }
            }
        } catch { status = "Fotogramma non disponibile: \(error.localizedDescription)" }
    }

    func exportFrame() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType.png]; panel.nameFieldStringValue = "Fotogramma.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = project, at = clock.time
        Task { @MainActor in
            do {
                for media in snapshot.media where cache.runtimes[media.id] == nil { _ = await cache.prepare(media, background: false) }
                let composition = CompositionBuilder.build(snapshot, cache: cache)
                let generator = AVAssetImageGenerator(asset: composition.composition)
                generator.appliesPreferredTrackTransform = true
                if let vc = CompositionBuilder.videoComposition(composition, project: snapshot, cache: cache, burnOverlays: true) {
                    CompositionBuilder.addOverlays(to: vc, project: snapshot)
                    generator.videoComposition = vc
                }
                let image = try generator.copyCGImage(at: CMTime(seconds: at, preferredTimescale: 600), actualTime: nil)
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw NSError(domain: "EliteStudio", code: 42) }
                CGImageDestinationAddImage(dest, image, nil); guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "EliteStudio", code: 43) }
                status = "Fotogramma esportato"
            } catch { status = "Esportazione fotogramma non riuscita: \(error.localizedDescription)" }
        }
    }

    func razor(_ id: ID, at t: Double, allTracks: Bool) {
        edit { p in
            if allTracks {
                for c in p.clips where c.start < t && c.end > t { p.split(c.id, at: t) }
            } else { p.split(id, at: t) }
        }
    }

    func deleteSelection(ripple: Bool) {
        if let c = selectedCaption { deleteCaption(c); return }
        if let g = gap {
            edit { $0.closeGap(track: g.track, g.start, g.end) }
            gap = nil
            return
        }
        guard !selection.isEmpty else { return }
        let sel = selection
        let ranges = project.clips.filter { sel.contains($0.id) }.map { ($0.start, $0.end) }
        edit { p in
            p.clips.removeAll { sel.contains($0.id) }
            guard ripple else { return }
            // merge overlapping ranges and remove them from the whole sequence, last first
            var merged: [(Double, Double)] = []
            for r in ranges.sorted(by: { $0.0 < $1.0 }) {
                if let l = merged.last, r.0 <= l.1 + 1e-6 { merged[merged.count - 1].1 = max(l.1, r.1) } else { merged.append(r) }
            }
            for r in merged.reversed() { p.extract(r.0, r.1) }
        }
        selection = []
    }

    /// Q / W: remove from the clip's start up to the playhead (or playhead to clip end) and close the gap.
    func rippleTrim(toPlayhead before: Bool) {
        let t = clock.time
        let under = clipsUnderPlayhead().filter { !$0.isTitle }
        guard let c = under.first(where: { selection.contains($0.id) }) ?? under.min(by: { $0.track < $1.track }) else { return }
        edit { p in before ? p.extract(c.start, t) : p.extract(t, c.end) }
        if before { seek(c.start) }
    }

    func selectAll() { selection = Set(project.clips.map(\.id)); gap = nil }

    func copy() { clipboard = project.clips.filter { selection.contains($0.id) } }

    func paste() {
        guard let first = clipboard.map(\.start).min() else { return }
        let t = clock.time
        var ids: Set<ID> = []
        edit { p in
            for var c in clipboard {
                c.id = newID()
                c.start = t + (c.start - first)
                p.overwrite(c.start, c.end, track: c.track)
                p.clips.append(c)
                ids.insert(c.id)
            }
        }
        selection = ids
        seek(t + ((clipboard.map(\.end).max() ?? first) - first))
    }

    func toggleVideo(_ lane: Int) { edit { $0.tracks.videoHidden[lane].toggle() } }
    func toggleAudio(_ lane: Int) { edit { $0.tracks.audioMuted[lane].toggle() } }
    func toggleTitles() { edit { $0.tracks.titlesHidden.toggle() } }

    // MARK: - files

    private static var supportDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EliteStudio")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var autosaveURL: URL { supportDir.appendingPathComponent("autosave.elitestudio") }

    func newProject() {
        pause()
        project = Project(); projectURL = nil
        undoStack.removeAll(); redoStack.removeAll(); selection = []; gap = nil; selectedCaption = nil
        seek(0)
        UserDefaults.standard.removeObject(forKey: "lastProject")
    }

    func open(_ url: URL) {
        do {
            let p = try ProjectFile.decode(Data(contentsOf: url), base: url.deletingLastPathComponent())
            pause()
            undoStack.removeAll(); redoStack.removeAll(); selection = []; gap = nil; selectedCaption = nil
            projectURL = url.pathExtension == "elitestudio" ? url : nil
            project = p
            UserDefaults.standard.set(url.path, forKey: "lastProject")
            seek(0)
            Task { await self.completeMedia(); self.fitTimeline?() }
            status = "Aperto \(url.lastPathComponent)"
        } catch {
            status = "Impossibile aprire \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func completeMedia() async {
        let (p, missing) = await ProjectLoader.complete(project, cache: cache, folder: projectURL?.deletingLastPathComponent())
        if let m = missing.first { status = "File mancante: \(m)" }
        if p != project { project = p }
    }

    /// Reconnect moved Windows/Mac media by filename; ambiguous matches are never chosen silently.
    func relinkMissingMedia(in folder: URL) async {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var candidates: [String: [URL]] = [:]
        for case let url as URL in files {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                candidates[url.lastPathComponent.lowercased(), default: []].append(url)
            }
        }
        var replacements: [ID: URL] = [:]
        var ambiguous = 0
        for item in project.media where !FileManager.default.fileExists(atPath: item.url.path) {
            let name = item.url.path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? item.name
            let matches = candidates[name.lowercased()] ?? []
            if matches.count == 1 { replacements[item.id] = matches[0] }
            else if matches.count > 1 { ambiguous += 1 }
        }
        guard !replacements.isEmpty else {
            status = ambiguous > 0 ? "Più file con lo stesso nome: scegli una cartella più specifica" : "Nessun file corrispondente trovato"
            return
        }
        edit { p in
            for i in p.media.indices {
                if let url = replacements[p.media[i].id] { p.media[i].url = url }
            }
        }
        for id in replacements.keys { cache.forget(id) }
        await completeMedia()
        status = "Ricollegati \(replacements.count) file" + (ambiguous > 0 ? "; \(ambiguous) nomi ambigui ignorati" : "")
    }

    func restoreLastSession() {
        if let path = UserDefaults.standard.string(forKey: "lastProject"), FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
        } else if FileManager.default.fileExists(atPath: Self.autosaveURL.path) {
            open(Self.autosaveURL)
            projectURL = nil
        }
    }

    func save(to url: URL) {
        do {
            ProjectHistory.backup(url)
            try ProjectFile.encode(project, base: url.deletingLastPathComponent()).write(to: url, options: .atomic)
            projectURL = url
            UserDefaults.standard.set(url.path, forKey: "lastProject")
            status = "Salvato \(url.lastPathComponent)"
        } catch { status = "Errore salvataggio: \(error.localizedDescription)" }
    }

    /// Changes are written automatically: to the project file if there is one, otherwise to an autosave.
    private func scheduleAutosave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if self.interacting { self.scheduleAutosave(); return }
            let url = self.projectURL ?? Self.autosaveURL
            if self.projectURL != nil { ProjectHistory.backup(url) }
            try? ProjectFile.encode(self.project, base: url.deletingLastPathComponent()).write(to: url, options: .atomic)
        }
    }

    // MARK: - export

    func startExport(to url: URL, hevc: Bool, width: Int? = nil, height: Int? = nil) {
        pause()
        var renderProject = project
        if let width, let height { renderProject.settings.width = width; renderProject.settings.height = height }
        export = ExportState(url: url)
        exportTask = Task {
            do {
                try await Exporter.run(project: renderProject, to: url, hevc: hevc) { p in
                    self.export?.progress = p
                }
                self.export?.done = true
                self.export?.progress = 1
            } catch is CancellationError {
                self.export = nil
            } catch {
                self.export?.error = error.localizedDescription
            }
        }
    }

    func cancelExport() { exportTask?.cancel(); export = nil }
}

/// Fills in what a hand- or script-written project leaves out.
@MainActor
enum ProjectLoader {
    /// Probes media without duration, sizes "to end of file" clips, picks the frame format. Returns missing file paths.
    static func complete(_ project: Project, cache: MediaCache, folder: URL?) async -> (Project, [String]) {
        var p = project
        var missing: [String] = []
        // photos written into a project by hand or by a script: turn them into their short video
        for i in p.media.indices where StillMaker.isImage(p.media[i].url) {
            if let v = try? await StillMaker.video(for: p.media[i].url, in: StillMaker.folder(projectFolder: folder)) {
                p.media[i].name = p.media[i].url.lastPathComponent
                p.media[i].url = v; p.media[i].still = true; p.media[i].duration = 0
            } else { missing.append(p.media[i].url.path) }
        }
        for i in p.media.indices where p.media[i].duration <= 0 {
            if let m = try? await cache.probe(p.media[i].url) {
                p.media[i].duration = m.duration; p.media[i].hasVideo = m.hasVideo; p.media[i].hasAudio = m.hasAudio
                p.media[i].width = m.width; p.media[i].height = m.height; p.media[i].pano = m.pano
            } else { missing.append(p.media[i].url.path) }
        }
        for i in p.clips.indices where !p.clips[i].isTitle {
            guard let m = p.media(p.clips[i].mediaID), m.duration > 0 else { continue }
            p.clips[i].sourceIn = min(p.clips[i].sourceIn, max(0, m.duration - minClipDuration))
            if p.clips[i].duration <= 0 && m.still { p.clips[i].duration = min(StillMaker.defaultDuration, m.duration) }
            if p.clips[i].duration <= 0 || p.clips[i].sourceIn + p.clips[i].sourceDuration > m.duration + 0.01 {
                p.clips[i].duration = max(minClipDuration, (m.duration - p.clips[i].sourceIn) / p.clips[i].speed)
            }
        }
        if !p.settings.customized, let m = p.media.first(where: { $0.hasVideo && $0.width > 0 }) {
            let ar = m.width / m.height
            (p.settings.width, p.settings.height) = ar < 0.9 ? (1080, 1920) : ar > 1.1 ? (1920, 1080) : (1080, 1080)
        }
        return (p, missing)
    }

    static func load(_ url: URL) async throws -> (Project, [String]) {
        let p = try ProjectFile.decode(Data(contentsOf: url), base: url.deletingLastPathComponent())
        return await complete(p, cache: MediaCache.shared, folder: url.deletingLastPathComponent())
    }
}

/// Renders a project to an .mp4 file. Used by the app and by the command line.
@MainActor
enum Exporter {
    static func run(project p: Project, to url: URL, hevc: Bool, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard !p.media.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else {
            throw NSError(domain: "EliteStudio", code: 4, userInfo: [NSLocalizedDescriptionKey: "L’esportazione non può sostituire un file sorgente"])
        }
        let cache = MediaCache.shared
        for m in p.media where cache.runtimes[m.id] == nil { _ = await cache.prepare(m, background: false) }
        let b = CompositionBuilder.build(p, cache: cache)
        guard b.hasVideo || !b.audio.isEmpty else {
            throw NSError(domain: "EliteStudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "La timeline è vuota"])
        }
        let preset = hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: b.composition, presetName: preset) else {
            throw NSError(domain: "EliteStudio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Esportazione non disponibile"])
        }
        if let vc = CompositionBuilder.videoComposition(b, project: p, cache: cache, burnOverlays: true) {
            CompositionBuilder.addOverlays(to: vc, project: p)
            session.videoComposition = vc
        }
        session.audioMix = CompositionBuilder.audioMix(b, project: p)
        session.audioTimePitchAlgorithm = .spectral
        let partial = url.deletingLastPathComponent().appendingPathComponent(".elite-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: partial) }
        let watcher = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let pr) = state { await progress(pr.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: partial, as: .mp4)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
        } else { try FileManager.default.moveItem(at: partial, to: url) }
    }
}
