import Foundation
import XCTest
@testable import HeadBridge

final class OppoProtocolTests: XCTestCase {
    private func data(_ bytes: [UInt8]) -> Data {
        Data(bytes)
    }

    func testBatteryRequestFrameMatchesHardwareCapture() {
        let frame = OppoWire.encode(command: 0x0106, sequence: 0, payload: [])
        XCTAssertEqual(
            frame,
            data([0xAA, 0x07, 0x00, 0x00, 0x06, 0x01, 0x00, 0x00, 0x00])
        )
    }

    func testNoiseSetFrameMatchesHardwareCapture() throws {
        let profile = try XCTUnwrap(OppoModelProfile.profile(for: 0x06C810))
        XCTAssertEqual(
            OppoNoiseCodec.encodeSet(mode: .noiseCancellation, profile: profile, sequence: 0x01),
            data([0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0x01, 0x03, 0x00, 0x01, 0x01, 0x02])
        )
        XCTAssertEqual(
            OppoNoiseCodec.encodeSet(mode: .off, profile: profile, sequence: 0x05),
            data([0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0x05, 0x03, 0x00, 0x01, 0x01, 0x01])
        )
        XCTAssertEqual(
            OppoNoiseCodec.encodeSet(mode: .ambient, profile: profile, sequence: 0x02),
            data([0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0x02, 0x03, 0x00, 0x01, 0x01, 0x04])
        )
    }

    func testFrameParsingBatteryReplyFromHardware() throws {
        var parser = OppoFrameParser()
        let messages = parser.append(
            data([0xAA, 0x0D, 0x00, 0x00, 0x06, 0x81, 0x00, 0x06, 0x00, 0x00, 0x02, 0x01, 0x46, 0x02, 0x46])
        )
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(message.command, 0x8106)
        XCTAssertEqual(message.sequence, 0x00)

        let battery = try XCTUnwrap(OppoBatteryCodec.decode(message.payload))
        XCTAssertEqual(battery.left, 70)
        XCTAssertEqual(battery.right, 70)
        XCTAssertNil(battery.caseLevel)
        XCTAssertFalse(battery.isCharging)
        XCTAssertEqual(battery.lowestEarbudLevel, 70)
    }

    func testBatteryParserHandlesChargingAndCase() throws {
        let battery = try XCTUnwrap(
            OppoBatteryCodec.decode([0x00, 0x03, 0x01, 0x82, 0x02, 0x8A, 0x03, 0x5A])
        )
        XCTAssertEqual(battery.left, 2)
        XCTAssertEqual(battery.right, 10)
        XCTAssertEqual(battery.caseLevel, 90)
        XCTAssertTrue(battery.isCharging)
        XCTAssertEqual(battery.lowestEarbudLevel, 2)
    }

    func testBatteryParserRejectsErrorStatus() {
        XCTAssertNil(OppoBatteryCodec.decode([0x01, 0x02, 0x01, 0x64, 0x02, 0x64]))
        XCTAssertNil(OppoBatteryCodec.decode([0x00, 0x00]))
    }

    func testNoiseReportMappingFromHardware() {
        XCTAssertEqual(OppoNoiseCodec.decodeReport([0x00, 0x01, 0x01, 0x08, 0x00]), .off)
        XCTAssertEqual(OppoNoiseCodec.decodeReport([0x00, 0x01, 0x01, 0x10, 0x00]), .noiseCancellation)
        XCTAssertEqual(OppoNoiseCodec.decodeReport([0x00, 0x01, 0x01, 0x20, 0x00]), .noiseCancellation)
        XCTAssertEqual(OppoNoiseCodec.decodeReport([0x00, 0x01, 0x01, 0x00, 0x01]), .ambient)
        XCTAssertEqual(OppoNoiseCodec.decodeReport([0x00, 0x01, 0x01, 0x00, 0x02]), .ambient)
        XCTAssertNil(OppoNoiseCodec.decodeReport([0x00, 0x01, 0x01, 0x00, 0x08]))
    }

    func testNoisePushEvent() throws {
        let message = OppoMessage(command: 0x0204, sequence: 0xFF, payload: [0x03, 0x01, 0x01, 0x00, 0x01])
        XCTAssertEqual(OppoEventCodec.decode(message), .noiseMode(.ambient))

        let batteryMessage = OppoMessage(
            command: 0x0204,
            sequence: 0xFF,
            // The event body starts with the same status byte as the battery reply.
            payload: [0x01, 0x00, 0x02, 0x01, 0x64, 0x02, 0x5A]
        )
        guard case .battery(let battery)? = OppoEventCodec.decode(batteryMessage) else {
            return XCTFail("Expected a battery push")
        }
        XCTAssertEqual(battery.left, 100)
        XCTAssertEqual(battery.right, 90)

        let ignored = OppoMessage(command: 0x0204, sequence: 0xFF, payload: [0x06, 0x00])
        XCTAssertNil(OppoEventCodec.decode(ignored))
    }

    func testProductIDSelectsAir5sProfile() throws {
        let productID = try XCTUnwrap(OppoModelProfile.productID(from: [0x00, 0x10, 0xC8, 0x06]))
        XCTAssertEqual(productID, 0x06C810)
        let profile = try XCTUnwrap(OppoModelProfile.profile(for: productID))
        XCTAssertEqual(profile.displayName, "OPPO Enco Air5s")
        XCTAssertEqual(profile.noiseBits[.off], 0)
        XCTAssertEqual(profile.noiseBits[.noiseCancellation], 1)
        XCTAssertEqual(profile.noiseBits[.ambient], 2)
        XCTAssertNil(OppoModelProfile.profile(for: 0x123456))
    }

    func testSplitAndCombinedFrames() {
        let first = OppoWire.encode(command: 0x0106, sequence: 0x01, payload: [])
        let second = OppoWire.encode(command: 0x010C, sequence: 0x02, payload: [0x01, 0x01])
        var combined = Data(first)
        combined.append(second)

        var parser = OppoFrameParser()
        var messages: [OppoMessage] = []
        for byte in combined {
            messages.append(contentsOf: parser.append(Data([byte])))
        }
        XCTAssertEqual(messages.map(\.command), [0x0106, 0x010C])
        XCTAssertEqual(messages.map(\.sequence), [0x01, 0x02])
    }

    func testTwoByteLengthPrefixRoundTrips() throws {
        let payload = [UInt8](repeating: 0x5A, count: 200)
        let frame = OppoWire.encode(command: 0x010C, sequence: 0x7F, payload: payload)
        XCTAssertEqual(frame[1], 0xCF)
        XCTAssertEqual(frame[2], 0x01)

        var parser = OppoFrameParser()
        let messages = parser.append(frame)
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(message.command, 0x010C)
        XCTAssertEqual(message.payload, payload)
    }

    func testParserResynchronizesAfterGarbage() throws {
        var data = Data([0xFF, 0x00, 0x01])
        data.append(OppoWire.encode(command: 0x8103, sequence: 0x03, payload: [0x00, 0x10, 0xC8, 0x06]))

        var parser = OppoFrameParser()
        let messages = parser.append(data)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.command, 0x8103)
    }

    func testParserDropsOversizedLength() {
        var parser = OppoFrameParser()
        let messages = parser.append(Data([0xAA, 0xFF, 0xFF, 0xFF, 0x7F, 0x00, 0x00]))
        XCTAssertTrue(messages.isEmpty)
    }

    @MainActor
    func testNameMatchingStaysInsideOppoEncoFamily() {
        XCTAssertTrue(OppoProvider.isSupportedHeadphoneName("OPPO Enco Air5s"))
        XCTAssertTrue(OppoProvider.isSupportedHeadphoneName("OPPO Enco Air5s（星光版）"))
        XCTAssertTrue(OppoProvider.isSupportedHeadphoneName("oppo enco air 5s"))
        XCTAssertFalse(OppoProvider.isSupportedHeadphoneName("OPPO Reno 12"))
        XCTAssertFalse(OppoProvider.isSupportedHeadphoneName("Sony WH-1000XM3"))
        XCTAssertFalse(OppoProvider.isSupportedHeadphoneName("Enco Air5s"))
    }
}

extension OppoProtocolTests {
    func testFeatureSwitchesParseFromHardware() throws {
        let payload: [UInt8] = [
            0x00, 0x0A,
            0x05, 0x00, 0x04, 0x01, 0x0B, 0x00, 0x11, 0x01, 0x18, 0x00,
            0x06, 0x01, 0x1B, 0x01, 0x27, 0x01, 0x28, 0x00, 0x37, 0x01,
        ]
        let states = try XCTUnwrap(OppoStatusCodec.featureSwitches(payload))
        XCTAssertEqual(states[0x04], 1)
        XCTAssertEqual(states[0x06], 1)
        XCTAssertEqual(states[0x0B], 0)
        XCTAssertEqual(states[0x11], 1)
        XCTAssertEqual(states[0x18], 0)
        XCTAssertEqual(states[0x1B], 1)
        XCTAssertEqual(states[0x37], 1)
    }

    func testFirmwareVersionDecodesTriples() {
        let payload: [UInt8] =
            [0x00, 0x04]
            + Array("1,2,163,2,2,163,3,1,01,3,2,102".utf8)
        XCTAssertEqual(OppoStatusCodec.firmware(payload), "163.163.102")
        XCTAssertNil(OppoStatusCodec.firmware([0x01, 0x00]))
    }

    func testCustomEQPresetParsesNameAndBands() throws {
        let name = Array("Balance v2".utf8)
        var payload: [UInt8] = [0x00, 0x01, 0x01, 0xFA, 0x06, 0x04, UInt8(name.count)]
        payload += name
        payload += [0x02]
        payload += [0x1F, 0x00, 0x00]  // 31 Hz, 0 dB
        payload += [0x3E, 0x00, 0xFE]  // 62 Hz, -2 dB

        let presets = try XCTUnwrap(OppoStatusCodec.eqPresets(payload))
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].id, 0x04)
        XCTAssertEqual(presets[0].name, "Balance v2")
        XCTAssertEqual(
            presets[0].bands,
            [OppoEQBand(frequency: 31, gain: 0), OppoEQBand(frequency: 62, gain: -2)]
        )
    }

    func testGameSoundAndSpatialParsing() throws {
        XCTAssertEqual(
            OppoStatusCodec.gameSound([0x00, 0x03, 0x02, 0x03, 0x00]),
            OppoGameSoundState(selected: 3, options: [3, 0])
        )
        XCTAssertEqual(OppoStatusCodec.spatialType([0x00, 0x01]), 1)
        XCTAssertEqual(OppoStatusCodec.codec([0x00, 0x02]), 2)
        XCTAssertEqual(OppoStatusCodec.alertVolume([0x00, 0x0A]), 10)
    }

    func testWearingParsesBudsAndCase() throws {
        let state = try XCTUnwrap(
            OppoStatusCodec.wearing([0x00, 0x03, 0x01, 0x07, 0x02, 0x07, 0x03, 0x04])
        )
        XCTAssertTrue(state.leftInEar)
        XCTAssertTrue(state.rightInEar)
        XCTAssertTrue(state.lidOpen)
        XCTAssertFalse(state.leftInCase)
    }

    func testDualDeviceListParsesNamesAndFlags() throws {
        var payload: [UInt8] = [0x00, 0x02]
        // MAC 01:02:03:04:05:06 written reversed, len 5, connected, this host + audio, name "Mac".
        payload += [0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x06, 0x02, 0x03, 0x03]
        payload += Array("Mac".utf8)
        // Second device, len 7, disconnected, no flags, name "Phone".
        payload += [0x16, 0x15, 0x14, 0x13, 0x12, 0x11, 0x08, 0x00, 0x00, 0x05]
        payload += Array("Phone".utf8)

        let devices = try XCTUnwrap(OppoStatusCodec.dualDevices(payload))
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].mac, "01:02:03:04:05:06")
        XCTAssertEqual(devices[0].name, "Mac")
        XCTAssertTrue(devices[0].isConnected)
        XCTAssertTrue(devices[0].isThisHost)
        XCTAssertTrue(devices[0].isMainAudio)
        XCTAssertEqual(devices[1].name, "Phone")
        XCTAssertFalse(devices[1].isConnected)
    }

    func testPreferredDeviceParsing() {
        XCTAssertEqual(
            OppoStatusCodec.preferredDevice([0x00, 0x02, 0x01, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]),
            "AA:BB:CC:DD:EE:FF"
        )
        XCTAssertNil(OppoStatusCodec.preferredDevice([0x00, 0x02, 0x00]))
    }

    func testGestureTableParsingAndLabels() throws {
        let bindings = try XCTUnwrap(
            OppoStatusCodec.gestures([
                0x00, 0x02,
                0x01, 0x01, 0x01, 0x01,
                0x02, 0x06, 0x06, 0x1D,
            ])
        )
        XCTAssertEqual(bindings.count, 2)
        XCTAssertEqual(bindings[0].sideLabel, "Left")
        XCTAssertEqual(bindings[0].actionLabel, "Single")
        XCTAssertEqual(bindings[0].functionLabel, "Play / pause")
        XCTAssertEqual(bindings[1].groupLabel, "Call")
        XCTAssertEqual(bindings[1].functionLabel, "Answer / end call")
    }

    func testSpatialFeatureWriteFrames() {
        XCTAssertEqual(
            OppoWire.encode(command: 0x0403, sequence: 0x07, payload: [0x1B, 0x01]),
            data([0xAA, 0x09, 0x00, 0x00, 0x03, 0x04, 0x07, 0x02, 0x00, 0x1B, 0x01])
        )
        XCTAssertEqual(
            OppoWire.encode(command: 0x0423, sequence: 0x08, payload: [0x03, 0x01]),
            data([0xAA, 0x09, 0x00, 0x00, 0x23, 0x04, 0x08, 0x02, 0x00, 0x03, 0x01])
        )
    }
}

extension OppoProtocolTests {
    func testSpatialTypeWriteFrames() {
        XCTAssertEqual(
            OppoWire.encode(command: 0x0422, sequence: 0x09, payload: [0x01]),
            data([0xAA, 0x08, 0x00, 0x00, 0x22, 0x04, 0x09, 0x01, 0x00, 0x01])
        )
        XCTAssertEqual(
            OppoWire.encode(command: 0x0422, sequence: 0x0A, payload: [0x00]),
            data([0xAA, 0x08, 0x00, 0x00, 0x22, 0x04, 0x0A, 0x01, 0x00, 0x00])
        )
    }
}

extension OppoProtocolTests {
}

extension OppoProtocolTests {
    func testMACBytesReverseListOrder() {
        XCTAssertEqual(
            OppoWire.macBytes(from: "68:85:A4:1F:0A:66"),
            [0x66, 0x0A, 0x1F, 0xA4, 0x85, 0x68]
        )
        XCTAssertNil(OppoWire.macBytes(from: "not-a-mac"))
    }

    func testHiResAndDualCommandFrames() {
        XCTAssertEqual(
            OppoWire.encode(command: 0x041A, sequence: 0x03, payload: [0x08, 0x01, 0x00]),
            data([0xAA, 0x0A, 0x00, 0x00, 0x1A, 0x04, 0x03, 0x03, 0x00, 0x08, 0x01, 0x00])
        )
        XCTAssertEqual(
            OppoWire.encode(command: 0x0427, sequence: 0x04, payload: [0x09]),
            data([0xAA, 0x08, 0x00, 0x00, 0x27, 0x04, 0x04, 0x01, 0x00, 0x09])
        )
        XCTAssertEqual(
            OppoWire.encode(command: 0x0429, sequence: 0x05, payload: [0x01, 0x66, 0x0A, 0x1F, 0xA4, 0x85, 0x68]),
            data([0xAA, 0x0E, 0x00, 0x00, 0x29, 0x04, 0x05, 0x07, 0x00, 0x01, 0x66, 0x0A, 0x1F, 0xA4, 0x85, 0x68])
        )
    }

    func testGestureTableWriteFrame() {
        var payload: [UInt8] = [0x02]
        payload += [0x01, 0x01, 0x01, 0x01]
        payload += [0x02, 0x06, 0x06, 0x1C]
        XCTAssertEqual(
            OppoWire.encode(command: 0x0401, sequence: 0x06, payload: payload),
            data([0xAA, 0x10, 0x00, 0x00, 0x01, 0x04, 0x06, 0x09, 0x00,
                  0x02, 0x01, 0x01, 0x01, 0x01, 0x02, 0x06, 0x06, 0x1C])
        )
    }
}

extension OppoProtocolTests {
    func testCustomEQWriteFrame() {
        let bands = [
            OppoEQBand(frequency: 31, gain: 0),
            OppoEQBand(frequency: 62, gain: -2),
            OppoEQBand(frequency: 16_000, gain: 3),
        ]
        let frame = OppoEQWrite.frame(
            action: 0x01,
            id: 0,
            name: "Test",
            bands: bands,
            sequence: 0x0B
        )
        let bytes = [UInt8](frame)
        XCTAssertEqual(bytes[0], 0xAA)
        XCTAssertEqual(bytes[4], 0x18)
        XCTAssertEqual(bytes[5], 0x04)
        XCTAssertEqual(bytes[6], 0x0B)
        XCTAssertEqual(Array(bytes[9...12]), [0x01, 0xFA, 0x06, 0x00])
        XCTAssertEqual(bytes[13], 0x04)  // name length
        XCTAssertEqual(Array(bytes[14...17]), Array("Test".utf8))
        XCTAssertEqual(bytes[18], 0x03)  // band count
    }

}

extension OppoProtocolTests {
    func testNoiseDepthFramesAndParsing() {
        XCTAssertEqual(
            [UInt8](OppoNoiseCodec.encodeSetLevel(.light, sequence: 0x03)),
            [0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0x03, 0x03, 0x00, 0x01, 0x01, 0x40]
        )
        XCTAssertEqual(
            [UInt8](OppoNoiseCodec.encodeSetLevel(.smart, sequence: 0x04)),
            [0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0x04, 0x03, 0x00, 0x01, 0x01, 0x80]
        )
        XCTAssertEqual(OppoNoiseCodec.level(forRawValue: 0x10), .deep)
        XCTAssertEqual(OppoNoiseCodec.level(forRawValue: 0x40), .light)
        XCTAssertEqual(OppoNoiseCodec.level(forRawValue: 0x80), .smart)
        XCTAssertNil(OppoNoiseCodec.level(forRawValue: 0x02))
        XCTAssertEqual(OppoNoiseCodec.decodeSmartLevel([0x00, 0x04, 0x01, 0x40, 0x00]), .light)
        XCTAssertEqual(OppoNoiseCodec.reportRawValue([0x00, 0x01, 0x01, 0x10, 0x00]), 0x10)
    }
}

extension OppoProtocolTests {
    func testHoldCycleFrames() {
        XCTAssertEqual(
            [UInt8](OppoNoiseCodec.encodeHoldCycle(0x07, sequence: 0x05)),
            // Hardware capture: 0x0404 02 01 07, frame length 0x0A.
            [0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0x05, 0x03, 0x00, 0x02, 0x01, 0x07]
        )
        XCTAssertEqual(OppoNoiseCodec.decodeHoldCycle([0x00, 0x02, 0x01, 0x03, 0x00]), 0x03)
        XCTAssertEqual(OppoNoiseCodec.decodeHoldCycle([0x00, 0x02, 0x01, 0x07, 0x00]), 0x07)
        XCTAssertNil(OppoNoiseCodec.decodeHoldCycle([0x01, 0x02, 0x01, 0x03, 0x00]))
    }
}

extension OppoProtocolTests {
    func testDualDeviceListRejectsTruncatedEntries() {
        let full: [UInt8] =
            [0x00, 0x01]
            + [0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x06, 0x02, 0x03, 0x03]
            + Array("Mac".utf8)

        for length in 2..<full.count {
            XCTAssertNil(
                OppoStatusCodec.dualDevices(Array(full.prefix(length))),
                "length \(length) must not parse a partial entry"
            )
        }
        XCTAssertEqual(OppoStatusCodec.dualDevices(full)?.count, 1)
        XCTAssertNil(OppoStatusCodec.dualDevices([0x00, 0x01] + [0x06, 0x05, 0x04, 0x03, 0x02, 0x01]))
        XCTAssertNil(OppoStatusCodec.dualDevices([0x00, 0x01] + [0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x06]))
        XCTAssertNil(
            OppoStatusCodec.dualDevices(
                [0x00, 0x01] + [0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x06, 0x02, 0x03]
            )
        )
    }

    func testWearingRequiresBothBuds() {
        XCTAssertNil(OppoStatusCodec.wearing([0x00, 0x00]))
        XCTAssertNil(OppoStatusCodec.wearing([0x00, 0x01, 0x03, 0x04]))
        XCTAssertNil(OppoStatusCodec.wearing([0x00, 0x01, 0x01, 0x07]))
        XCTAssertNil(OppoStatusCodec.wearing([0x00, 0x01, 0x02, 0x07]))

        let bothOut = OppoStatusCodec.wearing([0x00, 0x02, 0x01, 0x04, 0x02, 0x04])
        XCTAssertEqual(bothOut?.bothBudsReported, true)
        XCTAssertEqual(bothOut?.bothOutOfEar, true)
        XCTAssertEqual(bothOut?.leftInEar, false)
        XCTAssertEqual(bothOut?.rightInEar, false)

        let leftIn = OppoStatusCodec.wearing([0x00, 0x02, 0x01, 0x07, 0x02, 0x04])
        XCTAssertEqual(leftIn?.bothOutOfEar, false)
        XCTAssertEqual(leftIn?.leftInEar, true)
        XCTAssertEqual(leftIn?.rightInEar, false)

        let rightIn = OppoStatusCodec.wearing([0x00, 0x02, 0x01, 0x04, 0x02, 0x07])
        XCTAssertEqual(rightIn?.bothOutOfEar, false)
    }
}

extension OppoProtocolTests {
    func testRingRequiresFreshBothOutWearingReport() {
        let now = Date()
        let bothOut = OppoWearingState(left: 0x04, right: 0x04, caseStatus: 0x04)
        let leftIn = OppoWearingState(left: 0x07, right: 0x04, caseStatus: 0x04)

        XCTAssertTrue(OppoRingSafety.canRing(wearing: bothOut, updatedAt: now, now: now))
        XCTAssertTrue(
            OppoRingSafety.canRing(
                wearing: bothOut,
                updatedAt: now.addingTimeInterval(-2),
                now: now
            )
        )
        XCTAssertFalse(
            OppoRingSafety.canRing(
                wearing: bothOut,
                updatedAt: now.addingTimeInterval(-4),
                now: now
            )
        )
        XCTAssertFalse(OppoRingSafety.canRing(wearing: bothOut, updatedAt: nil, now: now))
        XCTAssertFalse(OppoRingSafety.canRing(wearing: nil, updatedAt: now, now: now))
        XCTAssertFalse(OppoRingSafety.canRing(wearing: leftIn, updatedAt: now, now: now))
    }
}
