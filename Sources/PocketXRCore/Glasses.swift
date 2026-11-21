import Foundation

/// A USB device as the Mac lists it.
public struct UsbDeviceInfo: Equatable, Sendable {
    public var vendor: Int
    public var product: Int
    public var interfaceClasses: [Int]
    public var name: String

    public init(vendor: Int, product: Int, interfaceClasses: [Int] = [], name: String = "") {
        self.vendor = vendor
        self.product = product
        self.interfaceClasses = interfaceClasses
        self.name = name
    }
}

/// Which glasses are plugged in, and what Pocket XR can do with them. The model rules are the Steam Deck's
/// glasses.py, which follows Pocket XR's GlassesProfile, HeadImuTransport and SteadyMode.
public struct Glasses: Equatable, Sendable {
    public enum Family: String, Sendable { case aura, one, air, viture, other }

    public static let xreal = 0x3318
    public static let viture = 0x35CA
    public static let aura: Set<Int> = [0x0439, 0x043A]
    public static let oneFamily: [Int: String] = [
        0x0435: "XREAL One Pro", 0x0436: "XREAL One Pro", 0x0437: "XREAL One", 0x0438: "XREAL One",
        0x043D: "XREAL 1S", 0x043E: "XREAL 1S", 0x0443: "XREAL One Pro+", 0x0444: "XREAL One Pro+",
    ]
    public static let vitureBeast = 0x1211
    /// A second Beast USB id, reported by a tester (November 2026) with the same layout: HID on interface 5.
    public static let vitureBeast1201 = 0x1201
    /// The VITURE Beast's USB product ids.
    public static let beastProducts: Set<Int> = [vitureBeast, vitureBeast1201]

    public static func isBeastProduct(_ product: Int) -> Bool { beastProducts.contains(product) }
    public static let vitureMicrophone = 0x1102
    /// The Air family models whose HID motion stream Pocket XR reads. The XBX A01 and A01+ (XREAL's USB id, the Air's
    /// protocol on HID interface 1, as wheaney's nrealAirLinuxDriver hid_ids.c lists them) were added from a tester's
    /// report (November 2026); untested by the project.
    public static let airImu: [Int: String] = [
        0x0424: "XREAL Air", 0x0428: "XREAL Air 2", 0x0432: "XREAL Air 2 Pro", 0x0426: "XREAL Air 2 Ultra",
        0x0440: "XBX A01", 0x0442: "XBX A01+",
    ]
    public static let airFamily: Set<Int> = [
        0x0423, 0x0424, 0x0425, 0x0426, 0x0427, 0x0428, 0x0431, 0x0432, 0x043F, 0x0440, 0x0441, 0x0442,
    ]

    public var name: String
    public var family: Family
    public var vendor: Int
    public var product: Int
    /// An XREAL Eye (or any XREAL camera) seen beside One-family glasses.
    public var eye = false

    public init(name: String, family: Family, vendor: Int, product: Int, eye: Bool = false) {
        self.name = name
        self.family = family
        self.vendor = vendor
        self.product = product
        self.eye = eye
    }

    /// Head tracking over the glasses' USB network (169.254.2.1:52998): the Aura and the One family.
    public var networkImu: Bool { family == .aura || family == .one }

    /// XREAL's control link on 52999: settings Pocket XR can read and set.
    public var controlLink: Bool { family == .aura || family == .one }

    /// Glasses whose menu settings Pocket XR reads and puts right on every link: the Aura only.
    public var managed: Bool { family == .aura }

    public var isBeast: Bool { family == .viture && Self.isBeastProduct(product) }

    /// The One family and the VITURE Beast send x right, y down, z front; the Aura x right, y up, z back.
    public var axes: HeadFusion.Axes { family == .one || isBeast ? .one : .aura }

    /// Head tracking the Mac app reads without asking: the network stream. The Air family and VITURE (USB HID, [hidImu])
    /// are read only when the app's own setting says so, as they are untested on a Mac.
    public var trackingOnMac: Bool { networkImu }

    /// A One family model Pocket XR knows by its USB product id (not other XREAL glasses merely taken as One family).
    public var knownOne: Bool { family == .one && Self.oneFamily[product] != nil }

    /// Glasses that are offered Steady mode: the Aura and the One series (Pocket XR's SteadyMode.offeredOn). Tested
    /// on the Aura only; on the One series a refusal only ends the change. Other XREAL glasses taken as One family
    /// are left out: their settings are not known.
    public var steadyCapable: Bool { family == .aura || knownOne }

    /// Glasses that can hold Steady mode in 6DoF: the Aura, or the One series with the XREAL Eye (SteadyMode.sixDofOn).
    public var sixDofCapable: Bool { family == .aura || (knownOne && eye) }

    /// Glasses whose 6DoF hold Pocket XR turns on and off itself (Spatial Anchor, 10405): the Aura only. On the One
    /// series with the Eye the user turns 6DoF on in the glasses' own menu (SteadyMode.appAnchor).
    public var appAnchor: Bool { family == .aura }

    /// Head tracking over USB HID: the Air family models whose stream is known (the Air, Air 2, Air 2 Pro, Air 2 Ultra,
    /// XBX A01 and A01+), and VITURE glasses (experimental). The Air family has not been run on a Mac by the project.
    public var hidImu: Bool { (family == .air && Self.airImu[product] != nil) || family == .viture }

    /// Finds the glasses among [devices], in the Deck's order: the Aura, the One family, the Air family, VITURE, then any
    /// other XREAL device with a network interface (taken as One family, as Pocket XR does).
    public static func detect(_ devices: [UsbDeviceInfo]) -> Glasses? {
        let eye = devices.contains { $0.vendor == xreal && $0.interfaceClasses.contains(0x0E) && !aura.contains($0.product) }
        if let d = devices.first(where: { $0.vendor == xreal && aura.contains($0.product) }) {
            return Glasses(name: "XREAL Aura", family: .aura, vendor: d.vendor, product: d.product)
        }
        if let d = devices.first(where: { $0.vendor == xreal && oneFamily[$0.product] != nil }) {
            return Glasses(name: oneFamily[d.product]!, family: .one, vendor: d.vendor, product: d.product, eye: eye)
        }
        if let d = devices.first(where: { $0.vendor == xreal && airFamily.contains($0.product) }) {
            return Glasses(name: airImu[d.product] ?? (d.name.isEmpty ? "XREAL Air" : d.name), family: .air,
                           vendor: d.vendor, product: d.product)
        }
        let vit = devices.filter { $0.vendor == viture && $0.product != vitureMicrophone }
        if let d = vit.first(where: { isBeastProduct($0.product) }) ?? vit.first {
            return Glasses(name: d.name.isEmpty ? "VITURE glasses" : d.name, family: .viture, vendor: d.vendor, product: d.product)
        }
        if let d = devices.first(where: { $0.vendor == xreal && $0.interfaceClasses.contains(0x02) }) {
            return Glasses(name: d.name.isEmpty ? "XREAL glasses" : d.name, family: .one, vendor: d.vendor, product: d.product, eye: eye)
        }
        return nil
    }

    /// The glasses' display among the Mac's screens, by name ("XREAL AURA", "XREAL One", "VITURE ..."), else nil.
    public static func isGlassesScreenName(_ name: String) -> Bool {
        let n = name.uppercased()
        return n.contains("XREAL") || n.contains("NREAL") || n.contains("VITURE") || n.contains("ROKID")
            || n.contains("RAYNEO")
    }

    /// The names macOS gives an Air-family pair's display without the maker's name. The first XREAL Air shows as just
    /// "Air" (a tester's MacBook Air, November 2026: Pocket XR 0.5.1 and 0.5.2 never found it, as the name has no
    /// "XREAL"). "Air 2", "Air 2 Pro" and "Air 2 Ultra" are assumed from the model names; untested.
    public static func isAirScreenName(_ name: String) -> Bool {
        let n = name.uppercased().trimmingCharacters(in: .whitespaces)
        return ["AIR", "AIR 2", "AIR 2 PRO", "AIR 2 ULTRA"].contains(n)
    }

    /// Whether a screen is the glasses' display: a maker's name ([isGlassesScreenName]), or an Air-family name
    /// ([isAirScreenName]) while Air-family glasses are on USB, so a monitor that happens to be called "Air" is not
    /// taken for them otherwise. Never the Mac's built-in screen, and never one of Pocket XR's own floating screens.
    public static func isGlassesScreen(name: String, builtIn: Bool, airOnUsb: Bool) -> Bool {
        if builtIn || name.hasPrefix("Pocket XR") { return false }
        return isGlassesScreenName(name) || (airOnUsb && isAirScreenName(name))
    }
}
