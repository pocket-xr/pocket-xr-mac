import Foundation

/// The "Glasses report": what the Mac and Pocket XR know about the glasses now, as plain text a tester can paste into
/// a GitHub issue. After Pocket XR's GlassesReport on Android.
///
/// Nothing personal goes in: no serial numbers, no user names, and no network address other than the glasses' own
/// link (169.254.x.x). USB devices that are not glasses are listed by their ids and interface classes only, as their
/// names can carry a person's name ("Sam's iPhone"). Every line handed in is cleaned again ([scrub]) before it is
/// written.
public enum GlassesReport {
    /// A plain-text report a tester can send: the glasses found, every USB device's ids and interface classes, the
    /// network links, the settings state read, the Mac's displays (passed in as lines), app version and macOS version
    /// (passed in). No serial numbers, no user names, no addresses other than 169.254.x.x.
    public static func text(appVersion: String, system: String, glasses: Glasses?, usb: [UsbDeviceInfo], links: [String],
                            displays: [String], state: SettingsControl.State?, trackingLine: String) -> String {
        var out = [String]()
        out.append("Pocket XR for Mac glasses report")
        out.append("Pocket XR for Mac \(scrub(appVersion)), \(scrub(system))")
        out.append("")
        out.append(contentsOf: modelLines(glasses))
        out.append("")
        out.append("Displays:")
        if displays.isEmpty { out.append("- none listed") }
        for d in displays { out.append("- \(scrub(d))") }
        out.append("")
        out.append("USB devices (every one the Mac lists; names only for glasses):")
        if usb.isEmpty { out.append("- none") }
        for u in usb { out.append(usbLine(u)) }
        out.append("")
        out.append("The glasses' network links:")
        if links.isEmpty { out.append("- none (no interface with a 169.254.x.x address)") }
        for l in links { out.append("- \(scrub(l))") }
        out.append("")
        out.append("What Pocket XR read:")
        out.append("- Head tracking: \(scrub(trackingLine))")
        out.append(contentsOf: stateLines(state, glasses: glasses))
        return out.joined(separator: "\n") + "\n"
    }

    static func modelLines(_ glasses: Glasses?) -> [String] {
        guard let g = glasses else { return ["Model: no glasses found on USB"] }
        var out = [String]()
        out.append("Model: \(scrub(g.name)) (\(g.family.rawValue) family), USB \(hex4(g.vendor)):\(hex4(g.product))")
        let tracking: String
        if g.networkImu {
            tracking = "the glasses' USB network (TCP 169.254.2.1:52998)"
        } else if g.family == .air && g.hidImu {
            tracking = "USB HID, the Air family's stream on interface \(AirImuProtocol.imuInterface(g.product)) (untested on a Mac)"
        } else if g.family == .viture {
            tracking = "USB HID, VITURE's own protocol (experimental, untested on a Mac)"
        } else {
            tracking = "not known for this model: the screens are shown flat"
        }
        out.append("Head tracking link: \(tracking)")
        out.append("Head axes: \(g.axes == .one ? "x right, y down, z front" : "x right, y up, z back")")
        out.append("Control link (settings): \(g.controlLink ? "yes, TCP 169.254.2.1:52999" : "no")")
        if g.steadyCapable {
            let kind: String = g.sixDofCapable ? (g.appAnchor ? "in 6DoF (Spatial Anchor)" : "in 6DoF (the user turns 6DoF on in the glasses' menu)") : "in 3DoF"
            out.append("Steady mode: offered, \(kind)")
        } else {
            out.append("Steady mode: not offered on this model")
        }
        if g.knownOne {
            out.append(g.eye ? "XREAL Eye: seen (a camera on the glasses' USB), so Steady mode in 6DoF is offered"
                             : "XREAL Eye: not seen (no camera on the glasses' USB), so Steady mode in 6DoF is not offered")
        }
        if g.family != .aura {
            out.append("Note: only the XREAL Aura has been run with Pocket XR on a Mac; this model is untested here.")
        }
        return out
    }

    static func usbLine(_ u: UsbDeviceInfo) -> String {
        let maker: String? = vendorName(u.vendor)
        let classes: String = u.interfaceClasses.isEmpty ? "no interfaces listed" : u.interfaceClasses.map { classLabel($0) }.joined(separator: ", ")
        var line = "- \(hex4(u.vendor)):\(hex4(u.product))"
        if let m = maker {
            // Only glasses are named: other devices' names can hold a person's name.
            line += " \"\(scrub(u.name))\": \(classes) [\(m) glasses]"
            line += "; head tracking link: \(transport(u))"
        } else {
            line += ": \(classes)"
        }
        return line
    }

    static func stateLines(_ state: SettingsControl.State?, glasses: Glasses?) -> [String] {
        guard let s = state else {
            let why: String = (glasses?.controlLink ?? false) ? "not read yet" : "these glasses have none"
            return ["- Control link: \(why)"]
        }
        var out = [String]()
        out.append("- Control link: \(s.link ? "open" : "not open")")
        out.append("- 2D / 3D state: \(flagWords(s.stereo, on: "3D side by side (1)", off: "2D (0)"))")
        out.append("- Spatial Anchor: \(flagWords(s.anchor, on: "on (1)", off: "off (0)"))")
        out.append("- Ultrawide: \(flagWords(s.ultrawide, on: "on (1)", off: "off (0)"))")
        let size: String = s.sizeFactor.map { String(format: "%.2f", $0) } ?? "not read"
        let top: String = s.sizeMax.map { String(format: "%.2f", $0) } ?? "not read"
        out.append("- Screen size: \(size) (largest \(top))")
        let space: String = s.spaceFollow.map { $0 ? "follow" : "hover" } ?? "not read"
        out.append("- Space mode: \(space)")
        out.append("- Steady mode: \(s.steady ? "on" : "off")\(s.busy ? " (settings changing now)" : "")")
        if let note = s.steadyNote { out.append("- To do in the glasses' menu: \(note)") }
        return out
    }

    static func flagWords(_ v: Int?, on: String, off: String) -> String {
        guard let v = v else { return "not read" }
        if v == 1 { return on }
        if v == 0 { return off }
        return "\(v)"
    }

    static func hex4(_ v: Int) -> String { String(format: "%04X", v) }

    /// The glasses makers Pocket XR names (Pocket XR's GlassesVendors).
    static func vendorName(_ vendor: Int) -> String? {
        if vendor == Glasses.xreal { return "XREAL" }
        if vendor == Glasses.viture { return "VITURE" }
        return nil
    }

    /// A USB interface class in words (Pocket XR's UsbInterfaceInfo.label).
    static func classLabel(_ cls: Int) -> String {
        switch cls {
        case 0x01: return "audio"
        case 0x02: return "CDC (network)"
        case 0x03: return "HID"
        case 0x08: return "mass storage"
        case 0x0A: return "CDC data"
        case 0x0E: return "video"
        case 0xFF: return "vendor specific"
        default: return "class \(cls)"
        }
    }

    /// How a glasses maker's USB device carries head tracking (Pocket XR's HeadImuTransport.choose).
    static func transport(_ u: UsbDeviceInfo) -> String {
        if u.vendor == Glasses.viture { return "USB HID, VITURE's own protocol (experimental)" }
        if u.vendor != Glasses.xreal { return "not known from the USB device" }
        if Glasses.aura.contains(u.product) || Glasses.oneFamily[u.product] != nil || u.interfaceClasses.contains(0x02) {
            return "USB network (NCM / ECM), the One family's link"
        }
        if Glasses.airFamily.contains(u.product) || u.interfaceClasses.contains(0x03) {
            return "USB HID, like XREAL's Air family"
        }
        return "not known from the USB device"
    }

    // MARK: cleaning

    /// [text] with anything personal taken out: IPv4 addresses other than 169.254.x.x, hardware (MAC) addresses, email
    /// addresses, the user's name in a home folder path, and anything that names itself a serial number.
    public static func scrub(_ text: String) -> String {
        var t = text
        t = replace(t, #"(?i)\b(serial(?:\s*(?:number|no\.?))?\s*[:=#]?\s*)[A-Za-z0-9_-]{4,}"#, "$1[removed]")
        t = replace(t, #"\b[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}\b"#, "[hardware address removed]")
        t = replace(t, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email removed]")
        t = replace(t, #"(?<![0-9.])(?!169\.254\.)[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(?![0-9.])"#, "[address removed]")
        t = replace(t, #"/Users/[^/\s"]+"#, "/Users/[name]")
        return t
    }

    private static func replace(_ text: String, _ pattern: String, _ with: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: with)
    }
}
