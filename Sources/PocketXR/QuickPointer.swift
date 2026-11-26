import AppKit
import Metal
import PocketXRCore

/// Quick pointer: the pointer drawn by Pocket XR at each frame (see PointerSpot), from where macOS says it is now, with
/// the picture macOS shows for it. Capture leaves its own pointer out while this is on (DisplayCapture.showsCursor).
@MainActor
final class QuickPointer {
    private let device: MTLDevice
    private(set) var texture: MTLTexture?
    private var hotSpot = (x: 0.0, y: 0.0)
    private var size = (width: 0.0, height: 0.0)
    private var pictureKey = 0
    private var lookedAt = 0.0

    init(device: MTLDevice) {
        self.device = device
    }

    /// Where to draw the pointer this frame: which of [screens] (virtual display ids, in panel order) and where on it,
    /// as (u, v, width, height) of the panel. Nil when it is on none of them.
    func spot(screens: [CGDirectDisplayID]) -> (panel: Int, rect: SIMD4<Float>)? {
        guard let at = CGEvent(source: nil)?.location else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        // The pointer's picture changes seldom (arrow, I-beam, hand): looked at ten times a second.
        if texture == nil || now - lookedAt >= 0.1 {
            lookedAt = now
            refreshPicture()
        }
        guard texture != nil else { return nil }
        let bounds = screens.map { id -> (x: Double, y: Double, width: Double, height: Double) in
            let b = CGDisplayBounds(id)
            return (Double(b.origin.x), Double(b.origin.y), Double(b.width), Double(b.height))
        }
        let p = (x: Double(at.x), y: Double(at.y))
        guard let i = PointerSpot.screen(pointer: p, screens: bounds),
              let r = PointerSpot.rect(pointer: p, screen: bounds[i], hotSpot: hotSpot, size: size) else { return nil }
        return (i, SIMD4(Float(r.u), Float(r.v), Float(r.width), Float(r.height)))
    }

    private func refreshPicture() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard image.size.width > 0, image.size.height > 0,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return }
        var hasher = Hasher()
        hasher.combine(bytes)
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        let key = hasher.finalize()
        if key == pictureKey, texture != nil { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        texture = tex
        pictureKey = key
        hotSpot = (Double(cursor.hotSpot.x), Double(cursor.hotSpot.y))
        size = (Double(image.size.width), Double(image.size.height))
    }
}
