import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export") {
            guard args.count > i + 2 else { CLI.usage() }
            CLI.run { try await CLI.export(project: args[i + 1], output: args[i + 2], hevc: args.contains("--hevc")) }
        } else if let i = args.firstIndex(of: "--captions") {
            guard args.count > i + 1 else { CLI.usage() }
            func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } }
            CLI.run { try await CLI.captions(project: args[i + 1], language: opt("--lang"), words: opt("--words").flatMap { Int($0) }) }
        } else if let i = args.firstIndex(of: "--check") {
            guard args.count > i + 1 else { CLI.usage() }
            CLI.run { try await CLI.check(project: args[i + 1]) }
        } else {
            EliteStudioApp.main()
        }
    }
}

/// Command line, for scripts and Claude Code:
///   EliteStudio --check  project.elitestudio            prints the timeline as the app will read it
///   EliteStudio --export project.elitestudio out.mp4    renders it (add --hevc for HEVC)
///   EliteStudio --captions project.elitestudio          transcribes the audio and writes captions into the project
@MainActor
enum CLI {
    static func usage() -> Never {
        print("uso:\n  EliteStudio --check progetto.elitestudio\n  EliteStudio --export progetto.elitestudio uscita.mp4 [--hevc]\n  EliteStudio --captions progetto.elitestudio [--lang it-IT] [--words 3]")
        exit(2)
    }

    static func run(_ work: @escaping @MainActor () async throws -> Void) -> Never {
        Overlay.registerFonts()
        Task { @MainActor in
            do { try await work(); exit(0) } catch {
                FileHandle.standardError.write("errore: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    static func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    static func load(_ path: String) async throws -> Project {
        let (p, missing) = try await ProjectLoader.load(url(path))
        for m in missing { FileHandle.standardError.write("file mancante: \(m)\n".data(using: .utf8)!) }
        if !missing.isEmpty { throw NSError(domain: "EliteStudio", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(missing.count) file mancanti"]) }
        return p
    }

    static func check(project: String) async throws {
        let p = try await load(project)
        let u = url(project)
        print(String(data: try ProjectFile.encode(p, base: u.deletingLastPathComponent()), encoding: .utf8)!)
        print("ok: \(p.clips.count) clip, \(String(format: "%.2f", p.duration)) s, \(p.settings.width)x\(p.settings.height)")
    }

    /// Transcribes the timeline audio and saves the captions into the project file (replacing any old ones).
    static func captions(project: String, language: String?, words: Int?) async throws {
        var p = try await load(project)
        if let language { p.captionStyle.language = language }
        if let words { p.captionStyle.maxWords = min(8, max(1, words)) }
        let w = try await Transcriber.words(project: p, language: p.captionStyle.language) { s in
            FileHandle.standardError.write("\(s)\n".data(using: .utf8)!)
        }
        p.captions = Captions.chunks(w, maxWords: p.captionStyle.maxWords)
        p.tracks.captionsHidden = false
        let u = url(project)
        try ProjectFile.encode(p, base: u.deletingLastPathComponent()).write(to: u, options: .atomic)
        for c in p.captions.prefix(12) { print(String(format: "%7.2f %7.2f  ", c.start, c.end) + c.text) }
        if p.captions.count > 12 { print("…") }
        print("ok: \(p.captions.count) sottotitoli, \(w.count) parole → \(u.path)")
    }

    static func export(project: String, output: String, hevc: Bool) async throws {
        let p = try await load(project)
        var last = -1
        try await Exporter.run(project: p, to: url(output), hevc: hevc) { pr in
            let pct = Int(pr * 100)
            if pct / 10 != last / 10 { last = pct; print("\(pct)%"); fflush(stdout) }
        }
        print("ok \(url(output).path)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingOpen: URL?
    private var launched = false

    func applicationWillFinishLaunching(_ n: Notification) {
        Overlay.registerFonts()
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        KeyHandler.install()
        launched = true
        let editor = Editor.shared
        // a project path on the command line wins, then a file opened from Finder, then the last session
        if let arg = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".elitestudio") || $0.hasSuffix(".json") }) {
            editor.open(URL(fileURLWithPath: (arg as NSString).expandingTildeInPath))
        } else if let u = pendingOpen {
            editor.open(u)
        } else {
            editor.restoreLastSession()
        }
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        guard let u = urls.first(where: { $0.pathExtension == "elitestudio" }) else {
            Task { @MainActor in await Editor.shared.importMedia(urls) }
            return
        }
        if launched { Editor.shared.open(u) } else { pendingOpen = u }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

struct EliteStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var editor = Editor.shared

    var body: some Scene {
        Window("Elite Studio", id: "main") {
            ContentView(editor: editor)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuovo progetto") { editor.newProject() }.keyboardShortcut("n")
                Button("Apri progetto…") { Commands.open() }.keyboardShortcut("o")
                Divider()
                Button("Salva") { Commands.save() }.keyboardShortcut("s")
                Button("Salva con nome…") { Commands.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Importa media…") { Commands.importMedia() }.keyboardShortcut("i")
                Button("Ricollega file mancanti…") { Commands.relinkMedia() }
                Button("Apri versione precedente come copia…") { editor.restoreVersion() }
                Button("Esporta video…") { Commands.exportVideo() }.keyboardShortcut("e")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Annulla") { Commands.typing ? Commands.send("undo:") : editor.undo() }.keyboardShortcut("z")
                Button("Ripeti") { Commands.typing ? Commands.send("redo:") : editor.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Taglia") { Commands.send("cut:") }.keyboardShortcut("x")
                Button("Copia") { Commands.typing ? Commands.send("copy:") : editor.copy() }.keyboardShortcut("c")
                Button("Incolla") { Commands.typing ? Commands.send("paste:") : editor.paste() }.keyboardShortcut("v")
                Button("Seleziona tutto") { Commands.typing ? Commands.send("selectAll:") : editor.selectAll() }.keyboardShortcut("a")
            }
            CommandMenu("Colore") {
                Button("Colore…") { GradingWindow.show(editor) }.keyboardShortcut("g")
                Divider()
                Button("Copia grading") { GradingWindow.copyGrade() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Incolla grading") { GradingWindow.pasteGrade() }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Sequenza") {
                Button("Taglia al playhead") { editor.addEdit() }.keyboardShortcut("k")
                Button("Aggiungi titolo") { editor.addTitle() }.keyboardShortcut("t")
                Button("Aggiungi testo libero") { editor.addPlainText() }
                Button("Aggiungi traccia video/audio") { editor.addTrack() }
                Button("Dissolvenza incrociata con precedente") { editor.crossfadeSelection() }
                Button("Genera sottotitoli automatici") { editor.generateCaptions() }.disabled(editor.transcribing)
                Divider()
                Button("Elimina   ⌫") { editor.deleteSelection(ripple: false) }
                Button("Elimina e chiudi lo spazio   ⇧⌫") { editor.deleteSelection(ripple: true) }
                Button("Rifila inizio fino al playhead   Q") { editor.rippleTrim(toPlayhead: true) }
                Button("Rifila fine dal playhead   W") { editor.rippleTrim(toPlayhead: false) }
                Divider()
                Button("Adatta timeline   \\") { editor.fitTimeline?() }
            }
        }
    }
}

@MainActor
enum Commands {
    static var editor: Editor { Editor.shared }
    static var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }
    static func send(_ sel: String) { NSApp.sendAction(Selector(sel), to: nil, from: nil) }

    /// Folder of the first media file: default place for projects and exports.
    static var mediaFolder: URL? { editor.project.media.first?.url.deletingLastPathComponent() }

    static func importMedia() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.movie, .audio, .image, .data, .folder]
        p.message = "Scegli video, audio, foto, file Insta360 o un'intera cartella"
        guard p.runModal() == .OK else { return }
        Task { await editor.importMedia(p.urls) }
    }

    static func open() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [Editor.fileType, .json]
        guard p.runModal() == .OK, let u = p.url else { return }
        editor.open(u)
    }

    static func relinkMedia() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = "Scegli la cartella che contiene i video spostati: verranno cercati anche nelle sottocartelle"
        guard p.runModal() == .OK, let folder = p.url else { return }
        Task { await editor.relinkMissingMedia(in: folder) }
    }

    static func save() {
        if let u = editor.projectURL { editor.save(to: u) } else { saveAs() }
    }

    static func saveAs() {
        let p = NSSavePanel()
        p.allowedContentTypes = [Editor.fileType]
        p.nameFieldStringValue = editor.projectURL?.lastPathComponent ?? "Montaggio.elitestudio"
        if let d = mediaFolder { p.directoryURL = d }
        guard p.runModal() == .OK, let u = p.url else { return }
        editor.save(to: u)
    }

    static func exportVideo() {
        guard !editor.project.clips.isEmpty else { editor.status = "La timeline è vuota"; return }
        let options = NSAlert(); options.messageText = "Esporta video"
        options.informativeText = "Scegli formato e codec. Il progetto di montaggio resta invariato."
        options.addButton(withTitle: "Continua"); options.addButton(withTitle: "Annulla")
        let box = NSStackView(); box.orientation = .vertical; box.spacing = 8; box.frame = CGRect(x: 0, y: 0, width: 280, height: 70)
        let format = NSPopUpButton(frame: .zero, pullsDown: false); format.addItems(withTitles: ["Formato della sequenza", "Verticale · 1080×1920", "Orizzontale · 1920×1080", "Quadrato · 1080×1080", "Anteprima · lato lungo 720"])
        let codec = NSPopUpButton(frame: .zero, pullsDown: false); codec.addItems(withTitles: ["H.264 · compatibilità", "HEVC · file più piccolo"])
        box.addArrangedSubview(format); box.addArrangedSubview(codec); options.accessoryView = box
        guard options.runModal() == .alertFirstButtonReturn else { return }
        var width = editor.project.settings.width, height = editor.project.settings.height
        switch format.indexOfSelectedItem {
        case 1: width = 1080; height = 1920
        case 2: width = 1920; height = 1080
        case 3: width = 1080; height = 1080
        case 4:
            let factor = min(1, 720.0 / Double(max(width, height)))
            width = max(2, Int((Double(width) * factor / 2).rounded()) * 2)
            height = max(2, Int((Double(height) * factor / 2).rounded()) * 2)
        default: break
        }
        let p = NSSavePanel()
        p.allowedContentTypes = [.mpeg4Movie]
        p.nameFieldStringValue = (editor.projectURL?.deletingPathExtension().lastPathComponent ?? "Montaggio") + ".mp4"
        if let d = mediaFolder {
            let edited = d.appendingPathComponent("editati")
            p.directoryURL = FileManager.default.fileExists(atPath: edited.path) ? edited : d
        }
        guard p.runModal() == .OK, let u = p.url else { return }
        editor.startExport(to: u, hevc: codec.indexOfSelectedItem == 1, width: width, height: height)
    }
}

/// Single-key shortcuts (Premiere style). Ignored while typing in a text field.
@MainActor
enum KeyHandler {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handle(e) ? nil : e
        }
    }

    private static func handle(_ e: NSEvent) -> Bool {
        guard let w = NSApp.keyWindow, w.attachedSheet == nil, NSApp.modalWindow == nil,
              !(w.firstResponder is NSText) else { return false }
        let flags = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) || flags.contains(.control) { return false }
        let ed = Editor.shared
        let shift = flags.contains(.shift)
        switch e.keyCode {
        case 49: ed.togglePlay(); return true                                  // space
        case 123: ed.step(frames: shift ? -5 : -1); return true                // ←
        case 124: ed.step(frames: shift ? 5 : 1); return true                  // →
        case 126: ed.jumpEdit(forward: false); return true                     // ↑
        case 125: ed.jumpEdit(forward: true); return true                      // ↓
        case 51, 117:
            if let mediaID = ed.selectedMediaID {
                ed.removeMedia(mediaID)
                return true
            }
            ed.deleteSelection(ripple: shift || flags.contains(.option)); return true
        case 115: ed.pause(); ed.seek(0); return true                          // home
        case 119: ed.pause(); ed.seek(ed.duration); return true                // end
        case 53: ed.selection = []; ed.gap = nil; ed.selectedMediaID = nil; ed.selectedCaption = nil; return true   // esc
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "v": ed.tool = .select
        case "c": ed.tool = .razor
        case "s": ed.snapping.toggle()
        case "j": ed.shuttle(-1)
        case "k": ed.pause()
        case "l": ed.shuttle(1)
        case "q": ed.rippleTrim(toPlayhead: true)
        case "w": ed.rippleTrim(toPlayhead: false)
        case "=", "+": ed.zoomTimeline?(1.5)
        case "-": ed.zoomTimeline?(1 / 1.5)
        case "\\": ed.fitTimeline?()
        default: return false
        }
        return true
    }
}
