import Metal
import PocketXRCore
import QuartzCore
import simd

/// How one frame is to look, from the settings.
struct RenderOptions {
    /// Each eye's vertical field of view, degrees.
    var fovYDeg = 38.0
    /// The eyes' distance apart, metres.
    var ipd = 0.063
    /// The screens' brightness, 0.3 to 1.
    var brightness = 1.0
    /// The focused screen's outline, 0 off to 1, and its colour.
    var glow = 1.0
    var glowColor = Look.accent
    /// Which screen is focused (the one the pointer is on), nil for none.
    var focused: Int?
    var edgeFade = EdgeFade.soft
    /// One picture across the whole display even when it is 3840x1080: Steady mode, where the glasses show that
    /// picture as one wide flat canvas (Ultrawide), not as a left and a right eye.
    var mono = false
}

/// Draws the Space on the glasses: each screen a textured panel (flat or bent round the head), seen from the head's
/// pose, once per eye in 3D side by side (each half of a 3840x1080 picture), else once. Corners are rounded and the
/// focused screen carries a rim of light. Then Pocket XR's edge fade, so panels end in black (the glasses show black
/// as see-through) rather than at a hard line.
final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let panelPipeline: MTLRenderPipelineState
    private let fadePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    /// Each placement's mesh, made once and kept until the placement changes.
    private var meshes = [MeshKey: Mesh]()

    private struct MeshKey: Hashable {
        var yaw: Double, pitch: Double, width: Double, aspect: Double, distance: Double, curve: Double
        init(_ p: PanelPlacement) {
            yaw = p.yawDeg; pitch = p.pitchDeg; width = p.widthDeg; aspect = p.aspect; distance = p.distance; curve = p.curve
        }
    }

    private struct Mesh {
        var buffer: MTLBuffer
        var count: Int
    }

    private struct PanelUniforms {
        var mvp: simd_float4x4
        var tint: SIMD4<Float> // shown where there is no picture yet
        var glow: SIMD4<Float> // the rim's colour, alpha its strength
        var size: SIMD2<Float> // the panel's size in its own pixels, for the corners and the rim
        var hasTexture: Float
        var brightness: Float
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
            // Corners are cut with alpha, over the black behind.
            p.colorAttachments[0].isBlendingEnabled = true
            p.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            p.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            p.colorAttachments[0].sourceAlphaBlendFactor = .one
            p.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
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

    /// The placement's mesh as a buffer of x, y, z, u, v per vertex (a triangle strip in head-centred space).
    private func mesh(for placement: PanelPlacement) -> Mesh? {
        let key = MeshKey(placement)
        if let m = meshes[key] { return m }
        // A change of layout leaves the old meshes unused; they are few, but not kept for ever.
        if meshes.count > 24 { meshes.removeAll() }
        let vertices: [PanelVertex] = placement.mesh(columns: placement.curve > 0 ? 64 : 1)
        var floats = [Float]()
        floats.reserveCapacity(vertices.count * 5)
        for v in vertices {
            floats.append(v.position.x)
            floats.append(v.position.y)
            floats.append(v.position.z)
            floats.append(v.uv.x)
            floats.append(v.uv.y)
        }
        guard !floats.isEmpty,
              let buffer = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
        else { return nil }
        let m = Mesh(buffer: buffer, count: vertices.count)
        meshes[key] = m
        return m
    }

    /// One frame into [drawable]: [panels] seen from [head].
    func draw(drawable: CAMetalDrawable, head: Quat, panels: [(PanelPlacement, MTLTexture?)], options: RenderOptions) {
        let w = drawable.texture.width, h = drawable.texture.height
        let sbs = !options.mono && GlassesOptics.isSideBySide(width: w, height: h)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let fade = options.edgeFade.widths
        // Each eye: its offset in metres (right positive), its viewport x and width, and which side is the outer one.
        let eyes: [(Double, Int, Int, Bool, Bool)] = sbs
            ? [(-options.ipd / 2, 0, w / 2, true, false), (options.ipd / 2, w / 2, w / 2, false, true)]
            : [(0, 0, w, true, true)]
        for (eyeX, vx, vw, leftOuter, rightOuter) in eyes {
            enc.setViewport(MTLViewport(originX: Double(vx), originY: 0, width: Double(vw), height: Double(h), znear: 0, zfar: 1))
            let proj = SpaceMath.perspective(fovYDeg: options.fovYDeg, aspect: Double(vw) / Double(h))
            let view = SpaceMath.view(head: head, eyeX: eyeX)
            let vp = proj * view
            enc.setRenderPipelineState(panelPipeline)
            enc.setFragmentSamplerState(sampler, index: 0)
            for (index, (placement, texture)) in panels.enumerated() {
                guard let mesh = mesh(for: placement) else { continue }
                let lit = options.focused == index && options.glow > 0 && panels.count > 1
                let g = options.glowColor
                // The panel's own pixels: 1080 high, so the corner and the rim are the same size on every screen.
                let size = SIMD2<Float>(Float(1080 * placement.aspect), 1080)
                var u = PanelUniforms(
                    mvp: vp,
                    tint: SIMD4(0.12, 0.14, 0.19, 1), // Pocket XR's raised glass, a placeholder until the first frame
                    glow: SIMD4(Float(g.r), Float(g.g), Float(g.b), lit ? Float(options.glow) : 0),
                    size: size,
                    hasTexture: texture == nil ? 0 : 1,
                    brightness: Float(options.brightness)
                )
                enc.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<PanelUniforms>.stride, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<PanelUniforms>.stride, index: 1)
                if let texture { enc.setFragmentTexture(texture, index: 0) }
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: mesh.count)
            }
            if options.edgeFade != .off {
                // The widths are for a 1920 wide eye.
                let k = Float(vw) / 1920
                let l = Float(leftOuter ? fade.outer : fade.inner) * k
                let r = Float(rightOuter ? fade.outer : fade.inner) * k
                let v = Float(fade.vertical) * k
                enc.setRenderPipelineState(fadePipeline)
                var f = FadeUniforms(size: SIMD2(Float(vw), Float(h)), edges: SIMD4(l, r, v, v))
                enc.setFragmentBytes(&f, length: MemoryLayout<FadeUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PanelVertexIn { packed_float3 position; packed_float2 uv; };
    struct PanelUniforms { float4x4 mvp; float4 tint; float4 glow; float2 size; float hasTexture; float brightness; };
    struct PanelOut { float4 position [[position]]; float2 uv; };

    // The mesh is already in head-centred space; the picture's top left is uv (0, 0).
    vertex PanelOut panelVertex(uint vid [[vertex_id]], const device PanelVertexIn *vertices [[buffer(0)]],
                                constant PanelUniforms &u [[buffer(1)]]) {
        PanelOut o;
        o.position = u.mvp * float4(float3(vertices[vid].position), 1.0);
        o.uv = float2(vertices[vid].uv);
        return o;
    }

    // Distance in the panel's pixels from the inside of a rounded rectangle's edge: negative inside.
    static float roundedBox(float2 p, float2 halfSize, float radius) {
        float2 q = abs(p) - halfSize + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }

    fragment float4 panelFragment(PanelOut in [[stage_in]], constant PanelUniforms &u [[buffer(1)]],
                                  texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float2 p = (in.uv - 0.5) * u.size;
        float d = roundedBox(p, u.size * 0.5, 22.0);
        // Smooth over about a pixel and a half of the panel, whatever its size on the display.
        float edge = max(fwidth(d), 0.75);
        float alpha = 1.0 - smoothstep(-edge, edge, d);
        float3 colour = u.hasTexture < 0.5 ? u.tint.rgb : tex.sample(s, in.uv).rgb * u.brightness;
        // The focused screen: a thin rim of light at the edge, and a soft fall of it inward.
        float inside = max(-d, 0.0);
        float rim = (1.0 - smoothstep(2.0, 5.0, inside)) * 0.9 + exp(-inside / 26.0) * 0.28;
        colour = mix(colour, u.glow.rgb, saturate(rim * u.glow.a));
        return float4(colour, alpha);
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

    // Black, more opaque toward each edge of the eye's picture (Pocket XR's edge fade).
    fragment float4 fadeFragment(FadeOut in [[stage_in]], constant FadeUniforms &f [[buffer(0)]]) {
        float2 p = in.uv * f.size;
        float a = 0.0;
        a = max(a, 1.0 - saturate(p.x / max(f.edges.x, 0.001)));
        a = max(a, 1.0 - saturate((f.size.x - p.x) / max(f.edges.y, 0.001)));
        a = max(a, 1.0 - saturate(p.y / max(f.edges.z, 0.001)));
        a = max(a, 1.0 - saturate((f.size.y - p.y) / max(f.edges.w, 0.001)));
        return float4(0.0, 0.0, 0.0, a);
    }
    """
}
