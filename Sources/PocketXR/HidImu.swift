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

    /// "USB HID (XREAL Air 2)" once reports arrive, else nil.
    var connectedVia: String? { lock.lock(); defer { lock.unlock() }; return _connectedVia }

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
        plog("hid imu: looking for \(glasses.name)'s motion stream over USB HID (untested on a Mac)")
        while !isStopped {
            spin(0.2)
            let found: [HidCandidate] = candidates(manager)
            logCandidates(found)
            let order: [HidCandidate] = ordered(found)
            if order.isEmpty {
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
            let fa: Bool = a.product == Glasses.vitureBeast && a.interface == VitureImuProtocol.beastImuInterface
            let fb: Bool = b.product == Glasses.vitureBeast && b.interface == VitureImuProtocol.beastImuInterface
            if fa != fb { return fa }
            return (a.interface ?? 1000) < (b.interface ?? 1000)
        }
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

    // MARK: one open device

    /// Opens [c], starts its stream and reads until the stream ends or stop(). True if samples came.
    private func session(_ c: HidCandidate) -> Bool {
        let device: IOHIDDevice = c.device
        let opened: IOReturn = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened != kIOReturnSuccess {
            plog("hid imu: could not open \(c.line): \(Self.words(opened))")
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
            return false
        }
        plog("hid imu: motion stream asked for on \(c.line)")
        var askedAt = Date()
        var asks = 1
        var announced = false
        while !isStopped && !removed {
            spin(0.25)
            if sessionSamples > 0 && !announced {
                announced = true
                let model: String = glasses.family == .air ? (AirImuProtocol.modelName(glasses.product) ?? glasses.name) : glasses.name
                setConnected("USB HID (\(model))")
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

    /// Writes one 64 byte output report (report id 0: neither protocol numbers its reports).
    private func send(_ device: IOHIDDevice, _ bytes: [UInt8], what: String) -> Bool {
        let result: IOReturn = bytes.withUnsafeBufferPointer { (p: UnsafeBufferPointer<UInt8>) -> IOReturn in
            guard let base = p.baseAddress else { return kIOReturnSuccess }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(0), base, CFIndex(p.count))
        }
        if result != kIOReturnSuccess {
            plog("hid imu: the \(what) command was not written: \(Self.words(result))")
            return false
        }
        return true
    }

    /// One input report, on the reader's thread.
    private func received(_ bytes: [UInt8]) {
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
