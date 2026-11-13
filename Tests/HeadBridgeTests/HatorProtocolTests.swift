import CoreAudio
import XCTest
@testable import HeadBridge

final class HatorProtocolTests: XCTestCase {
    func testRapidToggleWhileBLEWriteIsPending() {
        var state = HatorSpatialSwitchState()
        XCTAssertFalse(state.select(true))  // still no device readback
        state.receiveDevice(false)

        XCTAssertTrue(state.select(true))
        XCTAssertEqual(state.displayed, true)  // immediate ON
        XCTAssertEqual(state.beginWrite(), true)
        XCTAssertEqual(state.inFlight, true)

        state.receiveDevice(false)  // an older poll must not revert the UI
        XCTAssertEqual(state.displayed, true)
        XCTAssertTrue(state.select(false))  // immediate OFF, no waiting
        XCTAssertEqual(state.displayed, false)
        XCTAssertNil(state.beginWrite())  // no concurrent RCSP commands

        XCTAssertEqual(
            state.completeWrite(sent: true, verified: true, readback: true),
            .send(false)
        )
        XCTAssertEqual(state.inFlight, false)
        XCTAssertEqual(state.displayed, false)

        // The second (latest) RCSP command finishes. Only now settle the UI.
        state.receiveDevice(false)
        XCTAssertEqual(
            state.completeWrite(sent: false, verified: true, readback: false),
            .settled
        )
        XCTAssertFalse(state.isPending)
        XCTAssertEqual(state.displayed, false)
        XCTAssertEqual(state.confirmed, false)
    }

    func testRapidTapsCoalesceToLatestValue() {
        var state = HatorSpatialSwitchState()
        state.receiveDevice(false)
        XCTAssertTrue(state.select(true))
        XCTAssertEqual(state.beginWrite(), true)
        XCTAssertTrue(state.select(false))
        XCTAssertTrue(state.select(true))  // final user intent = ON
        XCTAssertFalse(state.select(true))  // redundant tap ignored
        XCTAssertEqual(
            state.completeWrite(sent: true, verified: true, readback: true),
            .settled
        )
        XCTAssertNil(state.inFlight)
        XCTAssertEqual(state.displayed, true)
        XCTAssertFalse(state.isPending)
    }

    func testRevertBeforeAudioStartsDoesNotSendBLECommand() {
        var state = HatorSpatialSwitchState()
        state.receiveDevice(false)
        XCTAssertTrue(state.select(true))
        XCTAssertTrue(state.select(false))
        XCTAssertNil(state.beginWrite())  // audio startup can be cancelled
        XCTAssertFalse(state.isPending)
        XCTAssertEqual(state.displayed, false)
    }

    func testFailedWriteAndCancellationRollbackToDeviceState() {
        var state = HatorSpatialSwitchState()
        state.receiveDevice(true)
        XCTAssertTrue(state.select(false))
        XCTAssertEqual(state.beginWrite(), false)
        state.receiveDevice(true)
        XCTAssertEqual(state.displayed, false)
        XCTAssertEqual(
            state.completeWrite(sent: false, verified: false, readback: true),
            .failed
        )
        XCTAssertEqual(state.displayed, true)

        XCTAssertTrue(state.select(false))
        XCTAssertEqual(state.beginWrite(), false)
        state.receiveDevice(false)
        state.cancel()  // route switch or disconnect
        XCTAssertEqual(state.displayed, false)
        XCTAssertEqual(
            state.completeWrite(sent: false, verified: true, readback: false),
            .stale
        )

        state.reset()
        XCTAssertNil(state.displayed)
        XCTAssertNil(state.confirmed)
        XCTAssertFalse(state.isPending)
    }

    func testFailedOldWriteReconcilesNewestUserIntent() {
        var state = HatorSpatialSwitchState()
        state.receiveDevice(false)
        XCTAssertTrue(state.select(true))
        XCTAssertEqual(state.beginWrite(), true)
        XCTAssertTrue(state.select(false))
        // No readback: the first write may have applied even though its GET failed.
        // Explicitly write the last chosen state rather than trusting a stale
        // cached confirmation.
        XCTAssertEqual(
            state.completeWrite(sent: true, verified: false, readback: nil),
            .send(false)
        )
        XCTAssertEqual(
            state.completeWrite(sent: false, verified: true, readback: false),
            .settled
        )
        XCTAssertEqual(state.displayed, false)

        XCTAssertTrue(state.select(true))
        XCTAssertEqual(state.beginWrite(), true)
        XCTAssertTrue(state.select(false))
        XCTAssertEqual(
            state.completeWrite(sent: true, verified: false, readback: false),
            .settled
        )  // latest requested OFF is already confirmed; no second write
    }

    @MainActor
    func testSilentPlaybackRequiresAnExplicitAudioDestination() {
        let stream = HatorSilentAudioStream()
        XCTAssertFalse(stream.start(deviceUID: ""))
        XCTAssertFalse(stream.isRunning)
        stream.stop()
        XCTAssertFalse(stream.isRunning)
    }

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

    func testNoiseAndEqualizerCommandBytes() throws {
        let anc = try XCTUnwrap(HatorDSP.noiseControl(.noiseCancellation, sequence: 0x52))
        XCTAssertEqual(
            anc,
            [
                0xFE, 0xDC, 0xBA, 0xC0, 0x08, 0x00, 0x0D, 0x52,
                0xFF, 0x0A, 0x0D, 0x01, 0x40, 0, 0, 0, 0x40, 0, 0, 0, 0xEF,
            ])
        XCTAssertNil(HatorDSP.noiseControl(.windReduction, sequence: 1))

        let preset = try XCTUnwrap(HatorDSP.equalizerPreset(1, sequence: 0x37))
        XCTAssertEqual(
            preset,
            HatorRCSP.command(
                opcode: 0x08, sequence: 0x37,
                parameters: [0xFF, 0x02, 0x04, 0x01]
                    + Array(repeating: 0, count: 10)))
        XCTAssertNil(HatorDSP.equalizerPreset(9, sequence: 0x37))
        let values = [0, -12, 5, 1, 0, 0, 0, 0, 0, 12]
        let custom = try XCTUnwrap(HatorDSP.customEqualizer(values, sequence: 0x38))
        XCTAssertEqual(
            custom,
            HatorRCSP.command(
                opcode: 0x08, sequence: 0x38,
                parameters: [
                    0xFF, 0x0C, 0x04, 0x08,
                    0, 0xF4, 5, 1, 0, 0, 0, 0, 0, 12,
                ]))
        XCTAssertNil(HatorDSP.customEqualizer(Array(repeating: 0, count: 9), sequence: 1))
        XCTAssertNil(HatorDSP.customEqualizer(Array(repeating: 13, count: 10), sequence: 1))
    }

    func testEqualizerDeviceFieldsAndModeValidation() {
        let header: [UInt8] = [
            0x0A, 0x00, 0x47, 0x00, 0xAA, 0x01, 0xF4, 0x01, 0xF4,
            0x17, 0x70, 0x0B, 0x54, 0x12, 0xC0, 0x13, 0x88, 0x27,
            0x10, 0x54, 0x5F,
        ]
        let rows = (0..<9).flatMap { i -> [UInt8] in
            [UInt8(i)]
                + (0..<10).map { j -> UInt8 in
                    UInt8(bitPattern: Int8(i == 1 && j == 1 ? -16 : 0))
                }
        }
        let presets = HatorDSP.eqPresets(header + rows)
        XCTAssertEqual(presets.count, 9)
        XCTAssertEqual(
            presets.map(\.title),
            [
                "Normal", "Shooters", "Rock", "Movie", "Action", "Hip-Hop/Rap", "EDM", "Sport", "Custom",
            ])
        XCTAssertEqual(presets[1].gains[1], -16)  // raw device value, not UI clamp
        XCTAssertTrue(HatorDSP.eqPresets(Array(repeating: 0, count: 120)).isEmpty)
        XCTAssertTrue(HatorDSP.eqPresets(Array(repeating: 0, count: 119)).isEmpty)
        XCTAssertEqual(HatorDSP.eqState([0x08] + [0xF4] + Array(repeating: 0, count: 9))?.gains.first, -12)
        XCTAssertNil(HatorDSP.eqState([0x09] + Array(repeating: 0, count: 10)))
        XCTAssertNil(HatorDSP.eqState([0x08]))
    }

    func testANCDiscoveryValidatesAllModes() {
        let records = (0..<3).flatMap { [UInt8($0)] + Array(repeating: UInt8(0), count: 8) }
        XCTAssertEqual(HatorDSP.availableANC([3] + records), [.off, .noiseCancellation, .ambient])
        XCTAssertTrue(HatorDSP.availableANC([3] + Array(records.dropLast())).isEmpty)
        XCTAssertTrue(HatorDSP.availableANC([0]).isEmpty)
        XCTAssertTrue(HatorDSP.availableANC([2] + Array(repeating: 0, count: 18)).isEmpty)
    }

    func testSystemNotifyFramesAndReadbackValidation() {
        let update: [UInt8] = [
            0xFE, 0xDC, 0xBA, 0xC0, 0x09, 0, 5, 0x4D,
            0xFF, 0x02, 0x0D, 0x01, 0xEF,
        ]
        let frame = HatorRCSP.decode(update)
        XCTAssertEqual(frame?.opcode, 0x09)
        XCTAssertEqual(frame?.sequence, 0x4D)
        XCTAssertEqual(frame?.requiresAcknowledgement, true)
        XCTAssertEqual(HatorRCSP.systemFields(frame?.parameters ?? [])?[0x0D], [1])
        XCTAssertEqual(
            HatorRCSP.acknowledge(opcode: 0x09, sequence: 0x4D),
            [0xFE, 0xDC, 0xBA, 0, 0x09, 0, 2, 0, 0x4D, 0xEF])
        XCTAssertTrue(HatorSystemWrite.noise(.noiseCancellation).matches([0x0D: [1]]))
        XCTAssertFalse(HatorSystemWrite.noise(.noiseCancellation).matches([0x0D: [2]]))
        XCTAssertTrue(HatorSystemWrite.preset(1).matches([0x04: [1] + Array(repeating: 0, count: 10)]))
        XCTAssertFalse(
            HatorSystemWrite.customEQ(Array(repeating: 0, count: 10))
                .matches([0x04: [8, 1] + Array(repeating: 0, count: 9)]))
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
