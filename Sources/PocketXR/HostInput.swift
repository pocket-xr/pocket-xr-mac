import AppKit
import CoreGraphics
import PocketXRCore

/// The phone's mouse, wheel, keys and text, from the control stream's input messages (moonlight-common-c's Input.h:
/// a big-endian size, a little-endian type, then the packet), made into Mac input with CGEvent, as Sunshine's macOS
/// input does (GPLv3). Positions land on the streamed display. macOS lets this through only with Pocket XR allowed in
/// System Settings, Privacy & Security, Accessibility.
final class HostInput: @unchecked Sendable {
    private static let keyDown: UInt32 = 0x03, keyUp: UInt32 = 0x04, absMove: UInt32 = 0x05, relMove: UInt32 = 0x07,
                       buttonDown: UInt32 = 0x08, buttonUp: UInt32 = 0x09, scroll: UInt32 = 0x0A, text: UInt32 = 0x17,
                       hScroll: UInt32 = 0x55000001

    /// Where the streamed display is, in global points (top-left origin, as CGEvent takes them).
    var area = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttons: Set<CGMouseButton> = []
    private var flags: CGEventFlags = []
    private var lastClick: (button: CGMouseButton, at: Date, point: CGPoint, count: Int)?
    private(set) var sent = 0
    private var logged = 0
    private var warned = false

    /// One control message's input payload: input packets one after another.
    func handle(_ data: UnsafeRawBufferPointer) {
        let b = data.bindMemory(to: UInt8.self)
        var at = 0
        while b.count - at >= 8 {
            var size = 0
            for i in 0..<4 { size = size << 8 | Int(b[at + i]) }
            guard size >= 4, at + 4 + size <= b.count else { return }
            var type: UInt32 = 0
            for i in 0..<4 { type |= UInt32(b[at + 4 + i]) << (8 * UInt32(i)) }
            one(type, Array(b[(at + 8)..<(at + 4 + size)]))
            at += 4 + size
        }
    }

    private static func be16(_ p: [UInt8], _ i: Int) -> Int { Int(Int16(bitPattern: UInt16(p[i]) << 8 | UInt16(p[i + 1]))) }

    private func one(_ type: UInt32, _ p: [UInt8]) {
        // Without Accessibility nothing is posted (macOS would drop it, and may ask again and again).
        guard HostPermissions.inputAllowed else {
            if !warned {
                warned = true
                plog("host: input: Pocket XR is not allowed to control this Mac (System Settings, Privacy & Security, Accessibility): the phone's mouse and keys are not let through")
                HostPermissions.show(because: "Your phone's mouse and keys can't reach this Mac yet.")
            }
            return
        }
        switch type {
        case Self.absMove where p.count >= 10:
            let x = Self.be16(p, 0), y = Self.be16(p, 2)
            let w = max(1, Self.be16(p, 6) + 1), h = max(1, Self.be16(p, 8) + 1)
            let a = area
            moveTo(CGPoint(x: a.minX + CGFloat(x) * (a.width - 1) / CGFloat(max(1, w - 1)),
                           y: a.minY + CGFloat(y) * (a.height - 1) / CGFloat(max(1, h - 1))))
        case Self.relMove where p.count >= 4:
            let now = CGEvent(source: nil)?.location ?? CGPoint(x: area.midX, y: area.midY)
            let inside = area.contains(now)
            var x = (inside ? now.x : area.midX) + CGFloat(Self.be16(p, 0))
            var y = (inside ? now.y : area.midY) + CGFloat(Self.be16(p, 2))
            x = min(max(x, area.minX), area.maxX - 1)
            y = min(max(y, area.minY), area.maxY - 1)
            moveTo(CGPoint(x: x, y: y))
        case Self.buttonDown where p.count >= 1, Self.buttonUp where p.count >= 1:
            button(Int(p[0]), down: type == Self.buttonDown)
        case Self.scroll where p.count >= 2:
            scrollBy(vertical: Self.be16(p, 0), horizontal: 0)
        case Self.hScroll where p.count >= 2:
            scrollBy(vertical: 0, horizontal: Self.be16(p, 0))
        case Self.keyDown where p.count >= 4, Self.keyUp where p.count >= 4:
            let vk = Int(p[1]) | Int(p[2]) << 8
            key(vk & 0xFF, down: type == Self.keyDown, modifiers: p[3])
        case Self.text where !p.isEmpty:
            typeText(String(decoding: p, as: UTF8.self))
        default:
            break
        }
    }

    /// The pointer to the middle of the streamed display (a stream starting).
    func centre() { moveTo(CGPoint(x: area.midX, y: area.midY)) }

    private func post(_ e: CGEvent?) {
        guard let e else { return }
        e.post(tap: .cghidEventTap)
        sent += 1
    }

    private func moveTo(_ pt: CGPoint) {
        let type: CGEventType, button: CGMouseButton
        if buttons.contains(.left) { type = .leftMouseDragged; button = .left }
        else if buttons.contains(.right) { type = .rightMouseDragged; button = .right }
        else if buttons.contains(.center) { type = .otherMouseDragged; button = .center }
        else { type = .mouseMoved; button = .left }
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pt, mouseButton: button)
        e?.flags = flags
        post(e)
    }

    private func button(_ b: Int, down: Bool) {
        let button: CGMouseButton
        let type: CGEventType
        switch b {
        case 1: button = .left; type = down ? .leftMouseDown : .leftMouseUp
        case 3: button = .right; type = down ? .rightMouseDown : .rightMouseUp
        case 2: button = .center; type = down ? .otherMouseDown : .otherMouseUp
        case 4, 5: button = .center; type = down ? .otherMouseDown : .otherMouseUp
        default: return
        }
        let at = CGEvent(source: nil)?.location ?? CGPoint(x: area.midX, y: area.midY)
        if down { buttons.insert(button) } else { buttons.remove(button) }
        // Double clicks: macOS counts them only from the click state each event carries.
        var count = 1
        if down {
            if let l = lastClick, l.button == button, Date().timeIntervalSince(l.at) < NSEvent.doubleClickInterval,
               abs(l.point.x - at.x) < 5, abs(l.point.y - at.y) < 5 { count = l.count + 1 }
            lastClick = (button, Date(), at, count)
        } else if let l = lastClick, l.button == button {
            count = l.count
        }
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: button)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        e?.flags = flags
        post(e)
    }

    /// Moonlight's high-resolution wheel: 120 a notch, up and right positive.
    private func scrollBy(vertical: Int, horizontal: Int) {
        let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                        wheel1: Int32(vertical * 40 / 120), wheel2: Int32(-horizontal * 40 / 120), wheel3: 0)
        e?.flags = flags
        post(e)
    }

    /// A Windows virtual key (the phone sends US-layout key codes) as a Mac key, with the phone's modifiers.
    private func key(_ vk: Int, down: Bool, modifiers: UInt8) {
        var f: CGEventFlags = []
        if modifiers & 0x01 != 0 { f.insert(.maskShift) }
        if modifiers & 0x02 != 0 { f.insert(.maskControl) }
        if modifiers & 0x04 != 0 { f.insert(.maskAlternate) }
        if modifiers & 0x08 != 0 { f.insert(.maskCommand) }
        // The modifier keys themselves: held while down.
        let own: CGEventFlags? = switch vk {
        case 0x10, 0xA0, 0xA1: .maskShift
        case 0x11, 0xA2, 0xA3: .maskControl
        case 0x12, 0xA4, 0xA5: .maskAlternate
        case 0x5B, 0x5C: .maskCommand
        default: nil
        }
        if let own { if down { f.insert(own) } else { f.remove(own) } }
        flags = f
        guard let code = Self.keyCodes[vk] else {
            if logged < 5 { logged += 1; plog(String(format: "host: input: no Mac key for Windows key 0x%02x", vk)) }
            return
        }
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        if own != nil {
            e?.type = .flagsChanged
        }
        e?.flags = f
        post(e)
    }

    private func typeText(_ s: String) {
        var units = Array(s.utf16)
        while !units.isEmpty {
            let chunk = Array(units.prefix(20))
            units.removeFirst(chunk.count)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(e)
            }
        }
    }

    /// Windows virtual key codes to Mac key codes (Carbon's kVK_ values), US layout.
    static let keyCodes: [Int: CGKeyCode] = {
        var m: [Int: CGKeyCode] = [
            0x08: 0x33, 0x09: 0x30, 0x0D: 0x24, 0x10: 0x38, 0x11: 0x3B, 0x12: 0x3A, 0x14: 0x39, 0x1B: 0x35, 0x20: 0x31,
            0x21: 0x74, 0x22: 0x79, 0x23: 0x77, 0x24: 0x73, 0x25: 0x7B, 0x26: 0x7E, 0x27: 0x7C, 0x28: 0x7D,
            0x2D: 0x72, 0x2E: 0x75, 0x5B: 0x37, 0x5C: 0x36, 0x5D: 0x6E,
            0x6A: 0x43, 0x6B: 0x45, 0x6D: 0x4E, 0x6E: 0x41, 0x6F: 0x4B, 0x90: 0x47,
            0xA0: 0x38, 0xA1: 0x3C, 0xA2: 0x3B, 0xA3: 0x3E, 0xA4: 0x3A, 0xA5: 0x3D,
            0xAD: 0x4A, 0xAE: 0x49, 0xAF: 0x48,
            0xBA: 0x29, 0xBB: 0x18, 0xBC: 0x2B, 0xBD: 0x1B, 0xBE: 0x2F, 0xBF: 0x2C, 0xC0: 0x32,
            0xDB: 0x21, 0xDC: 0x2A, 0xDD: 0x1E, 0xDE: 0x27, 0xE2: 0x0A,
        ]
        let letters: [CGKeyCode] = [0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                                    0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06]
        for (i, c) in letters.enumerated() { m[0x41 + i] = c }
        let digits: [CGKeyCode] = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        for (i, c) in digits.enumerated() { m[0x30 + i] = c }
        let pad: [CGKeyCode] = [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]
        for (i, c) in pad.enumerated() { m[0x60 + i] = c }
        let fkeys: [CGKeyCode] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
                                  0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
        for (i, c) in fkeys.enumerated() { m[0x70 + i] = c }
        return m
    }()
}

/// This Mac's clipboard as text, for Apollo's clipboard requests (the phone shares its clipboard both ways).
enum HostClipboard {
    static func get() -> String { NSPasteboard.general.string(forType: .string) ?? "" }

    static func set(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }
}

/// The host on the network as Moonlight finds hosts: an mDNS service "_nvstream._tcp" on its HTTP port.
final class HostMdns: NSObject, NetServiceDelegate {
    private var service: NetService?

    func register(name: String, port: Int) {
        DispatchQueue.main.async {
            let s = NetService(domain: "local.", type: "_nvstream._tcp.", name: name, port: Int32(port))
            s.delegate = self
            s.publish()
            self.service = s
        }
    }

    func netServiceDidPublish(_ sender: NetService) {
        plog("host: mDNS: announced as \"\(sender.name)\" (_nvstream._tcp, port \(sender.port))")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        plog("host: mDNS: not announced: \(errorDict)")
    }

    func stop() {
        DispatchQueue.main.async { self.service?.stop(); self.service = nil }
    }
}
