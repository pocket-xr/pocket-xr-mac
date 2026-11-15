import XCTest
import simd
@testable import PocketXRCore

final class ImuFramerTests: XCTestCase {
    func testReadsAReportSplitAcrossReads() {
        let s = ImuSample(timestampNs: 123_456_789, gyro: SIMD3(0.1, -0.2, 0.3), accel: SIMD3(0, 9.8, 0), temperature: 31)
        let frame = ImuFramer.encode(s)
        XCTAssertEqual(frame.count, 134)
        let f = ImuFramer()
        XCTAssertTrue(f.feed(Array(frame[0..<50])).isEmpty)
        let got = f.feed(Array(frame[50...]))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].timestampNs, 123_456_789)
        XCTAssertEqual(got[0].gyro.y, -0.2, accuracy: 1e-6)
        XCTAssertEqual(got[0].accel.y, 9.8, accuracy: 1e-5)
    }

    func testSkipsNoiseAndOtherReportTypesAndTheOlderMagic() {
        let a = ImuFramer.encode(ImuSample(timestampNs: 1, gyro: .zero, accel: SIMD3(0, 9.8, 0)))
        let mag = ImuFramer.encode(ImuSample(timestampNs: 2, gyro: .zero, accel: .zero), type: 0x04)
        let b = ImuFramer.encode(ImuSample(timestampNs: 3, gyro: .zero, accel: SIMD3(0, 9.8, 0)), magic0: 0x27)
        let f = ImuFramer()
        let got = f.feed([0x00, 0x28, 0x99] + a + mag + b)
        XCTAssertEqual(got.map(\.timestampNs), [1, 3])
        XCTAssertEqual(f.reports, 3)
    }
}

final class HeadFusionTests: XCTestCase {
    private func feed(_ f: HeadFusion, seconds: Double, gyro: SIMD3<Double>, start: inout UInt64) {
        for _ in 0..<Int(seconds * 1000) {
            start += 1_000_000
            f.report(ImuSample(timestampNs: start, gyro: gyro, accel: SIMD3(0, 9.81, 0)))
        }
    }

    func testAStillHeadLooksAheadAndLearnsItsBias() {
        let f = HeadFusion(axes: .aura)
        var t: UInt64 = 0
        feed(f, seconds: 3, gyro: SIMD3(0, 0.5 * .pi / 180, 0), start: &t)
        XCTAssertTrue(f.biasReady)
        let before = f.view().yaw
        feed(f, seconds: 5, gyro: SIMD3(0, 0.5 * .pi / 180, 0), start: &t)
        // With the bias learnt, a still head stays still: well under the 2.5 degrees 5 s of drift would give.
        XCTAssertEqual(f.view().yaw, before, accuracy: 0.2 * .pi / 180)
    }

    func testTurningLeftTurnsTheViewLeft() {
        let f = HeadFusion(axes: .aura)
        var t: UInt64 = 0
        feed(f, seconds: 2.5, gyro: .zero, start: &t)
        feed(f, seconds: 1, gyro: SIMD3(0, 30 * .pi / 180, 0), start: &t) // 30 deg/s for 1 s, left
        XCTAssertEqual(f.view().yaw * 180 / .pi, 30, accuracy: 1.5)
        f.recentre()
        feed(f, seconds: 0.01, gyro: .zero, start: &t)
        XCTAssertEqual(f.view().yaw, 0, accuracy: 0.01)
    }

    func testTheOneFamilysAxesAreFlipped() {
        let f = HeadFusion(axes: .one)
        var t: UInt64 = 0
        // The One reports y down, so "up" gravity reads negative y and a left turn is a negative y rate.
        for _ in 0..<2500 {
            t += 1_000_000
            f.report(ImuSample(timestampNs: t, gyro: .zero, accel: SIMD3(0, -9.81, 0)))
        }
        for _ in 0..<1000 {
            t += 1_000_000
            f.report(ImuSample(timestampNs: t, gyro: SIMD3(0, -30 * .pi / 180, 0), accel: SIMD3(0, -9.81, 0)))
        }
        XCTAssertEqual(f.view().yaw * 180 / .pi, 30, accuracy: 1.5)
    }
}

final class ControlWireTests: XCTestCase {
    func testThe3DSetIsTheBytesPocketXRSends() throws {
        // Pocket XR's capture: `2822 00000008 <id> 1a020801` goes out when a 3D space starts.
        let id = ControlWire.rpcId(0)
        let f = try ControlWire.stereoSetFrame(id, sbs: true)
        XCTAssertEqual(f, [0x28, 0x22, 0, 0, 0, 8, 0x80, 0, 0, 1, 0x1A, 0x02, 0x08, 0x01])
        // Off is an empty request.
        XCTAssertEqual(try ControlWire.stereoSetFrame(id, sbs: false), [0x28, 0x22, 0, 0, 0, 6, 0x80, 0, 0, 1, 0x1A, 0x00])
    }

    func testNothingOutsideTheAllowListIsBuilt() {
        for t in [10079, 10325, 10326, 10327, 10328, 10116, 10110] {
            XCTAssertThrowsError(try ControlWire.rpc(t, 0x8000_0001))
        }
        XCTAssertTrue(ControlWire.sendable.isDisjoint(with: ControlWire.forbidden))
    }

    func testAnswersAreReadAndHeartbeatsSkipped() {
        let answerBody: [UInt8] = [0, 0, 0, 1] + ControlWire.pbMessage(4, ControlWire.pbVarint(2, 1))
        let stream = ControlWire.heartbeatFrame(42) + ControlWire.header(ControlWire.stereoGet, answerBody.count) + answerBody
        let got = ControlWire.Framer().feed(Array(stream))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].type, ControlWire.stereoGet)
        XCTAssertEqual(got[0].result, 0)
        XCTAssertEqual(got[0].flag, 1)
    }

    func testAFloatAnswerAndAText() {
        let body: [UInt8] = [0, 0, 0, 2] + ControlWire.pbMessage(4, ControlWire.pbFloat(2, 1.2) + ControlWire.pbFloat(3, 0.85))
        let a = ControlWire.Framer().feed(ControlWire.header(ControlWire.sizeRange, body.count) + body)
        XCTAssertEqual(a.first?.value ?? 0, 1.2, accuracy: 1e-6)
        XCTAssertEqual(a.first?.value2 ?? 0, 0.85, accuracy: 1e-6)
    }
}

final class SpaceLayoutTests: XCTestCase {
    func testTheMiddleScreenIsAheadAndTheOthersBesideIt() {
        let row = SpaceLayout.row(aspects: [16.0 / 9, 16.0 / 9, 16.0 / 9], widthDeg: 40, distance: 1.4)
        XCTAssertEqual(row.map(\.yawDeg), [42, 0, -42])
        XCTAssertEqual(SpaceLayout.middleYawDeg(row), 0)
        let two = SpaceLayout.row(aspects: [16.0 / 9, 16.0 / 9], widthDeg: 40, distance: 1.4)
        XCTAssertEqual(two.map(\.yawDeg), [21, -21])
    }

    func testAPanelStraightAheadLandsInTheMiddleOfTheView() {
        let p = PanelPlacement(yawDeg: 0, widthDeg: 40, aspect: 16.0 / 9, distance: 1.4)
        let mvp = SpaceMath.perspective(fovYDeg: 38, aspect: 16.0 / 9) * SpaceMath.view(head: .identity, eyeX: 0) * p.modelMatrix
        let c = mvp * SIMD4<Float>(0, 0, 0, 1)
        XCTAssertEqual(c.x / c.w, 0, accuracy: 1e-5)
        XCTAssertEqual(c.y / c.w, 0, accuracy: 1e-5)
        XCTAssertTrue(c.z / c.w > 0 && c.z / c.w < 1, "inside Metal's depth range")
        // Its right edge is 20 degrees right: tan(20) / tan(fovX / 2) of the way across.
        let r = mvp * SIMD4<Float>(0.5, 0, 0, 1)
        let fovX = 2 * atan(tan(19 * Double.pi / 180) * 16 / 9)
        XCTAssertEqual(Double(r.x / r.w), tan(20 * .pi / 180) / tan(fovX / 2), accuracy: 1e-3)
    }

    func testTurningTheHeadLeftMovesTheScreenRightInTheView() {
        let p = PanelPlacement(yawDeg: 0, widthDeg: 40, aspect: 16.0 / 9, distance: 1.4)
        let head = Quat.aboutY(10 * .pi / 180) // looking 10 degrees left
        let mvp = SpaceMath.perspective(fovYDeg: 38, aspect: 16.0 / 9) * SpaceMath.view(head: head, eyeX: 0) * p.modelMatrix
        let c = mvp * SIMD4<Float>(0, 0, 0, 1)
        XCTAssertGreaterThan(c.x / c.w, 0.1)
    }
}
