import Foundation

// The glasses' side: the Air family's and VITURE's HID packets, Steady mode's steps, the control frames Steady mode
// sends, which model can do what, and the Glasses report. Ported from Pocket XR's AirTracking101Test, Discussion24Test,
// Ultrawide0118Test, SteadySixDofTest, OneEyeSixDofTest, SteadyReplugTest and DisplayCommands0532Test.

private func hexBytes(_ s: String) -> [UInt8] {
    s.split(separator: " ").map { UInt8($0, radix: 16) ?? 0 }
}

/// What the glasses answered, for SteadyPlan: 0 is off and 1 is on.
private func glassesState(stereo: Int? = 0, wide: Int? = 0, anchor: Int? = 0, size: Double? = 1.2, max: Double? = 1.2) -> SettingsControl.State {
    var s = SettingsControl.State()
    s.stereo = stereo
    s.ultrawide = wide
    s.anchor = anchor
    s.sizeFactor = size
    s.sizeMax = max
    return s
}

func glassesChecks() {
    airChecks()
    vitureChecks()
    steadyChecks()
    controlWireChecks()
    capabilityChecks()
    reportChecks()
}

private func airChecks() {
    let deg: Double = Double.pi / 180

    // CRC32 as zlib computes it.
    check(AirImuProtocol.crc32(Array("123456789".utf8)) == 0xCBF4_3926, "CRC32 of 123456789")

    // The start command is framed as the Air expects: 0xAA, the CRC of the length, id and payload, length 4, 0x19, 1.
    let start: [UInt8] = AirImuProtocol.streamCommand()
    check(start.count == 64, "the Air command is 64 bytes")
    check(start[0] == 0xAA, "it starts 0xAA")
    check(Int(start[5]) | Int(start[6]) << 8 == 4, "length: one byte of payload plus 3")
    check(start[7] == 0x19 && start[8] == 1, "command 0x19 with 1 starts the stream")
    check(Array(start[1...4]) == [0xC5, 0xD1, 0x21, 0x42], "the start command's CRC32, little endian (0x4221D1C5)")
    check(start[9...].allSatisfy { $0 == 0 }, "the rest is zero")
    let stop: [UInt8] = AirImuProtocol.streamCommand(on: false)
    check(stop[7] == 0x19 && stop[8] == 0, "command 0x19 with 0 stops it")
    check(Array(stop[1...4]) == [0x53, 0xE1, 0x26, 0x35], "the stop command's CRC32 (0x3526E153)")

    // The Air 2 Pro is an Air on HID interface 3; the Aura and the One keep their network stream.
    check(AirImuProtocol.isAir(vendor: 0x3318, product: 0x0432), "the Air 2 Pro is an Air")
    check(AirImuProtocol.modelName(0x0432) == "XREAL Air 2 Pro", "its name")
    check(AirImuProtocol.imuInterface(0x0432) == 3 && AirImuProtocol.imuInterface(0x0424) == 3, "the IMU is on interface 3")
    check(AirImuProtocol.imuInterface(0x0426) == 2, "and on 2 on the Air 2 Ultra")
    // The XBX A01 and A01+ (XREAL's USB id): the Air's stream on HID interface 1 (nrealAirLinuxDriver's hid_ids.c).
    check(AirImuProtocol.imuInterface(0x0440) == 1 && AirImuProtocol.imuInterface(0x0442) == 1, "the XBX A01 and A01+ stream on interface 1")
    check(AirImuProtocol.imuInterface(0x0428) == 3, "the Air 2 stays on interface 3")
    check(AirImuProtocol.isAir(vendor: 0x3318, product: 0x0442) && AirImuProtocol.modelName(0x0442) == "XBX A01+", "the XBX A01+ is an Air, by name")
    check(AirImuProtocol.modelName(0x0440) == "XBX A01", "the XBX A01 by name")
    let xbx = Glasses.detect([UsbDeviceInfo(vendor: 0x3318, product: 0x0442, interfaceClasses: [0x03, 0x03, 0x03], name: "xbx a01+")])
    check(xbx?.name == "XBX A01+" && xbx?.family == .air && xbx?.hidImu == true, "the XBX A01+ is found as an Air with a HID stream")
    check(xbx.map { GlassesReport.modelLines($0).contains("Head tracking link: USB HID, the Air family's stream on interface 1 (untested on a Mac)") } == true,
          "the report names interface 1 for it")
    let air = Glasses.detect([UsbDeviceInfo(vendor: 0x3318, product: 0x0424, interfaceClasses: [0x03, 0x03, 0x03, 0x03], name: "XREAL Air")])
    check(air.map { GlassesReport.modelLines($0).contains("Head tracking link: USB HID, the Air family's stream on interface 3 (untested on a Mac)") } == true,
          "the Air's report names interface 3")
    // The XBX's MCU frame, as nrealAirLinuxDriver lays it out (Pocket XR for Steam Deck 0.6.1's test): 0xFD, the CRC32
    // of everything after it, length 17 + data, a timestamp, the id, 5 reserved bytes, the data.
    let mcu: [UInt8] = AirImuProtocol.mcuCommand(0x31, Array("3.1.1".utf8))
    check(mcu[0] == 0xFD && mcu.count == 5 + 17 + 5, "the MCU frame is 0xFD and 27 bytes for 5 bytes of data")
    check(mcu[5] == 22 && mcu[6] == 0 && Array(mcu[7..<15]) == [UInt8](repeating: 0, count: 8), "its length (22) and a zero timestamp")
    check(mcu[15] == 0x31 && mcu[16] == 0 && Array(mcu[17..<22]) == [0, 0, 0, 0, 0] && Array(mcu[22...]) == Array("3.1.1".utf8),
          "its id, 5 reserved bytes and the SDK version")
    let mcuCrc = UInt32(mcu[1]) | UInt32(mcu[2]) << 8 | UInt32(mcu[3]) << 16 | UInt32(mcu[4]) << 24
    check(mcuCrc == AirImuProtocol.crc32(Array(mcu[5...])), "its CRC32 covers everything after it")
    let beat: [UInt8] = AirImuProtocol.mcuHeartbeat(nowNs: 123)
    check(beat.count == 30 && beat[15] == 0x1A && beat[16] == 0 && beat[22] == 123, "the heartbeat is 0x1A with the time, 30 bytes")
    check(AirImuProtocol.mcuBootstrap.map(\.id) == [0x26, 0x57, 0x12, 0x02, 0x34, 0x35, 0x31], "the handshake's order")
    // Which interface is tried when: the XBX's IMU alone, then with the MCU woken, then interface 2; an Air 2 only 3.
    check(AirImuProtocol.tryOrder(product: 0x0442, interfaces: [0, 1, 2]) == [.imu(1), .wakeMcu, .imuWithMcu(1), .imu(2)],
          "the XBX A01+: interface 1, the MCU, 1 again, then 2")
    check(AirImuProtocol.tryOrder(product: 0x0440, interfaces: [1, 2]) == [.imu(1), .imu(2)], "no MCU interface: 1 then 2")
    check(AirImuProtocol.tryOrder(product: 0x0428, interfaces: [0, 1, 2, 3, 4]) == [.imu(3)], "the Air 2: interface 3 only, no MCU")
    check(AirImuProtocol.tryOrder(product: 0x0424, interfaces: [0, 1, 2]) == [], "the Air without interface 3: nothing written")
    check(AirImuProtocol.tryOrder(product: 0x0426, interfaces: [0, 1, 2, 3]) == [.imu(2)], "the Air 2 Ultra: interface 2 only")
    check(AirImuProtocol.isXbx(0x0442) && AirImuProtocol.isXbx(0x0440) && !AirImuProtocol.isXbx(0x0424), "which models are the XBX")
    check(AirImuProtocol.hexStart([0x01, 0x02, 0xFF], 2) == "01 02 ...", "the log's hex")
    // The command's first byte is what hidapi on macOS sends as the report id.
    check(AirImuProtocol.streamCommand()[0] == 0xAA, "the command's first byte (the report id sent) is 0xAA")
    check(!AirImuProtocol.isAir(vendor: 0x3318, product: 0x0439), "the Aura is not an Air")
    check(!AirImuProtocol.isAir(vendor: 0x3318, product: 0x0437), "the One is not an Air")
    check(!AirImuProtocol.isAir(vendor: 0x1234, product: 0x0432), "another maker's device is not an Air")

    // A report is read in head axes, radians a second and metres per second squared.
    let p: [UInt8] = AirImuProtocol.encodeReport(timestamp: 123_456_789, gyroDegS: SIMD3<Double>(10, -20, 30),
                                                  accelG: SIMD3<Double>(0.1, -0.2, 0.97))
    let r: ImuSample? = AirImuProtocol.parse(p)
    check(r != nil, "an Air report is read")
    if let r = r {
        check(r.timestampNs == 123_456_789, "its timestamp")
        // Head x = -sensor x, y = sensor z, z = sensor y.
        check(near(r.gyro.x, -10 * deg, 1e-4) && near(r.gyro.y, 30 * deg, 1e-4) && near(r.gyro.z, -20 * deg, 1e-4), "gyro in head axes, rad/s")
        // The report is in g; the fusion works in m/s2.
        check(near(r.accel.x, -0.1 * 9.81, 1e-2) && near(r.accel.y, 0.97 * 9.81, 1e-2) && near(r.accel.z, -0.2 * 9.81, 1e-2), "accelerometer in head axes, m/s2")
    }
    // At rest, flat on a desk as worn (sensor z up), gravity reads up in head axes at 9.81.
    let rest: ImuSample? = AirImuProtocol.parse(AirImuProtocol.encodeReport(timestamp: 1, gyroDegS: .zero, accelG: SIMD3<Double>(0, 0, 1)))
    check(rest.map { near($0.accel.y, 9.81, 1e-2) && near($0.accel.x, 0, 1e-6) } ?? false, "gravity is up (head y) at 9.81")
    check(AirImuProtocol.toSensor(AirImuProtocol.toHead(SIMD3<Double>(1, 2, 3))) == SIMD3<Double>(1, 2, 3), "to head axes and back")

    // What is not a report is refused.
    check(AirImuProtocol.parse([UInt8](repeating: 0, count: 64)) == nil, "zeros are not a report")
    check(AirImuProtocol.parse(start) == nil, "a command's answer (0xAA) is not a report")
    var wrong: [UInt8] = p
    wrong[0] = 0x02
    check(AirImuProtocol.parse(wrong) == nil, "a wrong first byte is refused")
    check(AirImuProtocol.parse(Array(p[0..<0x20])) == nil, "a short packet is refused")
    let zeroDiv: [UInt8] = AirImuProtocol.encodeReport(timestamp: 1, gyroDegS: .zero, accelG: .zero, gyroDiv: 0)
    check(AirImuProtocol.parse(zeroDiv) == nil, "a divisor of 0 is not a report")

    // The timestamp's unit comes from its first step.
    var ns = AirTimestamp()
    check(ns.toNs(1_000_000) == 1_000_000 && !ns.decided, "the first timestamp is taken as it is")
    check(ns.toNs(2_000_000) == 2_000_000 && ns.decided && ns.scale == 1, "steps of a million are ns")
    var us = AirTimestamp()
    _ = us.toNs(1_000)
    check(us.toNs(2_000) == 2_000_000 && us.scale == 1000, "steps of a thousand are microseconds")
}

private func vitureChecks() {
    // The write-up's example frame, and the two commands Pocket XR sends.
    let example: [UInt8] = VitureImuProtocol.frame(VitureImuProtocol.msgImuControl, [1, 2])
    check(example == hexBytes("10 00 01 03 02 00 03 00 01 02"), "the IMU control frame matches the write-up's example")
    check(VitureImuProtocol.startRaw() == hexBytes("10 00 01 03 02 00 04 00 02 02"), "the raw stream start command")
    check(VitureImuProtocol.stop() == hexBytes("10 00 01 03 02 00 00 00 00 00"), "the stop command")
    let padded: [UInt8] = VitureImuProtocol.padded(VitureImuProtocol.startRaw())
    check(padded.count == 64 && padded[10...].allSatisfy { $0 == 0 }, "padded with zeros to one 64 byte report")
    let back: VitureImuProtocol.Frame? = VitureImuProtocol.readFrame(VitureImuProtocol.padded(example))
    check(back?.msgId == VitureImuProtocol.msgImuControl && back?.payload == [1, 2], "a frame reads back")

    // A raw sample is read, and a bad frame is not.
    let p: [UInt8] = VitureImuProtocol.encodeRaw(counter: 4242, gyroRadS: SIMD3<Double>(0.1, -0.2, 0.3), accelG: SIMD3<Double>(0, 1, 0))
    check(p.count == 64, "a raw sample is one 64 byte report")
    let f: VitureImuProtocol.Frame? = VitureImuProtocol.readFrame(p)
    check(f?.msgId == VitureImuProtocol.msgRaw, "it is message 0x7309")
    let s: VitureImuProtocol.RawSample? = VitureImuProtocol.parseReport(p)
    check(s?.counter == 4242, "its counter")
    check(s.map { near($0.gyro.x, 0.1, 1e-6) && near($0.gyro.y, -0.2, 1e-6) && near($0.gyro.z, 0.3, 1e-6) } ?? false, "gyro in rad/s")
    check(s.map { near($0.accelG.y, 1, 1e-6) } ?? false, "accelerometer in g")
    if let s = s {
        let sample: ImuSample = VitureImuProtocol.sample(s, timestampNs: 7)
        check(near(sample.accel.y, 9.81, 1e-4) && near(sample.gyro.y, -0.2, 1e-6) && sample.timestampNs == 7, "the fusion gets m/s2 and rad/s")
    }
    var badSum: [UInt8] = p
    badSum[20] = badSum[20] &+ 1
    check(VitureImuProtocol.readFrame(badSum) == nil, "a wrong checksum is refused")
    var badMagic: [UInt8] = p
    badMagic[0] = 0x11
    check(VitureImuProtocol.readFrame(badMagic) == nil, "a wrong preamble is refused")
    check(VitureImuProtocol.readFrame(Array(p[0..<20])) == nil, "a length past the packet is refused")
    let air: [UInt8] = AirImuProtocol.encodeReport(timestamp: 1, gyroDegS: .zero, accelG: SIMD3<Double>(0, 0, 1))
    check(VitureImuProtocol.readFrame(air) == nil, "XREAL's Air report is not a VITURE frame")
    let pose: [UInt8] = VitureImuProtocol.padded(VitureImuProtocol.frame(VitureImuProtocol.msgPose, [UInt8](repeating: 0, count: 24)))
    check(VitureImuProtocol.readFrame(pose) != nil && VitureImuProtocol.parseReport(pose) == nil, "a pose frame is not a raw sample")

    // The clock learns the real rate from the counter.
    var c = VitureClock(nominalHz: 120)
    let period: UInt64 = 1_000_000_000 / 240 // the glasses really send 240 a second
    var t: UInt64 = 0
    for n in 0...200 { t = c.toNs(counter: UInt32(1000 + n), hostNs: 5_000_000_000 + UInt64(n) * period) }
    check(c.learned, "the rate is learnt after 120 samples")
    check(abs(Int64(t) - Int64(5_000_000_000 + 200 * period)) < 1_000, "times follow the measured rate")
    check(c.line.contains("240.0 Hz"), "the clock's line says 240 Hz")
    check(c.toNs(counter: 3, hostNs: 9_000_000_000) == 9_000_000_000 && !c.learned, "a counter that goes back starts over")
}

private func steadyChecks() {
    typealias Step = SteadyPlan.Step

    // Plain Steady mode (3DoF) goes step by step (Ultrawide0118Test).
    check(SteadyPlan.next(on: true, state: glassesState(stereo: 1, anchor: 1, size: 0.8, max: 1.3)) == .anchorOff, "Spatial Anchor off first")
    check(SteadyPlan.next(on: true, state: glassesState(stereo: 1, size: 0.8, max: 1.3)) == .leave3D, "then out of 3D")
    check(SteadyPlan.next(on: true, state: glassesState(size: 0.8, max: 1.3)) == .ultrawideOn, "then Ultrawide on")
    check(SteadyPlan.next(on: true, state: glassesState(wide: 1, size: 0.9, max: 1.2)) == .screenMax, "then the largest screen size")
    check(SteadyPlan.next(on: true, state: glassesState(wide: 1, size: 1.2, max: 1.2)) == .done, "then done")
    check(SteadyPlan.next(on: true, state: SettingsControl.State()) == .wait, "nothing read yet: wait")
    check(SteadyPlan.next(on: true, state: glassesState(wide: 1, max: nil)) == .wait, "the range not read: wait")
    var onlyWide = SettingsControl.State()
    onlyWide.ultrawide = 1
    check(SteadyPlan.next(on: false, state: onlyWide) == .ultrawideOff, "off only turns Ultrawide off")
    onlyWide.ultrawide = 0
    check(SteadyPlan.next(on: false, state: onlyWide) == .done, "off with Ultrawide off: done")
    check(SteadyPlan.next(on: false, state: SettingsControl.State()) == .wait, "off before a read: wait")

    // In 6DoF the anchor goes on last and off first (SteadySixDofTest).
    check(SteadyPlan.next(on: true, state: glassesState(stereo: 1), sixDof: true) == .leave3D, "6DoF: to 2D")
    check(SteadyPlan.next(on: true, state: glassesState(), sixDof: true) == .ultrawideOn, "6DoF: Ultrawide")
    check(SteadyPlan.next(on: true, state: glassesState(wide: 1, size: 1.0), sixDof: true) == .screenMax, "6DoF: size")
    check(SteadyPlan.next(on: true, state: glassesState(wide: 1), sixDof: true) == .anchorOn, "6DoF: Spatial Anchor on, last")
    check(SteadyPlan.next(on: true, state: glassesState(wide: 1, anchor: 1), sixDof: true) == .done, "6DoF: done")
    check(SteadyPlan.next(on: true, state: glassesState(stereo: 1, anchor: 1), sixDof: true) == .leave3D, "6DoF: an anchor already on is kept")
    check(SteadyPlan.next(on: false, state: glassesState(wide: 1, anchor: 1), sixDof: true) == .anchorOff, "6DoF off: the anchor first")
    check(SteadyPlan.next(on: false, state: glassesState(wide: 1), sixDof: true) == .ultrawideOff, "6DoF off: then Ultrawide")
    check(SteadyPlan.next(on: false, state: glassesState(), sixDof: true) == .done, "6DoF off: done")
    check(SteadyPlan.next(on: false, state: glassesState(wide: 1, anchor: 1)) == .ultrawideOff, "plain off leaves the anchor alone")
    check(SteadyPlan.next(on: true, state: glassesState(anchor: nil), sixDof: true) == .wait, "waits for the anchor read")

    // The One series with the Eye goes wide without touching the anchor (OneEyeSixDofTest).
    check(SteadyPlan.next(on: true, state: glassesState(stereo: 1, anchor: nil), sixDof: true, appAnchor: false) == .leave3D, "One: to 2D with no anchor read")
    check(SteadyPlan.next(on: true, state: glassesState(anchor: 1), sixDof: true, appAnchor: false) == .ultrawideOn, "One: an anchor that says on is left alone")
    check(SteadyPlan.next(on: true, state: glassesState(wide: 1, anchor: nil, size: 1.0), sixDof: true, appAnchor: false) == .screenMax, "One: size")
    check(SteadyPlan.next(on: true, state: glassesState(wide: 1, anchor: nil), sixDof: true, appAnchor: false) == .done, "One: done without the anchor")
    check(SteadyPlan.next(on: false, state: glassesState(wide: 1, anchor: 1), sixDof: true, appAnchor: false) == .ultrawideOff, "One off: Ultrawide only")
    check(SteadyPlan.next(on: false, state: glassesState(anchor: 1), sixDof: true, appAnchor: false) == .done, "One off: done, anchor untouched")

    // The whole order, as one list.
    let from3D: SettingsControl.State = glassesState(stereo: 1, size: 0.8, max: 1.3)
    let in6: [Step] = SteadyPlan.steps(entering: true, sixDof: true, state: from3D)
    check(in6 == [.leave3D, .ultrawideOn, .screenMax, .anchorOn], "entering in 6DoF: 2D, Ultrawide, size, Spatial Anchor last")
    let in3: [Step] = SteadyPlan.steps(entering: true, sixDof: false, state: glassesState(stereo: 1, anchor: 1, size: 0.8, max: 1.3))
    check(in3 == [.anchorOff, .leave3D, .ultrawideOn, .screenMax], "entering in 3DoF: Spatial Anchor off, 2D, Ultrawide, size")
    let inOne: [Step] = SteadyPlan.steps(entering: true, sixDof: true, state: glassesState(stereo: 1, anchor: 1, size: 0.8, max: 1.3), appAnchor: false)
    check(inOne == [.leave3D, .ultrawideOn, .screenMax], "entering on the One series with the Eye: no anchor set at all")
    check(SteadyPlan.steps(entering: true, sixDof: true, state: glassesState(wide: 1, anchor: 1)).isEmpty, "already in Steady mode: nothing to send")
    check(SteadyPlan.steps(entering: true, sixDof: true, state: SettingsControl.State()) == [.wait], "nothing read: the plan waits")
    let held: SettingsControl.State = glassesState(wide: 1, anchor: 1)
    let out6: [Step] = SteadyPlan.steps(entering: false, sixDof: true, state: held,
                                        before: SteadyPlan.Before(stereo: 1, ultrawide: 0, size: 0.8, our3D: true))
    check(out6 == [.anchorOff, .ultrawideOff, .sizeBack, .stereoBack], "leaving 6DoF: the reverse, then the size and 3D as before")
    let out3: [Step] = SteadyPlan.steps(entering: false, sixDof: false, state: glassesState(wide: 1),
                                        before: SteadyPlan.Before(stereo: 0, ultrawide: 0, size: 1.2, our3D: false))
    check(out3 == [.ultrawideOff], "leaving 3DoF from 2D with the same size: Ultrawide off only")
    let outWide: [Step] = SteadyPlan.steps(entering: false, sixDof: false, state: glassesState(wide: 1),
                                           before: SteadyPlan.Before(stereo: 0, ultrawide: 1, size: 0.9, our3D: false))
    check(outWide == [.sizeBack, .ultrawideOff], "Ultrawide's own earlier size goes back while still in Ultrawide")
    check(SteadyPlan.steps(entering: false, sixDof: true, state: glassesState()).isEmpty, "leaving when not in it: nothing to send")

    // The size is only put back when it reads different and can be believed.
    check(SteadyPlan.sizeToPutBack(before: 0.8, now: 1.2) == 0.8, "a changed size goes back")
    check(SteadyPlan.sizeToPutBack(before: 1.2, now: 1.203) == nil, "the same size is left")
    check(SteadyPlan.sizeToPutBack(before: nil, now: 1.2) == nil, "a size never read is left")
    check(SteadyPlan.sizeToPutBack(before: 7, now: 1.2) == nil, "a size outside 0.5 to 1.5 is not believed")
    check(SteadyPlan.sizeToPutBack(before: Double.nan, now: 1.2) == nil, "not a number is not sent")

    // Ultrawide leaving by itself (SteadyReplugTest; seconds here).
    check(SteadyPlan.dropped(nowS: 100, lastDropS: nil, linkOpenedS: 98) == .replug, "off just after a new link is a re-plug")
    check(SteadyPlan.dropped(nowS: 100, lastDropS: 95, linkOpenedS: 99) == .replug, "even with a drop moments ago")
    let old: Double = 100 - SteadyPlan.replugS - 0.001
    check(SteadyPlan.dropped(nowS: 100, lastDropS: nil, linkOpenedS: old) == .backIn, "on an old link it is the button: back in once")
    check(SteadyPlan.dropped(nowS: 100, lastDropS: 90, linkOpenedS: old) == .leave, "a second time within 30 s: leave")
    check(SteadyPlan.dropped(nowS: 100, lastDropS: 60, linkOpenedS: old) == .backIn, "a drop long ago does not count")

    // A new state is safe: not in Steady mode, nothing read.
    let fresh = SettingsControl.State()
    check(!fresh.steady && fresh.sizeFactor == nil && fresh.spaceFollow == nil && fresh.steadyNote == nil, "a new state is not in Steady mode")
}

private func controlWireChecks() {
    let id: UInt32 = ControlWire.rpcId(0)
    check(id == 0x8000_0001, "the first request id has the top bit set")
    // Frame: u16 type, u32 length, u32 id, then the Base protobuf with the request in field 3 (Pocket XR's GlassesWire:
    // { 1 = 1 } is "1a020801", an empty request "1a00").
    let wideOn: [UInt8]? = try? ControlWire.ultrawideSetFrame(id, on: true)
    check(wideOn == hexBytes("28 26 00 00 00 08 80 00 00 01 1a 02 08 01"), "Ultrawide on (10278 = 1)")
    let wideOff: [UInt8]? = try? ControlWire.ultrawideSetFrame(id, on: false)
    check(wideOff == hexBytes("28 26 00 00 00 06 80 00 00 01 1a 00"), "Ultrawide off is an empty request")
    let anchorOn: [UInt8]? = try? ControlWire.anchorSetFrame(id, on: true)
    check(anchorOn == hexBytes("28 a5 00 00 00 08 80 00 00 01 1a 02 08 01"), "Spatial Anchor on (10405 = 1)")
    let anchorOff: [UInt8]? = try? ControlWire.anchorSetFrame(id, on: false)
    check(anchorOff == hexBytes("28 a5 00 00 00 06 80 00 00 01 1a 00"), "Spatial Anchor off")
    let twoD: [UInt8]? = try? ControlWire.stereoSetFrame(id, sbs: false)
    check(twoD == hexBytes("28 22 00 00 00 06 80 00 00 01 1a 00"), "2D (10274 = 0)")
    let size: [UInt8]? = try? ControlWire.sizeSetFrame(id, size: 1.2)
    check(size == hexBytes("28 9e 00 00 00 0b 80 00 00 01 1a 05 0d 9a 99 99 3f"), "screen size 1.2 as a float in field 1 (10398)")
    let recentre: [UInt8]? = try? ControlWire.recenterFrame(id)
    check(recentre == hexBytes("28 27 00 00 00 06 80 00 00 01 1a 00"), "recentre (10279) is an empty request")
    let follow: [UInt8]? = try? ControlWire.followFrame(id)
    check(follow == hexBytes("28 2c 00 00 00 08 80 00 00 01 1a 02 08 01"), "follow (10284 = 1)")
    let rangeRead: [UInt8]? = try? ControlWire.rpc(ControlWire.sizeRange, id)
    check(rangeRead == hexBytes("28 9c 00 00 00 06 80 00 00 01 1a 00"), "the size range read (10396)")

    // What must never be sent is refused: EDID (10078 read, 10079 set), firmware (10325 to 10328), duty (10065, 10066).
    for forbidden in [10078, 10079, 10325, 10326, 10327, 10328, 10065, 10066, 10281, 12345] {
        let frame: [UInt8]? = try? ControlWire.rpc(forbidden, id)
        check(frame == nil, "message \(forbidden) is refused")
    }
    // Everything Steady mode sends is on the allow list.
    for wanted in [10273, 10274, 10277, 10278, 10279, 10284, 10396, 10397, 10398, 10404, 10405, 10421] {
        check(ControlWire.sendable.contains(wanted), "message \(wanted) may be sent")
    }

    // The size answers: 10397's value in field 2, 10396's range in fields 2 and 3 of the answer (field 4).
    func answer(_ type: Int, _ body: [UInt8]) -> ControlWire.Answer? {
        let pb: [UInt8] = ControlWire.pbMessage(4, body)
        let bytes: [UInt8] = ControlWire.header(type, 4 + pb.count) + [0, 0, 0, 1] + pb
        return ControlWire.Framer().feed(bytes).first
    }
    let range: ControlWire.Answer? = answer(ControlWire.sizeRange, ControlWire.pbFloat(2, 0.85) + ControlWire.pbFloat(3, 1.2))
    check(range.map { near($0.value ?? 0, 0.85, 1e-6) && near($0.value2 ?? 0, 1.2, 1e-6) && $0.result == 0 } ?? false, "the size range reads back")
    check(ControlWire.believableSize(range?.value2).map { near($0, 1.2, 1e-6) } ?? false, "its largest is believed")
    let sizeNow: ControlWire.Answer? = answer(ControlWire.sizeGet, ControlWire.pbFloat(2, 1.2))
    check(sizeNow.map { near($0.value ?? 0, 1.2, 1e-6) } ?? false, "the screen size reads back")
    let off: ControlWire.Answer? = answer(ControlWire.anchorGet, [])
    check(off?.flag == 0, "proto3 leaves a zero out: an empty answer is off")
    check(ControlWire.believableSize(Double.nan) == nil && ControlWire.believableSize(3) == nil && ControlWire.believableSize(nil) == nil,
          "a size that is not a number, or outside 0.5 to 1.5, is not believed")
}

private func capabilityChecks() {
    func found(_ product: Int, classes: [Int] = [0x02, 0x03], vendor: Int = 0x3318, extra: [UsbDeviceInfo] = []) -> Glasses? {
        Glasses.detect([UsbDeviceInfo(vendor: vendor, product: product, interfaceClasses: classes, name: "")] + extra)
    }
    let aura: Glasses? = found(0x0439, classes: [0x02, 0x0A, 0x03, 0x0E])
    check(aura?.family == .aura, "the Aura is found")
    check(aura?.steadyCapable == true && aura?.sixDofCapable == true && aura?.appAnchor == true, "the Aura: Steady mode, 6DoF, its anchor set by the app")
    check(aura?.hidImu == false && aura?.trackingOnMac == true && aura?.managed == true, "the Aura tracks over the network and is managed")

    for product in [0x0435, 0x0437, 0x043D, 0x0443] {
        let one: Glasses? = found(product)
        check(one?.family == .one && one?.steadyCapable == true, "the One series is offered Steady mode (\(product))")
        check(one?.sixDofCapable == false, "without the Eye it has no 6DoF")
        check(one?.appAnchor == false && one?.managed == false, "its anchor is the user's, and it is not managed")
        check(one?.hidImu == false && one?.controlLink == true, "it tracks over the network")
    }
    // An XREAL camera beside One series glasses is the Eye.
    let eye = UsbDeviceInfo(vendor: 0x3318, product: 0x0450, interfaceClasses: [0x0E], name: "")
    let oneEye: Glasses? = found(0x0437, extra: [eye])
    check(oneEye?.eye == true && oneEye?.sixDofCapable == true && oneEye?.appAnchor == false, "the One with the Eye: 6DoF, turned on by the user")

    let air2: Glasses? = found(0x0428, classes: [0x03, 0x01])
    check(air2?.family == .air && air2?.hidImu == true, "the Air 2 tracks over USB HID")
    check(air2?.steadyCapable == false && air2?.sixDofCapable == false && air2?.controlLink == false, "the Air has no Steady mode and no control link")
    check(air2?.trackingOnMac == false, "HID tracking is the app's choice, not on by itself")
    check(air2.map { $0.axes == .aura } ?? false, "the Air's samples are in head axes")
    let helen: Glasses? = found(0x043F, classes: [0x03])
    check(helen?.family == .air && helen?.hidImu == false, "an Air family model with no known stream is not read")

    let beast: Glasses? = found(Glasses.vitureBeast, classes: [0x03], vendor: Glasses.viture)
    check(beast?.family == .viture && beast?.hidImu == true && beast?.steadyCapable == false, "the VITURE Beast: USB HID, no Steady mode")
    check(beast.map { $0.axes == .one } ?? false, "the Beast sends x right, y down, z front")
    // The Beast also comes as 0x1201 (a tester's, November 2026): the same rules, and it is preferred to a second VITURE id.
    let beast1201: Glasses? = found(Glasses.vitureBeast1201, classes: [0x03], vendor: Glasses.viture)
    check(beast1201?.isBeast == true && beast1201?.hidImu == true && beast1201?.steadyCapable == false, "the VITURE Beast 0x1201: USB HID, no Steady mode")
    check(beast1201.map { $0.axes == .one } ?? false, "the Beast 0x1201 sends x right, y down, z front")
    let otherViture = UsbDeviceInfo(vendor: Glasses.viture, product: 0x1301, interfaceClasses: [0x03], name: "")
    let beastFirst: Glasses? = found(0x1201, classes: [0x03], vendor: Glasses.viture, extra: [otherViture])
    check(beastFirst?.product == 0x1201, "the Beast 0x1201 is picked over another VITURE id")
    check(Glasses.isBeastProduct(0x1211) && Glasses.isBeastProduct(0x1201) && !Glasses.isBeastProduct(0x1301) && !Glasses.isBeastProduct(Glasses.vitureMicrophone), "the Beast's ids are 0x1211 and 0x1201")
    let viture: Glasses? = found(0x1301, classes: [0x03], vendor: Glasses.viture)
    check(viture?.hidImu == true && (viture.map { $0.axes == .aura } ?? false), "other VITURE glasses: as the sensor sends")

    // Other XREAL glasses with a network interface are taken as One family for tracking, but get no settings sent.
    let unknown: Glasses? = found(0x0499)
    check(unknown?.family == .one && unknown?.steadyCapable == false && unknown?.sixDofCapable == false, "unknown XREAL glasses are not offered Steady mode")

    screenNameChecks()
}

private func screenNameChecks() {
    // The maker's name is the glasses' display, with or without an Air on USB.
    check(Glasses.isGlassesScreen(name: "XREAL AURA", builtIn: false, airOnUsb: false), "\"XREAL AURA\" is the glasses")
    check(Glasses.isGlassesScreen(name: "VITURE Beast", builtIn: false, airOnUsb: false), "a VITURE name is the glasses")
    // The first XREAL Air shows on a Mac as just "Air" (a tester's MacBook Air, November 2026).
    check(Glasses.isGlassesScreen(name: "Air", builtIn: false, airOnUsb: true), "\"Air\" is the glasses while an Air is on USB")
    for name in ["Air 2", "Air 2 Pro", "Air 2 Ultra", "air", " AIR 2 PRO "] {
        check(Glasses.isGlassesScreen(name: name, builtIn: false, airOnUsb: true), "\"\(name)\" is the glasses while an Air is on USB")
    }
    check(!Glasses.isGlassesScreen(name: "Air", builtIn: false, airOnUsb: false), "\"Air\" with no Air on USB is another monitor")
    // Never the Mac's own screen, even one whose name would match, and never Pocket XR's floating screens.
    check(!Glasses.isGlassesScreen(name: "Air", builtIn: true, airOnUsb: true), "the built-in screen is never the glasses")
    check(!Glasses.isGlassesScreen(name: "Built-in Retina Display", builtIn: true, airOnUsb: true), "the MacBook's own screen is not the glasses")
    check(!Glasses.isGlassesScreen(name: "Pocket XR 1", builtIn: false, airOnUsb: true), "Pocket XR's floating screen is not the glasses")
    check(!Glasses.isGlassesScreen(name: "Pocket XR XREAL", builtIn: false, airOnUsb: false), "even one with XREAL in its name")
    // Only the Air's own names: a monitor whose name merely has "Air" in it is not taken.
    for name in ["MacBook Air", "Airplay Display", "Air 3", "Fair View", "LG Air"] {
        check(!Glasses.isGlassesScreen(name: name, builtIn: false, airOnUsb: true), "\"\(name)\" is not the glasses")
    }
    check(Glasses.isGlassesScreen(name: "XREAL Air 2 Pro", builtIn: false, airOnUsb: false), "\"XREAL Air 2 Pro\" needs no Air on USB")
}

private func reportChecks() {
    let usb: [UsbDeviceInfo] = [
        UsbDeviceInfo(vendor: 0x3318, product: 0x0439, interfaceClasses: [0x02, 0x0A, 0x03, 0x0E], name: "XREAL Aura"),
        UsbDeviceInfo(vendor: 0x05AC, product: 0x12A8, interfaceClasses: [0x06, 0xFF], name: "Sam Example's iPhone"),
    ]
    var state = SettingsControl.State()
    state.link = true
    state.stereo = 0
    state.anchor = 1
    state.ultrawide = 1
    state.sizeFactor = 1.2
    state.sizeMax = 1.2
    state.steady = true
    let text: String = GlassesReport.text(
        appVersion: "0.2.0 (12)", system: "macOS 14.6.1",
        glasses: Glasses.detect(usb), usb: usb,
        links: ["en7 (169.254.2.10 -> 169.254.2.1)", "en0 192.168.1.23 a4:83:e7:12:34:56"],
        displays: ["\"XREAL AURA\" 3840x1080 at 60 Hz, serial number K7Q2X9P4A1"],
        state: state,
        trackingLine: "on, 1000 samples a second; log at /Users/samexample/Library/Logs/Pocket XR, sam@example.com")
    check(text.contains("XREAL Aura"), "the report names the model")
    check(text.contains("3318:0439"), "and its USB ids")
    check(text.contains("05AC:12A8"), "other USB devices are listed by their ids")
    check(!text.contains("Sam Example"), "but not by name: a name can be a person's")
    check(text.contains("169.254.2.10"), "the glasses' own link is kept")
    check(!text.contains("192.168.1.23"), "another network address is taken out")
    check(!text.lowercased().contains("a4:83:e7:12:34:56"), "a hardware address is taken out")
    check(!text.contains("K7Q2X9P4A1"), "a serial number is taken out")
    check(!text.contains("samexample") && !text.contains("sam@example.com"), "the user's name and email are taken out")
    check(text.contains("Steady mode: on"), "the settings read are in it")
    check(text.contains("Ultrawide: on (1)") && text.contains("Spatial Anchor: on (1)") && text.contains("Screen size: 1.20"), "with Ultrawide, the anchor and the size")
    check(text.contains("macOS 14.6.1") && text.contains("0.2.0 (12)"), "the app and system versions are kept")
    check(text.contains("3840x1080"), "the display line is kept")

    let none: String = GlassesReport.text(appVersion: "0.2.0", system: "macOS 14.6.1", glasses: nil, usb: [], links: [],
                                          displays: [], state: nil, trackingLine: "no glasses")
    check(none.contains("no glasses found"), "a report with no glasses says so")

    let air: [UsbDeviceInfo] = [UsbDeviceInfo(vendor: 0x3318, product: 0x0432, interfaceClasses: [0x03, 0x01], name: "Air 2 Pro")]
    let airText: String = GlassesReport.text(appVersion: "0.2.0", system: "macOS 14.6.1", glasses: Glasses.detect(air), usb: air,
                                             links: [], displays: [], state: nil, trackingLine: "not started")
    check(airText.contains("XREAL Air 2 Pro") && airText.contains("USB HID") && airText.contains("untested"), "an Air's report says HID, and untested on a Mac")
}
