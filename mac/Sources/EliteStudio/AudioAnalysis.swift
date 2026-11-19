import Foundation
import AVFoundation

enum AudioAnalysis {
    static func gain(url: URL, start: Double, duration: Double) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 1 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "EliteStudio", code: 30) }
        var sum = 0.0, peak = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0; var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { p in
                for i in 0..<(length / 4) { let x = Double(p[i]); sum += x * x; peak = max(peak, abs(x)); count += 1 }
            }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "EliteStudio", code: 31) }
        guard count > 0, peak > 0 else { return 1 }
        let rms = sqrt(sum / Double(count))
        return min(2, min(pow(10, -18.0 / 20) / max(0.000001, rms), pow(10, -1.5 / 20) / peak))
    }
}

@MainActor
extension Editor {
    func normalizeAudio(_ id: ID) {
        guard let c = project.clips.first(where: { $0.id == id }), let media = project.media(c.mediaID), media.hasAudio else { return }
        status = "Analizzo il volume della clip…"
        let url = media.url, start = c.sourceIn, duration = c.sourceDuration
        Task {
            do {
                let gain = try await Task.detached { try await AudioAnalysis.gain(url: url, start: start, duration: duration) }.value
                guard project.clips.first(where: { $0.id == id }) == c else { return }
                edit { p in
                    guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return }
                    p.clips[i].volume = gain
                    let factor = gain / max(0.000001, c.volume)
                    for j in p.clips[i].effects.keys.indices { p.clips[i].effects.keys[j].volume = min(2, p.clips[i].effects.keys[j].volume * factor) }
                }
                status = "Volume regolato al \(Int((gain * 100).rounded()))%, con margine sui picchi"
            } catch { status = "Analisi audio non riuscita: \(error.localizedDescription)" }
        }
    }
}
