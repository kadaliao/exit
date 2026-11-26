import AppKit
import Metal
import simd

/// Mirrors `struct Exit` in prelude.metal. Field order matters (96 bytes with padding).
struct ExitUniforms {
    var win: SIMD4<Float> = .zero
    var accent: SIMD4<Float> = SIMD4(0.35, 0.55, 1.0, 1)
    var size: SIMD2<Float> = .zero
    var cursor: SIMD2<Float> = .zero
    var progress: Float = 0
    var time: Float = 0
    var duration: Float = 1
    var seed: Float = 0
    var scale: Float = 2
    var event: Int32 = 0
    var hasSnapshot: Int32 = 1
    var corner: Float = 20
    var shadow: Float = 0
    private var pad0: Float = 0
    private var pad1: Float = 0
    private var pad2: Float = 0
}

/// Shared Metal state and texture helpers.
final class Renderer {
    static let shared = Renderer()

    let device: MTLDevice
    let queue: MTLCommandQueue

    private init() {
        device = EffectLibrary.shared.device
        guard let q = device.makeCommandQueue() else { fatalError("Cannot create Metal command queue") }
        queue = q
        precondition(MemoryLayout<ExitUniforms>.stride == 96, "ExitUniforms layout mismatch")
    }

    /// Uploads a CGImage as a premultiplied BGRA texture with mipmaps (top row = uv.y 0).
    func makeTexture(from image: CGImage) -> MTLTexture? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        let ok: Bool = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
        }
        return tex
    }

    /// Encodes one effect frame into the given pass.
    func encode(_ pipeline: MTLRenderPipelineState, uniforms: ExitUniforms, texture: MTLTexture?,
                pass: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) {
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<ExitUniforms>.stride, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}

/// Renders effects into images without a window (thumbnails, contact sheets, AI checks).
final class OffscreenRenderer {
    let width: Int
    let height: Int
    private let target: MTLTexture

    init?(width: Int, height: Int) {
        self.width = width
        self.height = height
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let t = Renderer.shared.device.makeTexture(descriptor: desc) else { return nil }
        target = t
    }

    /// Renders one frame and returns raw premultiplied BGRA bytes.
    func renderBytes(_ pipeline: MTLRenderPipelineState, uniforms: ExitUniforms, texture: MTLTexture?) -> [UInt8]? {
        let r = Renderer.shared
        guard let cb = r.queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        r.encode(pipeline, uniforms: uniforms, texture: texture, pass: pass, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error {
            log.error("offscreen render failed: \(err.localizedDescription, privacy: .public)")
            return nil
        }
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        target.getBytes(&data, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return data
    }

    /// Renders one frame and returns it as a CGImage (premultiplied, sRGB).
    func render(_ pipeline: MTLRenderPipelineState, uniforms: ExitUniforms, texture: MTLTexture?) -> CGImage? {
        guard let data = renderBytes(pipeline, uniforms: uniforms, texture: texture) else { return nil }
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Measures average GPU time per frame in milliseconds.
    func benchmark(_ pipeline: MTLRenderPipelineState, uniforms: ExitUniforms, texture: MTLTexture?, frames: Int = 30) -> Double {
        let r = Renderer.shared
        var total: Double = 0
        for i in 0..<frames {
            guard let cb = r.queue.makeCommandBuffer() else { continue }
            var u = uniforms
            u.progress = Float(i) / Float(max(frames - 1, 1))
            u.time = u.progress * u.duration
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            r.encode(pipeline, uniforms: u, texture: texture, pass: pass, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
            total += (cb.gpuEndTime - cb.gpuStartTime) * 1000
        }
        return total / Double(frames)
    }
}
