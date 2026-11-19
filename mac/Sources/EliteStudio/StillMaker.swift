import AVFoundation
import ImageIO
import CoreImage
import CryptoKit

/// Photos on the timeline: AVFoundation only edits video, so a photo becomes a short silent video
/// (60 s long, two frames, tiny) the first time it is imported. Default length on the timeline: 5 s.
enum StillMaker {
    static let imageExtensions = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif"]
    static let defaultDuration = 5.0
    static let folderName = "Elite Studio foto"

    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    /// Where generated photo videos go: next to the project if it has been saved, otherwise in Application Support.
    static func folder(projectFolder: URL?) -> URL {
        let base = projectFolder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EliteStudio")
        let d = base.appendingPathComponent(folderName)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Returns the video for a photo, making it if needed (reused while the photo is unchanged).
    static func video(for image: URL, in folder: URL) async throws -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: image.path)
        let stamp = "\(image.standardizedFileURL.path)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let hash = SHA256.hash(data: Data(stamp.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let out = folder.appendingPathComponent("\(image.deletingPathExtension().lastPathComponent)-\(hash).mov")
        if FileManager.default.fileExists(atPath: out.path) { return out }

        guard let src = CGImageSourceCreateWithURL(image as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,      // apply the EXIF rotation
                kCGImageSourceThumbnailMaxPixelSize: 3840,
              ] as CFDictionary) else {
            throw NSError(domain: "EliteStudio", code: 5, userInfo: [NSLocalizedDescriptionKey: "\(image.lastPathComponent): immagine non leggibile"])
        }
        let w = max(2, cg.width & ~1), h = max(2, cg.height & ~1)
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(out.lastPathComponent).part.mov")
        try? FileManager.default.removeItem(at: tmp)
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            // one good keyframe, then frames that repeat it (almost free)
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: w * h * 3, AVVideoMaxKeyFrameIntervalKey: 61,
                                              AVVideoAllowFrameReorderingKey: false],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "EliteStudio", code: 6) }
        writer.startSession(atSourceTime: .zero)

        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &pb)
        guard let pb else { throw NSError(domain: "EliteStudio", code: 7) }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        // the picture never changes: one frame at the start and one near the end are enough
        for second in [0, 59] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(second), timescale: 1))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 60, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "EliteStudio", code: 8) }
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }
}
