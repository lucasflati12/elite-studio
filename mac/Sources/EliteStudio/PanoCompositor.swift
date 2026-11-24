import Foundation
import AVFoundation
import Metal
import CoreVideo
import simd

// Custom video compositor used only when the project contains 360 clips or captions.
// Normal clips are drawn with their usual transform/opacity; 360 clips are rendered from the
// fisheye picture(s) with stabilization + reframing, in one pass on the GPU; captions go on top.

/// One layer of an instruction, bottom to top.
struct CompLayer {
    enum Kind { case flat, pano }
    var kind: Kind
    var trackID: CMPersistentTrackID
    var trackID2: CMPersistentTrackID = kCMPersistentTrackID_Invalid   // second lens of a two-file 360 clip
    var transform = CGAffineTransform.identity                          // source px -> frame px (flat)
    var opacity: Float = 1
    var clip: Clip?
    // 360
    var pano: PanoData?
    var reframe = Reframe()
    var clipStart = 0.0, sourceIn = 0.0, speed = 1.0
    var frameRate = 0.0                                                 // of the 360 file; 0 = unknown

    func mediaTime(_ t: Double) -> Double { sourceIn + (t - clipStart) * speed }
    /// Start time of the source frame AVFoundation shows at media time `mt` (the frame whose interval contains it).
    /// The gyro must be read there, not at `mt`: they differ by up to one frame, by a varying amount when the
    /// sequence fps differs from the camera's, which showed up as residual wobble after stabilization.
    func frameTime(_ mt: Double) -> Double {
        guard frameRate > 0 else { return mt }
        return (mt * frameRate + 1e-3).rounded(.down) / frameRate
    }
}

final class CompInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [CompLayer]
    let captions: CaptionTrack?
    let overlays: OverlayTrack?

    init(timeRange: CMTimeRange, layers: [CompLayer], captions: CaptionTrack? = nil, overlays: OverlayTrack? = nil) {
        self.timeRange = timeRange
        self.layers = layers
        self.captions = captions
        self.overlays = overlays
        var ids: [NSValue] = []
        for l in layers {
            ids.append(NSNumber(value: l.trackID))
            if l.trackID2 != kCMPersistentTrackID_Invalid { ids.append(NSNumber(value: l.trackID2)) }
        }
        requiredSourceTrackIDs = ids.isEmpty ? nil : ids
    }
}

final class PanoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]

    private let queue = DispatchQueue(label: "elitestudio.pano.render")
    private var renderContext: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard let ins = request.videoCompositionInstruction as? CompInstruction,
                  let out = self.renderContext?.newPixelBuffer() ?? request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "EliteStudio", code: 10, userInfo: nil)); return
            }
            let t = request.compositionTime.seconds
            if GPU.shared?.render(ins, request: request, time: t, into: out) == true {
                request.finish(withComposedVideoFrame: out)
            } else {
                request.finish(with: NSError(domain: "EliteStudio", code: 11, userInfo: [NSLocalizedDescriptionKey: "rendering 360 non riuscito"]))
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

/// Metal state shared by every compositor instance.
final class GPU: @unchecked Sendable {
    static let shared = GPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let flat: MTLComputePipelineState
    let pano: MTLComputePipelineState
    let clear: MTLComputePipelineState
    let finish: MTLComputePipelineState
    let caption: MTLComputePipelineState
    private var cache: CVMetalTextureCache?
    private var accum: MTLTexture?
    private let captionLock = NSLock()
    private var captionTextures: [String: MTLTexture] = [:]

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        do {
            let lib = try d.makeLibrary(source: GPU.source, options: nil)
            func pipe(_ n: String) throws -> MTLComputePipelineState { try d.makeComputePipelineState(function: lib.makeFunction(name: n)!) }
            flat = try pipe("flatLayer"); pano = try pipe("panoLayer"); clear = try pipe("clearAcc"); finish = try pipe("finishOut")
            caption = try pipe("captionLayer")
        } catch {
            NSLog("EliteStudio: Metal setup failed: \(error)")
            return nil
        }
        device = d; queue = q
        CVMetalTextureCacheCreate(nil, nil, d, nil, &cache)
    }

    private func texture(_ pb: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        guard let cache else { return nil }
        var ref: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &ref) == kCVReturnSuccess,
              let ref, let tex = CVMetalTextureGetTexture(ref) else { return nil }
        return (tex, ref)
    }

    func render(_ ins: CompInstruction, request: AVAsynchronousVideoCompositionRequest, time: Double, into out: CVPixelBuffer) -> Bool {
        guard let (outTex, outRef) = texture(out), let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else {
            NSLog("EliteStudio: PanoCompositor failed to get outTex or encoder")
            return false
        }
        let w = outTex.width, h = outTex.height
        if accum == nil || accum!.width != w || accum!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
            accum = device.makeTexture(descriptor: d)
        }
        guard let acc = accum else { return false }
        var keep: [CVMetalTexture] = [outRef]
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)

        enc.setComputePipelineState(clear)
        enc.setTexture(acc, index: 0)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)

        for original in ins.layers {
            var l = original
            let e = l.clip?.effects ?? ClipEffects()
            var motion = MotionKey()
            if let c = l.clip { motion = c.motion(at: time); l.opacity = Float(motion.opacity * c.envelope(at: time)) }
            let placement = CGAffineTransform(translationX: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
                .concatenating(CGAffineTransform(scaleX: motion.scale, y: motion.scale))
                .concatenating(CGAffineTransform(rotationAngle: motion.rotation * .pi / 180))
                .concatenating(CGAffineTransform(translationX: CGFloat(w) / 2 + motion.x * CGFloat(w), y: CGFloat(h) / 2 + motion.y * CGFloat(h)))
            guard let pb = request.sourceFrame(byTrackID: l.trackID), let (src, r1) = texture(pb) else { continue }
            keep.append(r1)
            if l.kind == .flat {
                let inv = l.transform.concatenating(placement).inverted()
                var u: [SIMD4<Float>] = [
                    SIMD4(Float(inv.a), Float(inv.b), Float(inv.c), Float(inv.d)),
                    SIMD4(Float(inv.tx), Float(inv.ty), Float(src.width), Float(src.height)),
                    SIMD4(l.opacity, 0, 0, 0),
                    SIMD4(Float(e.exposure), Float(e.contrast), Float(e.saturation), Float(e.temperature)),
                ]
                enc.setComputePipelineState(flat)
                enc.setTexture(src, index: 0); enc.setTexture(acc, index: 1)
                enc.setBytes(&u, length: MemoryLayout<SIMD4<Float>>.stride * u.count, index: 0)
                enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            } else if let p = l.pano, p.lenses.count == 2 {
                var src2 = src
                if l.trackID2 != kCMPersistentTrackID_Invalid {
                    guard let pb2 = request.sourceFrame(byTrackID: l.trackID2), let (t2, r2) = texture(pb2) else { continue }
                    src2 = t2; keep.append(r2)
                }
                var u = GPU.panoUniforms(l, p, time: time, width: w, height: h)
                let inv = placement.inverted()
                u.append(SIMD4(Float(inv.a), Float(inv.b), Float(inv.c), Float(inv.d)))
                u.append(SIMD4(Float(inv.tx), Float(inv.ty), 0, 0))
                u.append(SIMD4(Float(e.exposure), Float(e.contrast), Float(e.saturation), Float(e.temperature)))
                enc.setComputePipelineState(pano)
                enc.setTexture(src, index: 0); enc.setTexture(src2, index: 1); enc.setTexture(acc, index: 2)
                enc.setBytes(&u, length: MemoryLayout<SIMD4<Float>>.stride * u.count, index: 0)
                enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            }
        }
        // captions, then (export only) titles and logo on top
        var stamps: [CaptionTrack.State] = []
        if let st = ins.captions?.state(at: time) { stamps.append(st) }
        if let o = ins.overlays { stamps += o.states(at: time) }
        for st in stamps {
            guard let tex = captionTexture(st) else { continue }
            let r = st.bitmap.rect.offsetBy(dx: st.dx, dy: 0)
            var u: [SIMD4<Float>] = [
                SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                SIMD4(st.scale, st.alpha, st.difference ? 1 : 0, 0),
            ]
            enc.setComputePipelineState(caption)
            enc.setTexture(tex, index: 0); enc.setTexture(acc, index: 1)
            enc.setBytes(&u, length: MemoryLayout<SIMD4<Float>>.stride * u.count, index: 0)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        }
        enc.setComputePipelineState(finish)
        enc.setTexture(acc, index: 0); enc.setTexture(outTex, index: 1)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        _ = keep
        return cb.status == .completed
    }

    /// GPU copy of a caption bitmap, kept while the same phrase is on screen.
    private func captionTexture(_ st: CaptionTrack.State) -> MTLTexture? {
        captionLock.lock(); defer { captionLock.unlock() }
        if let t = captionTextures[st.key] { return t }
        let b = st.bitmap
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: b.width, height: b.height, mipmapped: false)
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        b.bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, b.width, b.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: b.bytesPerRow) }
        if captionTextures.count > 64 { captionTextures.removeAll() }
        captionTextures[st.key] = t
        return t
    }

    /// Packs one 360 layer for the shader (see `panoLayer` for the layout).
    static func panoUniforms(_ l: CompLayer, _ p: PanoData, time: Double, width: Int, height: Int) -> [SIMD4<Float>] {
        let mt = l.mediaTime(time)
        let v = l.reframe.view(atMedia: mt)
        // view -> camera: stabilization, then the chosen direction
        let stab: simd_quatf = l.reframe.stabilize ? p.stabilization(at: l.frameTime(mt), lockDirection: l.reframe.lockDirection, smooth: l.reframe.smooth)
                                                   : simd_quatf(angle: 0, axis: [0, 1, 0])
        let look = rotY(v.yaw) * rotX(-v.pitch) * rotZ(-v.roll)
        let s = simd_double3x3(simd_quatd(ix: Double(stab.imag.x), iy: Double(stab.imag.y), iz: Double(stab.imag.z), r: Double(stab.real)))
        let r = s * look
        let k = max(0, min(1.5, v.distance))
        let half = max(5, min(v.fov, 350)) / 2 * .pi / 180
        // half-width of the image plane for the requested field of view (at most just short of the limit)
        let denom = max(0.02, k + cos(half))
        let xmax = (k + 1) * sin(half) / denom
        let ymax = xmax * Double(height) / Double(width)
        func row(_ m: simd_double3x3, _ i: Int) -> SIMD4<Float> { SIMD4(Float(m[0][i]), Float(m[1][i]), Float(m[2][i]), 0) }
        let pc = p.poly + [0, 0, 0, 0, 0]
        let p100 = (0..<5).reduce(0.0) { $0 + pc[$1] * pow(100, Double($1)) }
        var u: [SIMD4<Float>] = [
            row(r, 0), row(r, 1), row(r, 2),
            SIMD4(Float(xmax), Float(ymax), Float(k), l.opacity),
            SIMD4(Float(width), Float(height), 6, Float(p100)),
            SIMD4(Float(pc[1]), Float(pc[2]), Float(pc[3]), Float(pc[4])),
        ]
        for lens in p.lenses.prefix(2) {
            let a = lens.alpha * .pi / 180
            u.append(SIMD4(Float(lens.cx + lens.xOffset), Float(lens.cy), Float(lens.r100), Float(pc[0])))
            u.append(SIMD4(Float(cos(a)), Float(sin(a)), 0, 0))
            // camera -> lens = transpose of lens -> camera
            let t = lens.rotation.transpose
            u.append(row(t, 0)); u.append(row(t, 1)); u.append(row(t, 2))
        }
        return u
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    static float3 grade(float3 rgb, float4 e) {
        rgb = clamp((rgb * exp2(e.x) * float3(1.0 + 0.15 * e.w, 1.0, 1.0 - 0.15 * e.w) - 0.5) * e.y + 0.5, 0.0, 1.0);
        float gray = dot(rgb, float3(0.299, 0.587, 0.114));
        return clamp(mix(float3(gray), rgb, e.z), 0.0, 1.0);
    }

    kernel void clearAcc(texture2d<half, access::write> acc [[texture(0)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= acc.get_width() || g.y >= acc.get_height()) return;
        acc.write(half4(0, 0, 0, 1), g);
    }

    kernel void finishOut(texture2d<half, access::read> acc [[texture(0)]], texture2d<half, access::write> outT [[texture(1)]],
                          uint2 g [[thread_position_in_grid]]) {
        if (g.x >= outT.get_width() || g.y >= outT.get_height()) return;
        outT.write(half4(acc.read(g).rgb, 1), g);
    }

    // u[0] = inverse transform a b c d, u[1] = tx ty srcW srcH, u[2].x = opacity
    kernel void flatLayer(texture2d<float, access::sample> src [[texture(0)]], texture2d<half, access::read_write> acc [[texture(1)]],
                          constant float4 *u [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= acc.get_width() || g.y >= acc.get_height()) return;
        float2 p = float2(g) + 0.5;
        float2 s = float2(u[0].x * p.x + u[0].z * p.y + u[1].x, u[0].y * p.x + u[0].w * p.y + u[1].y);
        if (s.x < 0 || s.y < 0 || s.x > u[1].z || s.y > u[1].w) return;
        constexpr sampler smp(coord::pixel, filter::linear, address::clamp_to_edge);
        float4 c = src.sample(smp, s);
        half4 d = acc.read(g);
        // source alpha counts (ProRes 4444 overlays on V2); normal video has alpha 1
        acc.write(half4(half3(mix(float3(d.rgb), grade(c.rgb, u[3]), u[2].x * c.a)), 1.0h), g);
    }

    // Caption on top of the picture. u[0] = rect x y w h (frame px), u[1] = scale, alpha, mode (1 = difference / "negativo")
    kernel void captionLayer(texture2d<float, access::sample> img [[texture(0)]], texture2d<half, access::read_write> acc [[texture(1)]],
                             constant float4 *u [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= acc.get_width() || g.y >= acc.get_height()) return;
        float2 size = u[0].zw;
        float2 q = (float2(g) + 0.5 - (u[0].xy + size * 0.5)) / u[1].x + size * 0.5;   // pop: scale around the centre
        if (q.x < 0 || q.y < 0 || q.x >= size.x || q.y >= size.y) return;
        constexpr sampler smp(coord::pixel, filter::linear, address::clamp_to_zero);
        float4 s = img.sample(smp, q * float2(img.get_width(), img.get_height()) / size);
        float a = s.a * u[1].y;
        if (a <= 0.0) return;
        float3 d = float3(acc.read(g).rgb);
        float3 o = u[1].z > 0.5 ? mix(d, abs(s.rgb / max(s.a, 1e-4) - d), a)   // difference blend: white text = inverted video
                                : d * (1.0 - a) + s.rgb * u[1].y;             // premultiplied "over"
        acc.write(half4(half3(o), 1.0h), g);
    }

    // u[0..2] view->camera rows, u[3] = xmax ymax k opacity, u[4] = outW outH blendDeg p100, u[5] = c1..c4
    // per lens (base 6 and 11): [cx+xoff, cy, r100, c0], [cos a, sin a], camera->lens rows ×3
    static float4 lensSample(texture2d<float, access::sample> tex, constant float4 *u, int b, float3 d, thread float &w) {
        float3 l = float3(dot(u[b + 2].xyz, d), dot(u[b + 3].xyz, d), dot(u[b + 4].xyz, d));
        float th = acos(clamp(l.z, -1.0, 1.0)) * 57.29577951;
        float blend = u[4].z;
        w = clamp((90.0 + blend * 0.5 - th) / blend, 0.0, 1.0);
        if (w <= 0) return float4(0);
        float poly = u[b].w + th * (u[5].x + th * (u[5].y + th * (u[5].z + th * u[5].w)));
        float rho = u[b].z * poly / u[4].w;
        float2 dir = normalize(l.xy + float2(1e-9, 0));
        float2 rd = float2(dir.x * u[b + 1].x - dir.y * u[b + 1].y, dir.x * u[b + 1].y + dir.y * u[b + 1].x);
        float2 px = float2(u[b].x + rho * rd.x, u[b].y - rho * rd.y) + 0.5;
        constexpr sampler smp(coord::pixel, filter::linear, address::clamp_to_edge);
        return tex.sample(smp, px);
    }

    kernel void panoLayer(texture2d<float, access::sample> lens0 [[texture(0)]], texture2d<float, access::sample> lens1 [[texture(1)]],
                          texture2d<half, access::read_write> acc [[texture(2)]],
                          constant float4 *u [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= acc.get_width() || g.y >= acc.get_height()) return;
        float2 pix = float2(g) + 0.5;
        pix = float2(u[16].x * pix.x + u[16].z * pix.y + u[17].x, u[16].y * pix.x + u[16].w * pix.y + u[17].y);
        if (any(pix < 0.0) || any(pix >= u[4].xy)) return;
        float2 q = pix / u[4].xy * 2.0 - 1.0;
        float k = u[3].z;
        float3 v = float3(q.x * u[3].x, -q.y * u[3].y, 1.0 + k);
        float3 P = float3(0, 0, -k);
        // ray from (0,0,-k) through the image plane, hitting the unit sphere: k=0 rectilinear, k=1 stereographic
        float vv = dot(v, v), pv = dot(P, v);
        float disc = pv * pv - vv * (k * k - 1.0);
        float s = (-pv + sqrt(max(disc, 0.0))) / vv;
        float3 dir = normalize(P + s * v);
        float3 d = float3(dot(u[0].xyz, dir), dot(u[1].xyz, dir), dot(u[2].xyz, dir));
        float w0, w1;
        float4 c0 = lensSample(lens0, u, 6, d, w0);
        float4 c1 = lensSample(lens1, u, 11, d, w1);
        float ws = w0 + w1;
        if (ws <= 0) return;
        float3 c = (c0.rgb * w0 + c1.rgb * w1) / ws;
        half4 old = acc.read(g);
        acc.write(half4(half3(mix(float3(old.rgb), grade(c, u[18]), u[3].w)), 1.0h), g);
    }
    """
}
