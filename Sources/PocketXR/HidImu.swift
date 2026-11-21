import Foundation
import IOKit
import IOKit.hid
import PocketXRCore

// IOKit's error codes are C macros Swift does not import, so the three this file tells apart are written out here.
private let hidReturnNotPrivileged: IOReturn = Int32(bitPattern: UInt32(0xE00002C1))
private let hidReturnExclusiveAccess: IOReturn = Int32(bitPattern: UInt32(0xE00002C5))
private let hidReturnNotPermitted: IOReturn = Int32(bitPattern: UInt32(0xE00002E2))

/// One HID device (on macOS each USB HID interface of the glasses is its own IOHIDDevice) as a candidate for the
/// motion stream.
private struct HidCandidate {
    let device: IOHIDDevice
    let vendor: Int
    let product: Int
    let name: String
    /// The USB interface number, from the device's parent in the registry; nil when it is not exposed.
    let interface: Int?
    let usagePage: Int
    let usage: Int
    let maxInput: Int
    let maxOutput: Int

    var line: String {
        let intf: String = interface.map { "interface \($0)" } ?? "interface not known"
        return String(format: "%04X:%04X \"%@\" %@, usage page 0x%04X usage 0x%02X, reports in %d B out %d B",
                      vendor, product, name, intf, usagePage, usage, maxInput, maxOutput)
    }
}

/// Head tracking over USB HID: the XREAL Air family and VITURE glasses, with IOHIDManager. After Pocket XR's
/// AirImuLink and VitureImuLink on Android and the Deck's hidimu.py. UNTESTED: the project has no Air or VITURE
/// glasses, and no part of this has run on a Mac.
///
/// Samples come out as the network stream's do, so HeadFusion takes them unchanged: gyro in rad/s, accelerometer in
/// m/s², time in ns. Axes: the Air's reports are turned into head axes here (x right, y up, z back, HeadFusion's
/// `.aura`); VITURE's are passed on as the sensor sends them, which Pocket XR takes as `.one` on the Beast and
/// `.aura` on other models. `glasses.axes` already says exactly that, and [axes(for:)] repeats it.
///
/// Which HID device: the Air's IMU is USB interface 3 (2 on the Air 2 Ultra). IOHIDDevice has no interface number of
/// its own, so it is read from the device's parent in the IORegistry (the IOUSBHostInterface's "bInterfaceNumber").
/// If macOS exposes that number for none of the glasses' HID devices, the fallback is the devices with a 64 byte
/// input report, vendor defined usage page first, tried one at a time. VITURE: the Beast's interface 5 first, then
/// each other HID device of the glasses in turn, as the Deck does. Every candidate seen is logged, so a tester's log
/// shows what the Mac listed.
///
/// What is written to the glasses: only the Air's stream command (0x19, start or stop) and VITURE's raw stream
/// command (0x0301, start or stop), exactly as AirImuProtocol and VitureImuProtocol build them. Nothing else.
///
/// macOS may want Input Monitoring permission (System Settings, Privacy & Security) before it lets an app open some
/// HID devices; a refused open is logged in words.
///
/// Everything after start() runs on the reader's own thread and run loop, the report callback included, so
/// [onSample] is called on that thread. Call stop() when done: the thread keeps the reader alive until then.
final class HidImuReader: @unchecked Sendable {
    private let glasses: Glasses
    private let onSample: (ImuSample) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var _connectedVia: String?
    private var _status = "not started"

    // The open device's state. Touched on the reader's thread only.
    private var draining = false
    private var removed = false
    private var sessionSamples = 0
    private var sessionOther = 0
    private var lastSampleAt = Date.distantPast
    private var airClock = AirTimestamp()
    private var vitureClock = VitureClock()
    private var loggedCandidates = ""

    /// Samples read since start().
    private(set) var samples = 0
    private var _readCount = 0
    private var _clockWords = "timestamps: unit not decided yet"

    /// Samples read since start(), as the reader's thread last published them (4 times a second).
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return _readCount }

    /// The time stamps' unit in words ("timestamps: ns"), as last published.
    var clockWords: String { lock.lock(); defer { lock.unlock() }; return _clockWords }

    /// Publishes the count and the unit for other threads (on the reader's thread).
    private func publish() {
        let words = clockLine()
        lock.lock(); _readCount = samples; _clockWords = words; lock.unlock()
    }

    /// "USB HID (XREAL Air 2)" once reports arrive, else nil.
    var connectedVia: String? { lock.lock(); defer { lock.unlock() }; return _connectedVia }

    /// Where the stream is, in words, for the glasses report: above all why no reports come ("Input Monitoring not
    /// allowed", "interface 3 not among the glasses' HID devices", "start sent 3 times, no motion reports").
    var status: String { lock.lock(); defer { lock.unlock() }; return _status }

    private func setStatus(_ s: String) {
        lock.lock(); let changed = _status != s; _status = s; lock.unlock()
        if changed { plog("hid imu: status: \(s)") }
    }

    /// macOS's Input Monitoring for this app, in words (IOHIDCheckAccess, ListenEvent).
    static func inputMonitoring() -> String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "allowed"
        case kIOHIDAccessTypeDenied: return "not allowed"
        default: return "not asked yet"
        }
    }

    /// The axes HeadFusion needs for this reader's samples: the same as `glasses.axes` (`.aura` for the Air family,
    /// whose reports are turned into head axes here, and for VITURE models other than the Beast; `.one` for the Beast).
    static func axes(for glasses: Glasses) -> HeadFusion.Axes { glasses.axes }

    init(glasses: Glasses, onSample: @escaping (ImuSample) -> Void) {
        self.glasses = glasses
        self.onSample = onSample
    }

    /// Opens the device's IMU interface, sends the start command and reads, on its own thread. Does nothing for
    /// glasses without a HID stream ([Glasses.hidImu]).
    func start() {
        guard glasses.hidImu else {
            plog("hid imu: \(glasses.name) has no HID motion stream Pocket XR knows; not started")
            return
        }
        lock.lock()
        let already = started
        started = true
        lock.unlock()
        if already { return }
        // A strong reference on purpose: the report callback holds an unretained pointer to the reader, so the reader
        // must live until the thread has closed the device.
        let t = Thread { self.run() }
        t.name = "Pocket XR HID head tracking"
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// Sends stop and closes. The reader's thread does both within about a quarter of a second.
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func setConnected(_ via: String?) {
        lock.lock(); _connectedVia = via; lock.unlock()
    }

    // MARK: the thread

    private func run() {
        let manager: IOHIDManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        var match: [String: Any] = [kIOHIDVendorIDKey as String: glasses.vendor]
        if glasses.family == .air { match[kIOHIDProductIDKey as String] = glasses.product }
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        // The manager is never opened (that would open every HID device of the glasses): it only lists them, and the
        // one device chosen is opened by itself.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        plog("hid imu: looking for \(glasses.name)'s motion stream over USB HID (untested on a Mac); Input Monitoring \(Self.inputMonitoring())")
        setStatus("looking for the glasses' HID devices")
        while !isStopped {
            spin(0.2)
            let found: [HidCandidate] = candidates(manager)
            logCandidates(found)
            if glasses.family == .air, found.contains(where: { $0.interface != nil }) {
                let streamed = tryAir(found)
                wait(streamed ? 1.0 : (AirImuProtocol.isXbx(glasses.product) ? 10.0 : 3.0))
                continue
            }
            let order: [HidCandidate] = ordered(found)
            if order.isEmpty {
                if found.isEmpty {
                    setStatus("macOS lists no HID device of the glasses")
                } else if glasses.family == .air {
                    let have = found.compactMap(\.interface).map(String.init).joined(separator: ", ")
                    setStatus("interface \(AirImuProtocol.imuInterface(glasses.product)) is not among the glasses' HID devices (macOS lists interfaces \(have.isEmpty ? "without numbers" : have))")
                }
                wait(2.0)
                continue
            }
            var streamed = false
            for c in order {
                if isStopped { break }
                if session(c) {
                    streamed = true
                    break
                }
            }
            wait(streamed ? 1.0 : 3.0)
        }
        stopMcu()
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        plog("hid imu: stopped")
    }

    /// Lets the run loop deliver reports for [seconds].
    private func spin(_ seconds: Double) {
        let result: CFRunLoopRunResult = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, seconds, false)
        // A run loop with nothing scheduled comes back at once: the time is slept instead, so no loop here spins.
        if result == CFRunLoopRunResult.finished { Thread.sleep(forTimeInterval: seconds) }
    }

    /// Waits [seconds], in short steps so stop() is seen.
    private func wait(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while !isStopped && Date() < end { spin(0.2) }
    }

    // MARK: finding the device

    private func candidates(_ manager: IOHIDManager) -> [HidCandidate] {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        var out = [HidCandidate]()
        for d in devices {
            let vendor: Int = Self.number(d, kIOHIDVendorIDKey) ?? 0
            let product: Int = Self.number(d, kIOHIDProductIDKey) ?? 0
            if vendor != glasses.vendor { continue }
            if glasses.family == .viture && product == Glasses.vitureMicrophone { continue }
            let name: String = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? ""
            out.append(HidCandidate(
                device: d, vendor: vendor, product: product, name: name,
                interface: Self.interfaceNumber(d),
                usagePage: Self.number(d, kIOHIDPrimaryUsagePageKey) ?? 0,
                usage: Self.number(d, kIOHIDPrimaryUsageKey) ?? 0,
                maxInput: Self.number(d, kIOHIDMaxInputReportSizeKey) ?? 0,
                maxOutput: Self.number(d, kIOHIDMaxOutputReportSizeKey) ?? 0))
        }
        // A fixed order, whatever order the set gives: by interface number, unknown ones last.
        return out.sorted { (a: HidCandidate, b: HidCandidate) -> Bool in
            let ia: Int = a.interface ?? 1000
            let ib: Int = b.interface ?? 1000
            if ia != ib { return ia < ib }
            return a.usagePage > b.usagePage
        }
    }

    private func logCandidates(_ found: [HidCandidate]) {
        let text: String = found.isEmpty ? "none" : found.map { $0.line }.joined(separator: "; ")
        if text == loggedCandidates { return }
        loggedCandidates = text
        plog("hid imu: HID devices of \(glasses.name) the Mac lists: \(text)")
    }

    /// The candidates to try, best first.
    private func ordered(_ found: [HidCandidate]) -> [HidCandidate] {
        if glasses.family == .air {
            let wanted: Int = AirImuProtocol.imuInterface(glasses.product)
            let known: [HidCandidate] = found.filter { $0.interface != nil }
            if !known.isEmpty {
                // Only the IMU's own interface is ever written to; the glasses' other HID interfaces are left alone.
                return known.filter { $0.interface == wanted }
            }
            // No interface numbers at all: the 64 byte report devices, vendor defined usage pages first.
            let sized: [HidCandidate] = found.filter { $0.maxInput >= AirImuProtocol.packetBytes }
            return sized.sorted { (a: HidCandidate, b: HidCandidate) -> Bool in
                let va: Bool = a.usagePage >= 0xFF00
                let vb: Bool = b.usagePage >= 0xFF00
                if va != vb { return va }
                return a.usagePage > b.usagePage
            }
        }
        // VITURE: the Beast's motion sensor is interface 5; other models are tried interface by interface.
        return found.sorted { (a: HidCandidate, b: HidCandidate) -> Bool in
            let fa: Bool = Glasses.isBeastProduct(a.product) && a.interface == VitureImuProtocol.beastImuInterface
            let fb: Bool = Glasses.isBeastProduct(b.product) && b.interface == VitureImuProtocol.beastImuInterface
            if fa != fb { return fa }
            return (a.interface ?? 1000) < (b.interface ?? 1000)
        }
    }

    /// Every HID device of [vendor] (0: all) as a line: ids, name, USB interface, usage, report sizes. Writes nothing
    /// to any device (PocketXR --hid-list, for a tester's report).
    static func list(vendor: Int) -> [String] {
        let manager: IOHIDManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, (vendor == 0 ? [:] : [kIOHIDVendorIDKey as String: vendor]) as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devices.map { d -> HidCandidate in
            HidCandidate(device: d, vendor: number(d, kIOHIDVendorIDKey) ?? 0, product: number(d, kIOHIDProductIDKey) ?? 0,
                         name: (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "",
                         interface: interfaceNumber(d), usagePage: number(d, kIOHIDPrimaryUsagePageKey) ?? 0,
                         usage: number(d, kIOHIDPrimaryUsageKey) ?? 0, maxInput: number(d, kIOHIDMaxInputReportSizeKey) ?? 0,
                         maxOutput: number(d, kIOHIDMaxOutputReportSizeKey) ?? 0)
        }.map(\.line).sorted()
    }

    private static func number(_ device: IOHIDDevice, _ key: String) -> Int? {
        guard let v = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (v as? NSNumber)?.intValue
    }

    /// The USB interface number of [device]: "bInterfaceNumber" of the nearest IOUSBHostInterface above it in the
    /// registry, or nil.
    private static func interfaceNumber(_ device: IOHIDDevice) -> Int? {
        let service: io_service_t = IOHIDDeviceGetService(device)
        if service == 0 { return nil }
        var entry: io_registry_entry_t = service
        var owned = false // the device's own service is not ours to release; the parents fetched here are
        var result: Int?
        for _ in 0..<8 {
            if IOObjectConformsTo(entry, "IOUSBHostInterface") != 0 || IOObjectConformsTo(entry, "IOUSBInterface") != 0 {
                if let v = IORegistryEntryCreateCFProperty(entry, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                    result = (v as? NSNumber)?.intValue
                }
                break
            }
            var parent: io_registry_entry_t = 0
            let kr: kern_return_t = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            if owned { IOObjectRelease(entry) }
            if kr != KERN_SUCCESS || parent == 0 {
                owned = false
                entry = 0
                break
            }
            entry = parent
            owned = true
        }
        if owned && entry != 0 { IOObjectRelease(entry) }
        return result
    }

    // MARK: the Air family: which interface streams

    /// The interface being read, for the log.
    private var currentInterface: Int?
    /// Raw reports logged per interface this try (the first few, in hex).
    private var loggedPerInterface: [Int: Int] = [:]
    private static let loggedReports = 12

    private func noteBytes(_ interface: Int?, _ bytes: [UInt8], _ what: String) {
        let key = interface ?? -1
        let n = loggedPerInterface[key, default: 0]
        guard n < Self.loggedReports else { return }
        loggedPerInterface[key] = n + 1
        plog("hid imu: interface \(interface.map(String.init) ?? "?") \(what) \(AirImuProtocol.hexStart(bytes))")
    }

    /// The Air family's steps (AirImuProtocol.tryOrder): the IMU interface; on the XBX, if it stays silent, the MCU
    /// heartbeat and the IMU interface again, then the other interfaces. True if one streamed (until its stream ended).
    private func tryAir(_ found: [HidCandidate]) -> Bool {
        var byNum = [Int: HidCandidate]()
        for c in found { if let n = c.interface, byNum[n] == nil { byNum[n] = c } }
        loggedPerInterface = [:]
        let steps = AirImuProtocol.tryOrder(product: glasses.product, interfaces: Set(byNum.keys))
        if steps.isEmpty {
            let have = byNum.keys.sorted().map(String.init).joined(separator: ", ")
            setStatus("interface \(AirImuProtocol.imuInterface(glasses.product)) is not among the glasses' HID devices (macOS lists interfaces \(have))")
            return false
        }
        plog("hid imu: trying, in order: \(steps.map { "\($0)" }.joined(separator: ", "))")
        defer { stopMcu() }
        for step in steps {
            if isStopped { return false }
            switch step {
            case .wakeMcu:
                if let c = byNum[AirImuProtocol.xbxMcuInterface] { _ = startMcu(c) }
            case .imuWithMcu(let n):
                guard mcu != nil, let c = byNum[n] else { continue }
                if session(c) { return true }
            case .imu(let n):
                guard let c = byNum[n] else { continue }
                if session(c) { return true }
            }
        }
        if !isStopped {
            setStatus("no interface sent motion reports (tried \(steps.map { "\($0)" }.joined(separator: ", ")))\(AirImuProtocol.isXbx(glasses.product) ? "; trying again in 10 s" : ""); Input Monitoring \(Self.inputMonitoring())")
        }
        return false
    }

    // MARK: the XBX's MCU heartbeat (interface 0)

    private final class Mcu {
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let size: Int
        var timer: CFRunLoopTimer?
        var answered = false
        init(device: IOHIDDevice, size: Int) {
            self.device = device
            self.size = size
            buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            buffer.initialize(repeating: 0, count: size)
        }
    }

    private var mcu: Mcu?

    /// Opens the MCU's interface, sends the handshake (each command waits up to 2 s for any 0xFD frame back, as the
    /// library does) and starts the heartbeat every 100 ms on this thread's run loop. False if it did not take.
    private func startMcu(_ c: HidCandidate) -> Bool {
        stopMcu()
        let device = c.device
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened != kIOReturnSuccess {
            plog("hid imu: MCU interface \(c.interface ?? -1) not open: \(Self.words(opened))")
            return false
        }
        let m = Mcu(device: device, size: max(64, c.maxInput))
        mcu = m
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, m.buffer, CFIndex(m.size), { context, _, _, _, _, report, length in
            guard let context = context, length > 0 else { return }
            let reader = Unmanaged<HidImuReader>.fromOpaque(context).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer<UInt8>(start: UnsafePointer<UInt8>(report), count: Int(length)))
            reader.noteBytes(AirImuProtocol.xbxMcuInterface, bytes, "read")
            if bytes.first == AirImuProtocol.mcuHead { reader.mcu?.answered = true }
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        spin(0.2)
        for step in AirImuProtocol.mcuBootstrap {
            let ok = mcuAsk(m, AirImuProtocol.mcuCommand(step.id, step.data))
            plog(String(format: "hid imu: MCU command 0x%02x on interface %d: %@", step.id, AirImuProtocol.xbxMcuInterface, ok ? "answered" : "no answer"))
            if !ok {
                setStatus(String(format: "the XBX's controller (interface 0) did not answer command 0x%02x", step.id))
                stopMcu()
                return false
            }
        }
        for _ in 0..<2 { _ = mcuAsk(m, AirImuProtocol.mcuHeartbeat(nowNs: DispatchTime.now().uptimeNanoseconds)) }
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.1, 0.1, 0, 0) { [weak self] _ in
            guard let self, let m = self.mcu else { return }
            _ = self.send(m.device, AirImuProtocol.mcuHeartbeat(nowNs: DispatchTime.now().uptimeNanoseconds), what: "heartbeat", quiet: true)
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
        m.timer = timer
        plog("hid imu: MCU heartbeat running on interface \(AirImuProtocol.xbxMcuInterface)")
        return true
    }

    private func mcuAsk(_ m: Mcu, _ frame: [UInt8]) -> Bool {
        m.answered = false
        guard send(m.device, frame, what: "MCU command") else { return false }
        let end = Date().addingTimeInterval(2)
        while !m.answered && Date() < end && !isStopped { spin(0.05) }
        return m.answered
    }

    private func stopMcu() {
        guard let m = mcu else { return }
        mcu = nil
        if let t = m.timer { CFRunLoopTimerInvalidate(t) }
        IOHIDDeviceRegisterInputReportCallback(m.device, m.buffer, CFIndex(m.size), nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(m.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(m.device, IOOptionBits(kIOHIDOptionsTypeNone))
        m.buffer.deinitialize(count: m.size)
        m.buffer.deallocate()
        plog("hid imu: MCU heartbeat stopped")
    }

    // MARK: one open device

    /// Opens [c], starts its stream and reads until the stream ends or stop(). True if samples came.
    private func session(_ c: HidCandidate) -> Bool {
        let device: IOHIDDevice = c.device
        currentInterface = c.interface
        let opened: IOReturn = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened != kIOReturnSuccess {
            plog("hid imu: could not open \(c.line): \(Self.words(opened))")
            if opened == hidReturnNotPermitted || opened == hidReturnNotPrivileged {
                // Puts Pocket XR in the Input Monitoring list (macOS asks once).
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                setStatus("Input Monitoring not allowed: macOS would not open \(c.interface.map { "interface \($0)" } ?? "the device"). Allow Pocket XR in System Settings, Privacy & Security, Input Monitoring, then open it again")
            } else {
                setStatus("could not open \(c.interface.map { "interface \($0)" } ?? "the device"): \(Self.words(opened))")
            }
            return false
        }
        let size: Int = max(AirImuProtocol.packetBytes, c.maxInput)
        let buffer: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        removed = false
        draining = true
        sessionSamples = 0
        sessionOther = 0
        airClock = AirTimestamp()
        vitureClock = VitureClock()
        let context: UnsafeMutableRawPointer = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, CFIndex(size), { context, result, sender, type, reportID, report, length in
            guard let context = context else { return }
            let reader: HidImuReader = Unmanaged<HidImuReader>.fromOpaque(context).takeUnretainedValue()
            let count: Int = Int(length)
            if count <= 0 { return }
            let bytes: [UInt8] = Array(UnsafeBufferPointer<UInt8>(start: UnsafePointer<UInt8>(report), count: count))
            reader.received(bytes)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, result, sender in
            guard let context = context else { return }
            let reader: HidImuReader = Unmanaged<HidImuReader>.fromOpaque(context).takeUnretainedValue()
            reader.removed = true
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        defer {
            // The stop command, then the callbacks off before the device closes and the buffer goes.
            if !removed { _ = send(device, stopCommand(), what: "stop") }
            spin(0.2)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, CFIndex(size), nil, nil)
            IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            buffer.deinitialize(count: size)
            buffer.deallocate()
            setConnected(nil)
        }
        // What is waiting is read first: the Beast takes no new command while an answer of its own is unread.
        spin(0.3)
        draining = false
        if !send(device, startCommand(), what: "start") {
            plog("hid imu: the start command was not accepted by \(c.line)")
            setStatus("the start command was not accepted by \(c.interface.map { "interface \($0)" } ?? "the device"): \(lastSendError)")
            return false
        }
        plog("hid imu: motion stream asked for on \(c.line)")
        setStatus("\(c.interface.map { "interface \($0)" } ?? "the device") open, motion stream asked for; waiting for reports")
        var askedAt = Date()
        var asks = 1
        var announced = false
        while !isStopped && !removed {
            spin(0.25)
            publish()
            if sessionSamples > 0 && !announced {
                announced = true
                let model: String = glasses.family == .air ? (AirImuProtocol.modelName(glasses.product) ?? glasses.name) : glasses.name
                setConnected("USB HID (\(model))")
                setStatus("reports arriving from \(c.interface.map { "interface \($0)" } ?? "the device")\(mcu != nil ? ", with the MCU heartbeat" : "")")
                plog("hid imu: Air samples on \(c.interface.map { "interface \($0)" } ?? "the device")\(mcu != nil ? ", with the MCU heartbeat" : "")")
                plog("hid imu: samples arriving from \(c.line)")
            }
            let quietFor: Double = Date().timeIntervalSince(sessionSamples > 0 ? lastSampleAt : askedAt)
            if quietFor < 2.0 { continue }
            if sessionSamples > 0 {
                plog("hid imu: no samples for 2 s (\(sessionSamples) read, \(clockLine())); starting over")
                return true
            }
            if glasses.family == .air && asks < 3 {
                // The Deck asks an Air again when nothing comes.
                asks += 1
                askedAt = Date()
                plog("hid imu: no reports for 2 s (\(sessionOther) other reports); asking again (\(asks))")
                if !send(device, startCommand(), what: "start") { return false }
                continue
            }
            plog("hid imu: no samples from \(c.line) (\(sessionOther) other reports)")
            setStatus("\(c.interface.map { "interface \($0)" } ?? "the device") open and the start sent \(asks) times (report id \(lastReportId)), but no motion reports came (\(sessionOther) other reports); Input Monitoring \(Self.inputMonitoring())")
            return false
        }
        if removed { plog("hid imu: the glasses were unplugged") }
        return sessionSamples > 0
    }

    private func startCommand() -> [UInt8] {
        glasses.family == .air ? AirImuProtocol.streamCommand(on: true) : VitureImuProtocol.padded(VitureImuProtocol.startRaw())
    }

    private func stopCommand() -> [UInt8] {
        glasses.family == .air ? AirImuProtocol.streamCommand(on: false) : VitureImuProtocol.padded(VitureImuProtocol.stop())
    }

    private var lastSendError = ""
    private var lastReportId = 0

    /// Writes one 64 byte output report. The Air's command goes with its first byte (0xAA) as the report id, as hidapi
    /// sends it on macOS (nrealAirLinuxDriver, which works there): the IMU interface numbers its reports (its own
    /// start 0x01), and a SET_REPORT naming id 0 may be ignored. If macOS refuses that, report id 0. VITURE: id 0.
    private func send(_ device: IOHIDDevice, _ bytes: [UInt8], what: String, quiet: Bool = false) -> Bool {
        func write(_ id: Int) -> IOReturn {
            bytes.withUnsafeBufferPointer { (p: UnsafeBufferPointer<UInt8>) -> IOReturn in
                guard let base = p.baseAddress else { return kIOReturnSuccess }
                return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(id), base, CFIndex(p.count))
            }
        }
        let ids: [Int] = glasses.family == .air && !bytes.isEmpty ? [Int(bytes[0]), 0] : [0]
        var result: IOReturn = kIOReturnSuccess
        for id in ids {
            result = write(id)
            if result == kIOReturnSuccess {
                if !quiet && (id != lastReportId || what == "start") { plog("hid imu: the \(what) written (report id \(id))") }
                lastReportId = id
                return true
            }
            if !quiet { plog("hid imu: the \(what) with report id \(id) was not written: \(Self.words(result))") }
        }
        // The MCU's frames are shorter than a report: padded to 64 if macOS wants a whole one.
        if bytes.count < AirImuProtocol.packetBytes {
            let padded = bytes + [UInt8](repeating: 0, count: AirImuProtocol.packetBytes - bytes.count)
            if send(device, padded, what: what + " (padded)", quiet: quiet) { return true }
        }
        lastSendError = Self.words(result)
        return false
    }

    /// One input report, on the reader's thread.
    private func received(_ bytes: [UInt8]) {
        noteBytes(currentInterface, bytes, draining ? "drained" : "read")
        if draining { return }
        if glasses.family == .air {
            guard var s = AirImuProtocol.parse(bytes) else {
                sessionOther += 1
                return
            }
            s.timestampNs = airClock.toNs(s.timestampNs)
            deliver(s)
        } else {
            guard let raw = VitureImuProtocol.parseReport(bytes) else {
                sessionOther += 1
                return
            }
            let ns: UInt64 = vitureClock.toNs(counter: raw.counter, hostNs: DispatchTime.now().uptimeNanoseconds)
            deliver(VitureImuProtocol.sample(raw, timestampNs: ns))
        }
    }

    private func deliver(_ s: ImuSample) {
        sessionSamples += 1
        samples += 1
        lastSampleAt = Date()
        onSample(s)
    }

    private func clockLine() -> String {
        glasses.family == .air ? airClock.line : vitureClock.line
    }

    private static func words(_ r: IOReturn) -> String {
        let code: String = String(format: "0x%08X", UInt32(bitPattern: r))
        if r == hidReturnNotPermitted || r == hidReturnNotPrivileged {
            return "macOS did not allow it (\(code)). Allow Pocket XR in System Settings, Privacy & Security, Input Monitoring, then open it again"
        }
        if r == hidReturnExclusiveAccess {
            return "another app holds the device (\(code))"
        }
        return "IOKit error \(code)"
    }
}
