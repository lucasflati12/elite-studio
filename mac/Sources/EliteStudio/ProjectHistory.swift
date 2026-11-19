import Foundation
import CryptoKit
import AppKit

enum ProjectHistory {
    static func folder(for url: URL) -> URL {
        let key = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EliteStudio/history/\(key)", isDirectory: true)
    }
    static func backup(_ url: URL) {
        let manager = FileManager.default, folder = Self.folder(for: url)
        do {
            guard manager.fileExists(atPath: url.path) else { return }
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let last = files.last, let date = try last.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) < 60 { return }
            let p = try ProjectFile.decode(Data(contentsOf: url), base: url.deletingLastPathComponent())
            let stamp = String(format: "%.0f", Date().timeIntervalSince1970)
            try ProjectFile.encode(p, base: nil).write(to: folder.appendingPathComponent(stamp + ".elitestudio"), options: .atomic)
            for old in files.prefix(max(0, files.count - 9)) { try? manager.removeItem(at: old) }
        } catch { /* History is supplementary; the primary save must still proceed. */ }
    }
}

@MainActor
extension Editor {
    func restoreVersion() {
        guard let url = projectURL else { status = "Salva prima il progetto per creare la cronologia"; return }
        let folder = ProjectHistory.folder(for: url)
        guard FileManager.default.fileExists(atPath: folder.path) else { status = "Nessuna versione precedente disponibile"; return }
        let panel = NSOpenPanel(); panel.directoryURL = folder; panel.allowedContentTypes = [Editor.fileType]
        panel.message = "Apri una versione precedente come copia; il progetto originale resta salvato"
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        open(selected); projectURL = nil
        UserDefaults.standard.removeObject(forKey: "lastProject")
        status = "Versione precedente aperta come copia: usa Salva con nome"
    }
}
