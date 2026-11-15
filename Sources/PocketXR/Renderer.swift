import Metal
import PocketXRCore
import QuartzCore
import simd

/// Draws the Space on the glasses: each screen a textured panel, seen from the head's pose, once per eye in 3D side by
/// side (each half of a 3840x1080 picture), else once. Then Pocket XR's "Soft" edge fade, so panels end in black
/// (the glasses show black as see-through) rather than at a hard line.
final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let panelPipeline: MTLRenderPipelineState
    private let fadePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    /// The eyes' distance apart, metres.
    static let ipd = 0.064

    private struct PanelUniforms {
        var mvp: simd_float4x4
        var tint: SIMD4<Float> // a rim colour where there is no picture yet
        var hasTexture: Float
        var pad: SIMD3<Float> = .zero
    }

    private struct FadeUniforms {
        var size: SIMD2<Float> // the eye's viewport, pixels
        var pad: SIMD2<Float> = .zero
        var edges: SIMD4<Float> // fade widths, pixels: left, right, top, bottom
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        queue = q
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let p = MTLRenderPipelineDescriptor()
            p.vertexFunction = lib.makeFunction(name: "panelVertex")
            p.fragmentFunction = lib.makeFunction(name: "panelFragment")
            p.colorAttachments[0].pixelFormat = pixelFormat
            panelPipeline = try device.makeRenderPipelineState(descriptor: p)
            let f = MTLRenderPipelineDescriptor()
            f.vertexFunction = lib.makeFunction(name: "fadeVertex")
            f.fragmentFunction = lib.makeFunction(name: "fadeFragment")
            f.colorAttachments[0].pixelFormat = pixelFormat
            f.colorAttachments[0].isBlendingEnabled = true
            f.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            f.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            f.colorAttachments[0].sourceAlphaBlendFactor = .one
            f.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            fadePipeline = try device.makeRenderPipelineState(descriptor: f)
        } catch {
            plog("renderer: shaders failed: \(error)")
            return nil
        }
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .notMipmapped
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        guard let samp = device.makeSamplerState(descriptor: s) else { return nil }
        sampler = samp
    }

    /// One frame into [drawable]: [panels] seen from [head]. [fovYDeg] is each eye's vertical field.
    func draw(drawable: CAMetalDrawable, head: Quat, panels: [(PanelPlacement, MTLTexture?)], fovYDeg: Double) {
        let w = drawable.texture.width, h = drawable.texture.height
        let sbs = w >= 3 * h
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Each eye: (its offset in metres, right positive; its viewport x; its width; fades left and right).
        let eyes: [(Double, Int, Int, Float, Float)] = sbs
            ? [(-Self.ipd / 2, 0, w / 2, 96, 48), (Self.ipd / 2, w / 2, w / 2, 48, 96)]
            : [(0, 0, w, 96, 96)]
        for (eyeX, vx, vw, fadeL, fadeR) in eyes {
            enc.setViewport(MTLViewport(originX: Double(vx), originY: 0, width: Double(vw), height: Double(h), znear: 0, zfar: 1))
            let proj = SpaceMath.perspective(fovYDeg: fovYDeg, aspect: Double(vw) / Double(h))
            let view = SpaceMath.view(head: head, eyeX: eyeX)
            enc.setRenderPipelineState(panelPipeline)
            enc.setFragmentSamplerState(sampler, index: 0)
            for (placement, texture) in panels {
                var u = PanelUniforms(
                    mvp: proj * view * placement.modelMatrix,
                    tint: SIMD4(0.12, 0.14, 0.19, 1), // Pocket XR's GLASS_RAISED, a placeholder until the first frame
                    hasTexture: texture == nil ? 0 : 1
                )
                enc.setVertexBytes(&u, length: MemoryLayout<PanelUniforms>.stride, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<PanelUniforms>.stride, index: 0)
                if let texture { enc.setFragmentTexture(texture, index: 0) }
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.setRenderPipelineState(fadePipeline)
            var f = FadeUniforms(size: SIMD2(Float(vw), Float(h)), edges: SIMD4(fadeL, fadeR, 48, 48))
            enc.setFragmentBytes(&f, length: MemoryLayout<FadeUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PanelUniforms { float4x4 mvp; float4 tint; float hasTexture; float3 pad; };
    struct PanelOut { float4 position [[position]]; float2 uv; };

    // A unit quad, -0.5...0.5, as a triangle strip; the picture's top left is uv (0, 0).
    vertex PanelOut panelVertex(uint vid [[vertex_id]], constant PanelUniforms &u [[buffer(0)]]) {
        float2 corners[4] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5), float2(0.5, 0.5) };
        float2 c = corners[vid];
        PanelOut o;
        o.position = u.mvp * float4(c, 0.0, 1.0);
        o.uv = float2(c.x + 0.5, 0.5 - c.y);
        return o;
    }

    fragment float4 panelFragment(PanelOut in [[stage_in]], constant PanelUniforms &u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        if (u.hasTexture < 0.5) { return u.tint; }
        return float4(tex.sample(s, in.uv).rgb, 1.0);
    }

    struct FadeUniforms { float2 size; float2 pad; float4 edges; };
    struct FadeOut { float4 position [[position]]; float2 uv; };

    vertex FadeOut fadeVertex(uint vid [[vertex_id]]) {
        float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        FadeOut o;
        o.position = float4(corners[vid], 0.0, 1.0);
        o.uv = float2((corners[vid].x + 1) * 0.5, (1 - corners[vid].y) * 0.5);
        return o;
    }

    // Black, more opaque toward each edge of the eye's picture (Pocket XR's EdgeFade "Soft").
    fragment float4 fadeFragment(FadeOut in [[stage_in]], constant FadeUniforms &f [[buffer(0)]]) {
        float2 p = in.uv * f.size;
        float a = 0.0;
        a = max(a, 1.0 - saturate(p.x / f.edges.x));
        a = max(a, 1.0 - saturate((f.size.x - p.x) / f.edges.y));
        a = max(a, 1.0 - saturate(p.y / f.edges.z));
        a = max(a, 1.0 - saturate((f.size.y - p.y) / f.edges.w));
        return float4(0.0, 0.0, 0.0, a);
    }
    """
}
