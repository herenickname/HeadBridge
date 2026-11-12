import CoreAudio
import XCTest
@testable import HeadBridge

final class HatorProtocolTests: XCTestCase {
    func testExactVendorCommands() {
        XCTAssertEqual(
            HatorRCSP.vendorGet(0x02, sequence: 0x71),
            [0xFE, 0xDC, 0xBA, 0xC0, 0xFF, 0x00, 0x03, 0x71, 0x02, 0xFF, 0xEF])
        XCTAssertEqual(
            HatorRCSP.vendorSet(0x05, value: 0x01, sequence: 0x71),
            [0xFE, 0xDC, 0xBA, 0xC0, 0xFF, 0x00, 0x03, 0x71, 0x05, 0x01, 0xEF])
        XCTAssertEqual(
            HatorRCSP.acknowledgeVendor(sequence: 0x71),
            [0xFE, 0xDC, 0xBA, 0x00, 0xFF, 0x00, 0x02, 0x00, 0x71, 0xEF])
    }

    func testUnverifiedSpatialModeIsNeverTreatedAsOnOrOff() {
        var snapshot = HatorDeviceSnapshot()
        snapshot.vendor[0x02] = 0x01  // unverified Head Tracking mode
        XCTAssertNil(snapshot.vendorBool(0x02))
        snapshot.vendor[0x02] = 0x02
        XCTAssertEqual(snapshot.vendorBool(0x02), true)
        snapshot.vendor[0x02] = 0x00
        XCTAssertEqual(snapshot.vendorBool(0x02), false)
        snapshot.vendor[0x05] = 0x7F
        XCTAssertNil(snapshot.vendorBool(0x05))
    }

    func testSpatialAckDoesNotBypassCalibration() {
        XCTAssertFalse(HatorBLEClient.shouldVerifyOnAck(code: 0x02))
        XCTAssertGreaterThan(HatorBLEClient.verificationDelay(for: 0x02), 9)
        XCTAssertTrue(HatorBLEClient.shouldVerifyOnAck(code: 0x05))
        XCTAssertTrue(HatorBLEClient.shouldVerifyOnAck(code: 0x08))
        XCTAssertLessThan(HatorBLEClient.verificationDelay(for: 0x05), 1)
    }

    func testSplittingAndCoalescing() {
        let reply: [UInt8] = [0xFE, 0xDC, 0xBA, 0xC0, 0xFF, 0x00, 0x03, 0x71, 0x02, 0x02, 0xEF]
        var parser = HatorRCSPParser()
        XCTAssertTrue(parser.append(Array(reply.prefix(4))).isEmpty)
        let frames = parser.append(Array(reply.dropFirst(4)) + reply)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].parameters, [0x02, 0x02])
    }

    func testOversizedAndMalformedFramesDoNotEscapeBounds() {
        var parser = HatorRCSPParser()
        XCTAssertTrue(parser.append(Array(repeating: 0xAA, count: 1025)).isEmpty)
        XCTAssertTrue(parser.append([0xFE, 0xDC, 0xBA, 0xC0, 0xFF, 0xFF, 0xFF, 0x01, 0xEF]).isEmpty)
        XCTAssertNil(HatorRCSP.decode([0xFE, 0xDC, 0xBA, 0xC0, 0xFF, 0, 3, 1, 2, 0, 0]))
        XCTAssertNil(HatorRCSP.systemFields([0xFF, 0xFE, 0x00]))
        let reply: [UInt8] = [0xFE, 0xDC, 0xBA, 0x00, 0xFF, 0, 2, 0, 0x71, 0xEF]
        XCTAssertEqual(parser.append(reply).first?.status, 0)
    }

    func testSystemInfoParser() {
        let fields = HatorRCSP.systemFields([0xFF, 0x02, 0x00, 89, 0x02, 0x0D, 1])
        XCTAssertEqual(fields?[0x00], [89])
        XCTAssertEqual(fields?[0x0D], [1])
    }

    func testAudioRouteFiltersOnlySpatialAudio() {
        let hardware: HeadphoneCapabilities = [.battery, .spatialAudio, .equalizer]
        let bluetooth = HatorAudioRoute.effectiveCapabilities(hardware, route: .bluetooth)
        let usb = HatorAudioRoute.effectiveCapabilities(hardware, route: .usbDongle)
        XCTAssertTrue(bluetooth.contains(.spatialAudio))
        XCTAssertFalse(usb.contains(.spatialAudio))
        XCTAssertTrue(usb.contains(.battery))
        XCTAssertTrue(usb.contains(.equalizer))
        XCTAssertEqual(HatorAudioRoute.effectiveCapabilities(hardware, route: .none).rawValue, 0)
    }

    func testNarrowAudioMatching() {
        func device(_ name: String, _ transport: UInt32) -> SystemAudioDevice {
            .init(
                id: 123, uid: "AppleUSBAudioEngine:Jieli Technology:USB Composite Device:demo:1", name: name,
                transportType: transport)
        }
        XCTAssertEqual(HatorAudioRoute.forDevice(device("HATOR PHOENIX 2", kAudioDeviceTransportTypeUSB)), .usbDongle)
        XCTAssertEqual(
            HatorAudioRoute.forDevice(device("HATOR PHOENIX 2", kAudioDeviceTransportTypeBluetooth)), .bluetooth)
        XCTAssertEqual(HatorAudioRoute.forDevice(device("HATOR PHOENIX 3", kAudioDeviceTransportTypeUSB)), .none)
        XCTAssertEqual(HatorAudioRoute.forDevice(device("HATOR PHOENIX 2", kAudioDeviceTransportTypeBuiltIn)), .none)
        let spoofed = SystemAudioDevice(
            id: 124, uid: "GenericUSB", name: "HATOR PHOENIX 2", transportType: kAudioDeviceTransportTypeUSB)
        XCTAssertEqual(HatorAudioRoute.forDevice(spoofed), .none)
    }
}
