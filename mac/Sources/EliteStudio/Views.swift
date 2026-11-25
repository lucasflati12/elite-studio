import SwiftUI
import AVKit
import UniformTypeIdentifiers

let goldColor = Color(red: 1, green: 0.82, blue: 0.25)
let panelColor = Color(red: 0.04, green: 0.09, blue: 0.15)
let deepColor = Color(red: 0.02, green: 0.05, blue: 0.09)

struct ContentView: View {
    @ObservedObject var editor: Editor

    var body: some View {
        VSplitView {
            HSplitView {
                BinView(editor: editor)
                    .frame(minWidth: 200, idealWidth: 250, maxWidth: 400)
                ViewerView(editor: editor, clock: editor.clock)
                    .frame(minWidth: 320)
                InspectorView(editor: editor)
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 360)
            }
            .frame(minHeight: 300)
            VStack(spacing: 0) {
                TimelineBar(editor: editor, clock: editor.clock)
                TimelineView(editor: editor)
            }
            .frame(minHeight: 230, idealHeight: 320)
        }
        .background(deepColor)
        .preferredColorScheme(.dark)
        .tint(goldColor)
        .sheet(isPresented: Binding(get: { editor.export != nil }, set: { if !$0 { editor.export = nil } })) {
            ExportSheet(editor: editor)
        }
        .navigationTitle(editor.projectURL?.deletingPathExtension().lastPathComponent ?? "Elite Studio")
    }
}

// MARK: - bin

struct BinView: View {
    @ObservedObject var editor: Editor
    @ObservedObject var cache = MediaCache.shared
    @State private var dropTarget = false
    @State private var search = ""

    var body: some View {
        let missingCount = editor.project.media.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("PROGETTO").font(.system(size: 10, weight: .heavy)).kerning(2).foregroundStyle(goldColor)
                Spacer()
                if missingCount > 0 {
                    Button {
                        Commands.relinkMedia()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "link")
                            Text("Mancanti (\(missingCount))")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Ricollega i file spostati da Windows o da un altro disco")
                }
                Button { Commands.importMedia() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Importa file o cartelle (⌘I)")
            }
            .padding(10)
            TextField("Cerca file nel progetto…", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 6)
            if editor.project.media.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Trascina qui video o cartelle\noppure ⌘I").multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(editor.project.media.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { m in
                        BinRow(item: m,
                               poster: cache.posterFrame(m.id),
                               used: editor.project.clips.contains { $0.mediaID == m.id },
                               isSelected: editor.selectedMediaID == m.id,
                               onRemove: { editor.removeMedia(m.id) })
                            .onDrag { NSItemProvider(object: "elitemedia:\(m.id)" as NSString) }
                            .onTapGesture {
                                editor.selectedMediaID = m.id
                            }
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                editor.append(m.id)
                            })
                            .contextMenu {
                                Button("Aggiungi in fondo alla timeline") { editor.append(m.id) }
                                Button("Inserisci al playhead") { editor.place(m.id, at: editor.clock.time, track: 0) }
                                if FileManager.default.fileExists(atPath: m.url.path) {
                                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.url]) }
                                }
                                Divider()
                                Button("Rimuovi dal progetto", role: .destructive) { editor.removeMedia(m.id) }
                            }
                            .task { _ = await cache.prepare(m) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(panelColor)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(goldColor, lineWidth: dropTarget ? 2 : 0))
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let url = URL(dataRepresentation: u, relativeTo: nil) { urls.append(url) }
                }
                await editor.importMedia(urls)
            }
            return true
        }
    }
}

struct BinRow: View {
    let item: MediaItem
    let poster: CGImage?
    let used: Bool
    let isSelected: Bool
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: item.url.path)
        HStack(spacing: 8) {
            ZStack {
                Rectangle().fill(Color.black)
                if let poster {
                    Image(decorative: poster, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: !exists ? "exclamationmark.triangle.fill" : item.still ? "photo" : item.hasVideo ? "film" : "waveform")
                        .foregroundStyle(!exists ? Color.red : Color.secondary)
                }
            }
            .frame(width: 54, height: 34)
            .clipped()
            .cornerRadius(3)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(!exists ? Color.red.opacity(0.8) : Color.clear, lineWidth: 1.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(!exists ? Color.red.opacity(0.95) : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if !exists {
                        Text("File mancante")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.red)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.2))
                            .cornerRadius(3)
                    } else {
                        if item.still { Text("Foto") } else { Text(formatShort(item.duration)).monospacedDigit() }
                        if item.width > 0 { Text("· \(Int(item.width))×\(Int(item.height))") }
                        if used { Circle().fill(goldColor).frame(width: 5, height: 5) }
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(!exists ? Color.red : isHovered ? Color.white : Color.secondary.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("Rimuovi dal progetto (⌫)")
            .opacity(!exists || isHovered || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? goldColor.opacity(0.18) : isHovered ? Color.white.opacity(0.05) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? goldColor.opacity(0.8) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - viewer

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.allowsVideoFrameAnalysis = false
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {}
}

struct ViewerView: View {
    @ObservedObject var editor: Editor
    @ObservedObject var clock: PlaybackClock
    @State private var panoDrag = CGSize.zero

    var body: some View {
        let s = editor.project.settings
        VStack(spacing: 0) {
            ZStack {
                deepColor
                ZStack {
                    Color.black
                    PlayerSurface(player: editor.player)
                    OverlayPreview(editor: editor, clock: clock)
                }
                .aspectRatio(CGFloat(s.width) / CGFloat(s.height), contentMode: .fit)
                .contentShape(Rectangle())
                .onTapGesture { editor.togglePlay() }
                .overlay(GeometryReader { geo in
                    // 360 clips: drag to look around
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 3)
                            .onChanged { g in
                                let d = CGSize(width: g.translation.width - panoDrag.width, height: g.translation.height - panoDrag.height)
                                panoDrag = g.translation
                                editor.dragPano(delta: d, viewSize: geo.size)
                            }
                            .onEnded { _ in panoDrag = .zero })
                        .onTapGesture { editor.togglePlay() }
                        .allowsHitTesting(editor.panoTarget() != nil)
                })
            }
            .padding(8)
            HStack(spacing: 14) {
                Text(formatTimecode(clock.time, fps: s.fps)).monospacedDigit().foregroundStyle(goldColor)
                Spacer()
                Button { editor.jumpEdit(forward: false) } label: { Image(systemName: "backward.end.fill") }.help("Taglio precedente (↑)")
                Button { editor.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }.help("Fotogramma precedente (←)")
                Button { editor.togglePlay() } label: { Image(systemName: clock.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18)) }.help("Play/Pausa (Spazio)")
                Button { editor.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }.help("Fotogramma successivo (→)")
                Button { editor.jumpEdit(forward: true) } label: { Image(systemName: "forward.end.fill") }.help("Taglio successivo (↓)")
                Spacer()
                Text(formatTimecode(editor.duration, fps: s.fps)).monospacedDigit().foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(panelColor)
        }
    }
}

/// Live preview of name cards, drawn with the same images the export uses.
struct OverlayPreview: View {
    @ObservedObject var editor: Editor
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        GeometryReader { geo in
            let p = editor.project
            let frame = p.settings.size
            let k = geo.size.width / frame.width
            ZStack(alignment: .topLeading) {
                if !p.tracks.titlesHidden {
                    ForEach(p.clips.filter { $0.isTitle && $0.start <= clock.time && clock.time < $0.end }) { c in
                        let card = c.title!
                        ForEach(Array(Overlay.elements(for: card, frame: frame).enumerated()), id: \.offset) { _, e in
                            let a = Overlay.animation(t: clock.time - c.start, dur: c.duration, delay: e.delay, fade: card.fade,
                                                      unit: Overlay.unit(frame) * CGFloat(card.size))
                            element(e, k: k, alpha: a.alpha, dx: a.dx)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    private func element(_ e: Overlay.Element, k: CGFloat, alpha: Double, dx: CGFloat) -> some View {
        Image(decorative: e.image, scale: 1).resizable()
            .frame(width: e.rect.width * k, height: e.rect.height * k)
            .offset(x: (e.rect.minX + dx) * k, y: e.rect.minY * k)
            .opacity(alpha)
    }
}

// MARK: - timeline toolbar

struct TimelineBar: View {
    @ObservedObject var editor: Editor
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $editor.tool) {
                Image(systemName: "arrow.up.left").help("Selezione (V)").tag(Tool.select)
                Image(systemName: "scissors").help("Taglio / rasoio (C)").tag(Tool.razor)
            }
            .pickerStyle(.segmented).frame(width: 90).labelsHidden()
            Toggle(isOn: $editor.snapping) { Image(systemName: "magnet") }
                .toggleStyle(.button).help("Aggancio (S)")
            Divider().frame(height: 16)
            Button { editor.addEdit() } label: { Label("Taglia", systemImage: "scissors") }.help("Taglia al playhead (⌘K)")
            Button { editor.deleteSelection(ripple: true) } label: { Label("Elimina e chiudi", systemImage: "delete.backward") }
                .help("Elimina e chiudi lo spazio (⇧⌫)").disabled(editor.selection.isEmpty && editor.gap == nil)
            Button { editor.addTitle() } label: { Label("Titolo", systemImage: "textformat") }.help("Aggiungi un titolo al playhead (⌘T)")
            Button { editor.generateCaptions() } label: {
                Label(editor.transcribing ? "Trascrivo…" : "Sottotitoli", systemImage: "captions.bubble")
            }
            .help("Sottotitoli automatici dall'audio della timeline (trascritti sul Mac)")
            .disabled(editor.transcribing || editor.project.clips.isEmpty)
            Spacer()
            Text(editor.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: Binding(get: { log(editor.pixelsPerSecond) }, set: { editor.pixelsPerSecond = exp($0) }), in: log(1)...log(800))
                .frame(width: 110)
            Button { editor.fitTimeline?() } label: { Image(systemName: "arrow.left.and.right") }.help("Adatta la timeline (\\)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(panelColor)
    }
}

// MARK: - inspector

struct InspectorView: View {
    @ObservedObject var editor: Editor

    private var selected: [Clip] { editor.project.clips.filter { editor.selection.contains($0.id) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                let sel = selected
                if let cid = editor.selectedCaption, editor.project.captions.contains(where: { $0.id == cid }) {
                    CaptionInspector(editor: editor, id: cid)
                } else if sel.count == 1, let c = sel.first {
                    if c.isTitle { TitleInspector(editor: editor, id: c.id) } else { ClipInspector(editor: editor, id: c.id) }
                } else if sel.count > 1 {
                    header("\(sel.count) CLIP")
                    Text("Trascina per spostarle insieme, ⌫ per eliminarle.").font(.callout).foregroundStyle(.secondary)
                } else {
                    SequenceInspector(editor: editor)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(panelColor)
    }
}

func header(_ s: String) -> some View {
    Text(s).font(.system(size: 10, weight: .heavy)).kerning(2).foregroundStyle(goldColor).padding(.top, 4)
}

/// Slider row whose changes share one undo step per drag.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(format(value)).font(.system(size: 11).monospacedDigit())
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

struct ClipInspector: View {
    @ObservedObject var editor: Editor
    @ObservedObject var clock: PlaybackClock
    let id: ID
    init(editor: Editor, id: ID) { self.editor = editor; self.clock = editor.clock; self.id = id }
    private func motionBind(_ key: WritableKeyPath<MotionKey, Double>, base: WritableKeyPath<Clip, Double>) -> Binding<Double> {
        Binding(get: { editor.project.clips.first { $0.id == id }?.motion(at: editor.clock.time)[keyPath: key] ?? 0 },
                set: { value in editor.edit("motion.\(id).\(key)") { p in
                    guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return }
                    if p.clips[i].effects.keys.isEmpty { p.clips[i][keyPath: base] = value }
                    else { p.clips[i].recordMotion(key, value: value, at: editor.clock.time) }
                } })
    }

    private func bind<T>(_ kp: WritableKeyPath<Clip, T>) -> Binding<T> {
        Binding(
            get: { (editor.project.clips.first { $0.id == id } ?? Clip())[keyPath: kp] },
            set: { v in editor.edit("clip.\(id).\(kp)") { p in
                if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i][keyPath: kp] = v }
            } })
    }

    var body: some View {
        if let c = editor.project.clips.first(where: { $0.id == id }) {
            let m = editor.project.media(c.mediaID)
            header("CLIP")
            Text(m?.name ?? "offline").font(.system(size: 13, weight: .semibold)).lineLimit(2)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow { Text("Inizio").foregroundStyle(.secondary); Text(formatTimecode(c.start, fps: editor.project.settings.fps)) }
                GridRow { Text("Durata").foregroundStyle(.secondary); Text(formatTimecode(c.duration, fps: editor.project.settings.fps)) }
                GridRow { Text("Sorgente").foregroundStyle(.secondary); Text("\(String(format: "%.2f", c.sourceIn)) → \(String(format: "%.2f", c.sourceIn + c.sourceDuration)) s") }
                GridRow { Text("Traccia").foregroundStyle(.secondary); Text("V\(Project.trackNumber(c.track)) / A\(Project.trackNumber(c.track))") }
            }
            .font(.system(size: 11).monospacedDigit())

            if !(m?.still ?? true) {
                header("VELOCITÀ")
                Picker("", selection: Binding(get: { c.speed }, set: { v in editor.edit { $0.setSpeed(id, v) } })) {
                    ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4, 8], id: \.self) { Text(speedLabel($0)).tag($0) }
                    if ![0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4, 8].contains(c.speed) { Text(speedLabel(c.speed)).tag(c.speed) }
                }
                .labelsHidden()
                Text("La clip si accorcia o si allunga, il resto della timeline si sposta.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if m?.hasAudio ?? false {
                header("AUDIO")
                ValueSlider(title: "Volume", value: motionBind(\.volume, base: \.volume), range: 0...4) { $0 == 0 ? "−∞ dB" : String(format: "%+.1f dB", 20 * log10($0)) }
                Button("Regola automaticamente il volume") { editor.normalizeAudio(id) }
                Toggle("Riduzione rumore (solo export Windows)", isOn: Binding(get: { c.noiseReduction }, set: { value in editor.edit { p in if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].noiseReduction = value } }; editor.status = "Riduzione rumore disponibile solo export Windows" }))
                Toggle("Disattiva audio incorporato", isOn: bind(\.audioDisabled))
            }
            if m?.pano ?? false {
                PanoInspector(editor: editor, clock: editor.clock, id: id)
                ValueSlider(title: "Opacità", value: motionBind(\.opacity, base: \.opacity), range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
                header("TRASFORMA")
                ForEach(["left", "right", "top", "bottom"], id: \.self) { side in
                    ValueSlider(title: "Ritaglio \(side)", value: Binding(get: { cropValue(c.crop, side) }, set: { value in editor.edit("crop.\(id).\(side)") { p in
                        guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return }
                        var crop = p.clips[i].crop ?? Crop()
                        setCropValue(&crop, side, min(0.85, max(0, value))); p.clips[i].crop = crop
                    } }), range: 0...0.85) { "\(Int(($0 * 100).rounded()))%" }
                }
                Toggle("Specchia orizzontalmente", isOn: bind(\.flipH))
                Toggle("Specchia verticalmente", isOn: bind(\.flipV))
                Toggle("Sfondo sfocato", isOn: Binding(get: { c.background != nil }, set: { value in editor.edit { p in
                    guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return }
                    p.clips[i].background = value ? ClipBackground(type: "blur", amount: 12) : nil
                } }))
                Toggle("Chroma key", isOn: Binding(get: { c.chromaKey != nil }, set: { value in editor.edit { p in
                    guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return }
                    p.clips[i].chromaKey = value ? ChromaKey() : nil
                } }))
                if let key = c.chromaKey {
                    TextField("Colore esadecimale", text: Binding(get: { key.color }, set: { value in editor.edit { p in if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].chromaKey?.color = value } } }))
                    ValueSlider(title: "Tolleranza", value: Binding(get: { key.tolerance }, set: { value in editor.edit { p in if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].chromaKey?.tolerance = value } } }), range: 0.001...0.5)
                    ValueSlider(title: "Morbidezza", value: Binding(get: { key.softness }, set: { value in editor.edit { p in if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].chromaKey?.softness = value } } }), range: 0.001...0.5)
                }
            } else if m?.hasVideo ?? false {
                header("VIDEO")
                Picker("", selection: bind(\.fill)) {
                    Text("Adatta").tag(false)
                    Text("Riempi").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                ValueSlider(title: "Scala", value: motionBind(\.scale, base: \.scale), range: 0.2...3) { "\(Int(($0 * 100).rounded()))%" }
                ValueSlider(title: "Posizione X", value: motionBind(\.x, base: \.offsetX), range: -0.5...0.5)
                ValueSlider(title: "Posizione Y", value: motionBind(\.y, base: \.offsetY), range: -0.5...0.5)
                ValueSlider(title: "Opacità", value: motionBind(\.opacity, base: \.opacity), range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
                Button("Reimposta") {
                    editor.edit { p in
                        if let i = p.clips.firstIndex(where: { $0.id == id }) {
                            p.clips[i].scale = 1; p.clips[i].offsetX = 0; p.clips[i].offsetY = 0; p.clips[i].opacity = 1; p.clips[i].fill = false
                        }
                    }
                }
                .controlSize(.small)
            }
            EffectsInspector(editor: editor, id: id)
        }
    }

    private func cropValue(_ crop: Crop?, _ side: String) -> Double {
        let value = crop ?? Crop()
        switch side { case "left": return value.left; case "right": return value.right; case "top": return value.top; default: return value.bottom }
    }
    private func setCropValue(_ crop: inout Crop, _ side: String, _ value: Double) {
        switch side { case "left": crop.left = value; case "right": crop.right = value; case "top": crop.top = value; default: crop.bottom = value }
    }
}

struct TitleInspector: View {
    @ObservedObject var editor: Editor
    let id: ID

    private func bind<T>(_ kp: WritableKeyPath<TitleCard, T>) -> Binding<T> {
        Binding(
            get: { (editor.project.clips.first { $0.id == id }?.title ?? TitleCard())[keyPath: kp] },
            set: { v in editor.edit("title.\(id).\(kp)") { p in
                if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].title?[keyPath: kp] = v }
            } })
    }

    var body: some View {
        if editor.project.clips.contains(where: { $0.id == id }) {
            header("TITOLO")
            Picker("Tipo", selection: bind(\.style)) { Text("Cartellino").tag("card"); Text("Testo libero").tag("text") }
            Picker("Animazione entrata", selection: bind(\.animationIn)) { ForEach(["Nessuna", "Dissolvenza", "Scorri su", "Pop/Scala", "Macchina da scrivere"], id: \.self) { Text($0).tag($0) } }
            Picker("Animazione uscita", selection: bind(\.animationOut)) { ForEach(["Nessuna", "Dissolvenza", "Scorri su", "Pop/Scala"], id: \.self) { Text($0).tag($0) } }
            Picker("Stile", selection: bind(\.stylePreset)) { ForEach(["Normale", "Contorno", "Ombra", "Sfondo box"], id: \.self) { Text($0).tag($0) } }
            Text("Nomi (uno per riga)").font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: bind(\.names))
                .font(.system(size: 13, weight: .semibold))
                .frame(height: 54)
                .scrollContentBackground(.hidden)
                .background(Color.black.opacity(0.3))
                .cornerRadius(4)
            Text("Etichetta").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", text: bind(\.label)).textFieldStyle(.roundedBorder)
            Toggle("Mostra etichetta", isOn: bind(\.showLabel)).font(.system(size: 12))
            Text("Tag (vuoto = nessuno)").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("MVP", text: bind(\.tag)).textFieldStyle(.roundedBorder)
            ValueSlider(title: "Posizione X", value: bind(\.x), range: 0...0.9)
            ValueSlider(title: "Posizione Y", value: bind(\.y), range: 0...0.95)
            ValueSlider(title: "Dimensione", value: bind(\.size), range: 0.4...2) { "\(Int(($0 * 100).rounded()))%" }
            ValueSlider(title: "Dissolvenza", value: bind(\.fade), range: 0.05...1.5) { String(format: "%.2f s", $0) }
            Button("Applica stile a tutti i titoli") {
                guard let src = editor.project.clips.first(where: { $0.id == id })?.title else { return }
                editor.edit { p in
                    for i in p.clips.indices where p.clips[i].isTitle {
                        let names = p.clips[i].title!.names
                        p.clips[i].title = src
                        p.clips[i].title!.names = names
                    }
                }
            }
            .controlSize(.small)
        }
    }
}

struct SequenceInspector: View {
    @ObservedObject var editor: Editor

    private func bind<T>(_ kp: WritableKeyPath<SequenceSettings, T>) -> Binding<T> {
        Binding(get: { editor.project.settings[keyPath: kp] },
                set: { v in editor.edit("seq.\(kp)") { $0.settings[keyPath: kp] = v; $0.settings.customized = true } })
    }

    private var format: Binding<String> {
        Binding(get: { "\(editor.project.settings.width)x\(editor.project.settings.height)" },
                set: { v in
                    let parts = v.split(separator: "x").compactMap { Int($0) }
                    guard parts.count == 2 else { return }
                    editor.edit { $0.settings.width = parts[0]; $0.settings.height = parts[1]; $0.settings.customized = true }
                })
    }

    var body: some View {
        header("SEQUENZA")
        Picker("Formato", selection: format) {
            Text("9:16 verticale · 1080×1920").tag("1080x1920")
            Text("4:5 · 1080×1350").tag("1080x1350")
            Text("1:1 · 1080×1080").tag("1080x1080")
            Text("16:9 · 1920×1080").tag("1920x1080")
            Text("16:9 · 3840×2160").tag("3840x2160")
        }
        Picker("Fotogrammi", selection: bind(\.fps)) {
            Text("24 fps").tag(24); Text("25 fps").tag(25); Text("30 fps").tag(30); Text("60 fps").tag(60)
        }
        CaptionStyleControls(editor: editor)
        header("INFO")
        Text("\(editor.project.clips.count) clip · \(formatShort(editor.duration))").font(.callout).foregroundStyle(.secondary)
        Text("Seleziona una clip per modificarla.").font(.callout).foregroundStyle(.secondary)
    }
}

// MARK: - captions

struct CaptionInspector: View {
    @ObservedObject var editor: Editor
    let id: ID
    @State private var draft = ""
    @State private var draftFor: ID?

    var body: some View {
        if let c = editor.project.captions.first(where: { $0.id == id }) {
            let fps = editor.project.settings.fps
            header("SOTTOTITOLO")
            Text("Testo").font(.system(size: 11)).foregroundStyle(.secondary)
            // edited as a draft so spaces typed at the end aren't eaten
            TextEditor(text: $draft)
                .font(.system(size: 14, weight: .semibold))
                .frame(height: 58)
                .scrollContentBackground(.hidden)
                .background(Color.black.opacity(0.3))
                .cornerRadius(4)
                .onAppear { draft = c.text; draftFor = id }
                .onChange(of: id) { _, new in draft = editor.project.captions.first { $0.id == new }?.text ?? ""; draftFor = new }
                .onChange(of: c.text) { _, t in   // undo / redo
                    if draft.split(whereSeparator: \.isWhitespace).joined(separator: " ") != t { draft = t }
                }
                .onChange(of: draft) { _, v in
                    guard draftFor == id, v != c.text, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    editor.updateCaption(id, key: "caption.\(id).text") { $0.setText(v) }
                }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow { Text("Inizio").foregroundStyle(.secondary); Text(formatTimecode(c.start, fps: fps)) }
                GridRow { Text("Fine").foregroundStyle(.secondary); Text(formatTimecode(c.end, fps: fps)) }
            }
            .font(.system(size: 11).monospacedDigit())
            HStack {
                Button("Vai") { editor.pause(); editor.seek(c.start + min(0.25, c.duration / 2)) }
                Button("Elimina", role: .destructive) { editor.deleteCaption(id) }
            }
            .controlSize(.small)
            Text("Trascina i bordi nella traccia S per cambiare i tempi, C (rasoio) per dividere.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            CaptionStyleControls(editor: editor)
        }
    }
}

/// Look of all the captions + generate / regroup.
struct CaptionStyleControls: View {
    @ObservedObject var editor: Editor

    private func bind<T>(_ kp: WritableKeyPath<CaptionStyle, T>) -> Binding<T> {
        Binding(get: { editor.project.captionStyle[keyPath: kp] },
                set: { v in editor.edit("capstyle.\(kp)") { $0.captionStyle[keyPath: kp] = v } })
    }

    var body: some View {
        let p = editor.project
        header("SOTTOTITOLI AUTOMATICI")
        HStack {
            Button(p.captions.isEmpty ? "Genera dall'audio" : "Rigenera") { editor.generateCaptions() }
                .disabled(editor.transcribing || p.clips.isEmpty)
            if editor.transcribing { ProgressView().controlSize(.small) }
        }
        Picker("Lingua", selection: bind(\.language)) {
            ForEach(Transcriber.languages, id: \.id) { Text($0.name).tag($0.id) }
            if !Transcriber.languages.contains(where: { $0.id == p.captionStyle.language }) { Text(p.captionStyle.language).tag(p.captionStyle.language) }
        }
        Picker("Parole per frase", selection: Binding(get: { p.captionStyle.maxWords }, set: { editor.setCaptionWords($0) })) {
            ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
        }
        Picker("", selection: bind(\.look)) {
            ForEach(CaptionLook.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        Text(p.captionStyle.look == .negative ? "Il testo prende i colori del video, invertiti."
             : p.captionStyle.look == .gold ? "La parola detta si accende in oro." : "Bianco con contorno nero.")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        ValueSlider(title: "Posizione verticale", value: bind(\.y), range: 0.08...0.92) { "\(Int(($0 * 100).rounded()))%" }
        ValueSlider(title: "Dimensione", value: bind(\.size), range: 0.4...2) { "\(Int(($0 * 100).rounded()))%" }
        Toggle("Maiuscolo", isOn: bind(\.uppercase)).font(.system(size: 12))
        Toggle("Animazione pop", isOn: bind(\.pop)).font(.system(size: 12))
        if !p.captions.isEmpty {
            Toggle("Mostra sottotitoli", isOn: Binding(get: { !p.tracks.captionsHidden }, set: { _ in editor.toggleCaptions() }))
                .font(.system(size: 12))
            Button("Elimina tutti i sottotitoli", role: .destructive) {
                editor.edit { $0.captions = [] }
                editor.selectedCaption = nil
            }
            .controlSize(.small)
            Text("\(p.captions.count) frasi · clicca una frase nella traccia S per correggerla")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        } else {
            Text("Trascrive l'audio della timeline sul Mac, senza internet.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - export

struct ExportSheet: View {
    @ObservedObject var editor: Editor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let e = editor.export {
                Text(e.done ? "Esportazione completata" : e.error != nil ? "Esportazione non riuscita" : "Esportazione in corso…")
                    .font(.headline)
                Text(e.url.lastPathComponent).font(.callout).foregroundStyle(.secondary)
                if let err = e.error {
                    Text(err).foregroundStyle(.red).font(.callout)
                } else {
                    ProgressView(value: e.progress)
                }
                HStack {
                    Spacer()
                    if e.done {
                        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }
                        Button("Chiudi") { editor.export = nil }.keyboardShortcut(.defaultAction)
                    } else if e.error != nil {
                        Button("Chiudi") { editor.export = nil }.keyboardShortcut(.defaultAction)
                    } else {
                        Button("Annulla") { editor.cancelExport() }.keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
