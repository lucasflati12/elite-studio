import SwiftUI

// Reframing 360 clips: inspector section + dragging in the viewer.

extension Editor {
    /// The 360 clip to reframe: the selected one, else the topmost one under the playhead.
    func panoTarget() -> Clip? {
        let t = clock.time
        let isPano: (Clip) -> Bool = { self.project.media($0.mediaID)?.pano ?? false }
        if selection.count == 1, let c = project.clips.first(where: { selection.contains($0.id) }), isPano(c) { return c }
        return project.clips.filter { isPano($0) && $0.start <= t && t < $0.end && !project.tracks.videoHidden[$0.track] }
            .max { $0.track < $1.track }
    }

    /// Media time of the playhead inside clip `c` (clamped to the clip).
    func mediaTime(_ c: Clip) -> Double {
        c.sourceTime(at: min(max(clock.time, c.start), c.end - 1e-3))
    }

    func editReframe(_ id: ID, key: String?, _ change: (inout Reframe) -> Void) {
        edit(key.map { "pano.\(id).\($0)" }) { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return }
            var r = p.clips[i].reframe ?? Reframe()
            change(&r)
            p.clips[i].reframe = r
        }
    }

    /// Changes the view at the playhead (moves/creates the keyframe there when the clip has keyframes).
    func editView(_ id: ID, key: String?, _ change: (inout PanoView) -> Void) {
        guard let c = project.clips.first(where: { $0.id == id }) else { return }
        let mt = mediaTime(c)
        let tol = c.speed / Double(max(1, project.settings.fps)) * 0.5
        editReframe(id, key: key) { r in
            var v = r.view(atMedia: mt)
            change(&v)
            v.yaw = remainder(v.yaw, 360)
            v.pitch = min(90, max(-90, v.pitch))
            v.fov = min(v.distance > 0.5 ? 330 : 170, max(20, v.fov))
            r.set(v, atMedia: mt, tolerance: tol)
        }
    }

    /// Viewer drag: grabbing the picture moves it, like in a 360 player.
    func dragPano(delta: CGSize, viewSize: CGSize) {
        guard let c = panoTarget(), viewSize.width > 0 else { return }
        let v = (c.reframe ?? Reframe()).view(atMedia: mediaTime(c))
        let degPerPx = v.fov / Double(viewSize.width)
        editView(c.id, key: "drag") { v in
            v.yaw -= Double(delta.width) * degPerPx
            v.pitch += Double(delta.height) * degPerPx
        }
    }
}

struct PanoInspector: View {
    @ObservedObject var editor: Editor
    @ObservedObject var clock: PlaybackClock
    let id: ID

    var body: some View {
        if let c = editor.project.clips.first(where: { $0.id == id }) {
            let r = c.reframe ?? Reframe()
            let mt = editor.mediaTime(c)
            let v = r.view(atMedia: mt)
            let tol = c.speed / Double(max(1, editor.project.settings.fps)) * 0.5
            let keyHere = r.keys.firstIndex { abs($0.t - mt) <= tol }

            header("360°")
            Text("Trascina nel visore per scegliere l'inquadratura.").font(.system(size: 10)).foregroundStyle(.secondary)
            Toggle("Stabilizzazione (giroscopio)", isOn: Binding(get: { r.stabilize }, set: { b in editor.editReframe(id, key: nil) { $0.stabilize = b } }))
                .font(.system(size: 11))
            if r.stabilize {
                Toggle("Blocca direzione", isOn: Binding(get: { r.lockDirection }, set: { b in editor.editReframe(id, key: nil) { $0.lockDirection = b } }))
                    .font(.system(size: 11))
                    .help("Acceso: l'inquadratura resta ferma nel mondo anche se la camera gira. Spento: segue la camera, in modo morbido.")
                if !r.lockDirection {
                    ValueSlider(title: "Morbidezza", value: Binding(get: { r.smooth }, set: { x in editor.editReframe(id, key: "smooth") { $0.smooth = x } }),
                                range: 0.2...4) { String(format: "%.1f s", $0) }
                }
            }

            ValueSlider(title: "Direzione", value: viewBinding(v, \.yaw), range: -180...180) { "\(Int($0.rounded()))°" }
            ValueSlider(title: "Inclinazione", value: viewBinding(v, \.pitch), range: -90...90) { "\(Int($0.rounded()))°" }
            ValueSlider(title: "Rotazione", value: viewBinding(v, \.roll), range: -45...45) { "\(Int($0.rounded()))°" }
            ValueSlider(title: "Campo visivo", value: viewBinding(v, \.fov), range: 20...(v.distance > 0.5 ? 330 : 170)) { "\(Int($0.rounded()))°" }
            ValueSlider(title: "Prospettiva (normale → grandangolo)", value: viewBinding(v, \.distance), range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
            HStack {
                Button("Normale") { editor.editView(id, key: nil) { $0.fov = 100; $0.distance = 0; $0.roll = 0 } }
                Button("Grandangolo") { editor.editView(id, key: nil) { $0.fov = 140; $0.distance = 0.6; $0.roll = 0 } }
                Button("Pianeta") { editor.editView(id, key: nil) { $0.pitch = -90; $0.fov = 300; $0.distance = 1; $0.roll = 0 } }
            }
            .controlSize(.small)

            header("KEYFRAME")
            Text(r.keys.isEmpty ? "Nessun keyframe: l'inquadratura è fissa per tutta la clip."
                                : "\(r.keys.count) keyframe. Cambiando l'inquadratura si crea/aggiorna il keyframe al cursore.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Button(keyHere == nil ? "◆ Aggiungi" : "◆ Presente") {
                    editor.editReframe(id, key: nil) { rr in
                        if rr.keys.isEmpty { rr.keys = [PanoKey(t: mt, view: v)] } else { rr.set(v, atMedia: mt, tolerance: tol) }
                    }
                }
                .disabled(keyHere != nil)
                Button("Rimuovi") { editor.editReframe(id, key: nil) { rr in if let k = keyHere { rr.view = rr.keys[k].view; rr.keys.remove(at: k) } } }
                    .disabled(keyHere == nil)
                Button("Cancella tutti") { editor.editReframe(id, key: nil) { rr in rr.view = v; rr.keys = [] } }
                    .disabled(r.keys.isEmpty)
            }
            .controlSize(.small)
            if !r.keys.isEmpty {
                HStack(spacing: 6) {
                    Button { jump(c, r.keys.last { $0.t < mt - tol }) } label: { Image(systemName: "chevron.left") }
                    Button { jump(c, r.keys.first { $0.t > mt + tol }) } label: { Image(systemName: "chevron.right") }
                    Text("keyframe precedente / successivo").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func viewBinding(_ v: PanoView, _ kp: WritableKeyPath<PanoView, Double>) -> Binding<Double> {
        Binding(get: { v[keyPath: kp] }, set: { x in editor.editView(id, key: "\(kp)") { $0[keyPath: kp] = x } })
    }

    private func jump(_ c: Clip, _ k: PanoKey?) {
        guard let k else { return }
        editor.seek(c.start + (k.t - c.sourceIn) / c.speed)
    }
}
