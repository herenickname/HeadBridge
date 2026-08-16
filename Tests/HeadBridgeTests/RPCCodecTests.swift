import Combine
import Foundation
import XCTest
@testable import HeadBridge

final class RPCCodecTests: XCTestCase {
    @MainActor
    func testManagerForwardsProviderChangesAfterTheProviderMutates() async {
        let provider = TestHeadphoneProvider()
        let manager = HeadphoneManager(providers: [provider])
        let updated = expectation(description: "Manager publishes the updated provider snapshot")
        let cancellation = manager.objectWillChange.sink {
            XCTAssertEqual(provider.connectedName, "PX7 S3")
            updated.fulfill()
        }

        provider.rename("PX7 S3")
        await fulfillment(of: [updated], timeout: 1)
        withExtendedLifetime(cancellation) {}
    }

    @MainActor
    func testManagerShutdownReleasesEachProviderOnlyOnce() {
        let provider = TestHeadphoneProvider()
        let manager = HeadphoneManager(providers: [provider])

        manager.shutdown()
        manager.shutdown()

        XCTAssertEqual(provider.disconnectCallCount, 1)
    }

    @MainActor
    func testSidebarModelTracksTheProviderConnectionSnapshot() async {
        let provider = TestHeadphoneProvider()
        let device = RecognizedHeadphoneDevice(
            id: "test-provider:test-device",
            deviceID: "test-device",
            name: "PX7 S3",
            address: "AA:BB:CC:DD:EE:FF",
            isConnected: true,
            providerID: provider.providerID,
            vendorName: provider.vendorName
        )
        let model = HeadphoneProviderSidebarModel(device: device, provider: provider)
        let updated = expectation(description: "Sidebar receives the ready provider snapshot")
        let cancellation = model.$snapshot.dropFirst().sink { snapshot in
            XCTAssertEqual(snapshot.name, "PX7 S3")
            XCTAssertEqual(snapshot.state, .ready)
            updated.fulfill()
        }

        provider.connect(name: "PX7 S3")

        await fulfillment(of: [updated], timeout: 1)
        withExtendedLifetime(cancellation) {}
    }

    func testBluetoothInventoryDecodesPairedAndConnectedDevicesWithoutDuplicates() throws {
        let json = #"""
            {
              "SPBluetoothDataType": [{
                "device_connected": [
                  {"Px7 S3": {
                    "device_address": "AA:BB:CC:DD:EE:FF",
                    "device_services": "0x800019 < HFP AVRCP A2DP ACL >"
                  }},
                  {"PX7 S3": {
                    "device_address": "77:88:99:AA:BB:CC",
                    "device_services": "0x400000 < BLE >"
                  }}
                ],
                "device_not_connected": [
                  {"Px7 S3": {"device_address": "AA:BB:CC:DD:EE:FF"}},
                  {"WH-1000XM3": {"device_address": "11:22:33:44:55:66"}}
                ]
              }]
            }
            """#

        let devices = try XCTUnwrap(BluetoothDeviceInventory.decode(Data(json.utf8)))

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first(where: { $0.id == "aa:bb:cc:dd:ee:ff" })?.name, "Px7 S3")
        XCTAssertEqual(devices.first(where: { $0.id == "aa:bb:cc:dd:ee:ff" })?.isConnected, true)
        XCTAssertEqual(devices.first(where: { $0.id == "aa:bb:cc:dd:ee:ff" })?.isAudioConnected, true)
        XCTAssertNil(devices.first(where: { $0.id == "77:88:99:aa:bb:cc" }))
        XCTAssertEqual(devices.first(where: { $0.id == "11:22:33:44:55:66" })?.isConnected, false)
    }

    @MainActor
    func testSonyAutomaticConnectionUsesBluetoothAudioWithoutWaitingForCoreAudio() {
        let sony = BluetoothPairedDevice(
            id: "11:22:33:44:55:66",
            name: "WH-1000XM3",
            address: "11:22:33:44:55:66",
            isConnected: true,
            isAudioConnected: true
        )
        let controlOnly = BluetoothPairedDevice(
            id: "aa:bb:cc:dd:ee:ff",
            name: "WH-1000XM3",
            address: "AA:BB:CC:DD:EE:FF",
            isConnected: true
        )

        XCTAssertEqual(
            SonyMDRProvider.automaticConnectionCandidate(
                from: [controlOnly, sony],
                coreAudioDeviceNames: []
            ),
            sony
        )
    }

    @MainActor
    func testManagerListsOnlyPairedDevicesRecognizedByAProvider() {
        let provider = TestHeadphoneProvider()
        let manager = HeadphoneManager(providers: [provider])

        manager.applyBluetoothPairedDevices([
            BluetoothPairedDevice(
                id: "aa:bb:cc:dd:ee:ff",
                name: "Test Headphones",
                address: "AA:BB:CC:DD:EE:FF",
                isConnected: false
            ),
            BluetoothPairedDevice(
                id: "11:22:33:44:55:66",
                name: "Unrelated Speaker",
                address: "11:22:33:44:55:66",
                isConnected: true
            ),
        ])

        XCTAssertEqual(manager.recognizedDevices.map(\.name), ["Test Headphones"])
        XCTAssertEqual(manager.recognizedDevices.first?.providerID, provider.providerID)
    }

    func testExactANCRequestsRecoveredFromAPK() {
        XCTAssertEqual(BWRPC.request(BWRPCatalog.ancGet).hexString, "04 0B 12 01 03")
        XCTAssertEqual(
            BWRPC.request(BWRPCatalog.ancSet, payload: .int(0)).hexString,
            "07 0B 92 02 03 01 00 00"
        )
        XCTAssertEqual(
            BWRPC.request(BWRPCatalog.ancSet, payload: .int(1)).hexString,
            "07 0B 92 02 03 01 00 01"
        )
        XCTAssertEqual(
            BWRPC.request(BWRPCatalog.ancSet, payload: .int(2)).hexString,
            "07 0B 92 02 03 01 00 02"
        )
    }

    func testFlatFiveBandEQRequest() {
        let payload = MessagePackValue.array(Array(repeating: .int(0), count: 5))
        XCTAssertEqual(
            BWRPC.request(BWRPCatalog.eqSet, payload: payload).hexString,
            "0C 0B 92 29 04 06 00 95 00 00 00 00 00"
        )
    }

    func testSpatialAudioRequests() {
        XCTAssertEqual(
            BWRPC.request(BWRPCatalog.spatialEnabledSet, payload: .bool(true)).hexString,
            "07 0B 92 2D 04 01 00 C3"
        )
        XCTAssertEqual(
            BWRPC.request(BWRPCatalog.spatialPresetSet, payload: .int(2)).hexString,
            "07 0B 92 2F 04 01 00 02"
        )
    }

    func testSignedEQValuesRoundTrip() throws {
        let value = MessagePackValue.array([.int(-60), .int(-1), .int(0), .int(31), .int(60)])
        let encoded = MessagePack.encode(value)
        XCTAssertEqual(try MessagePack.decode(encoded), value)
    }

    func testResponseAndNotificationDecode() throws {
        let response = try BWRPC.decode(Data([0x0C, 0x92, 0x01, 0x03, 0, 0, 1, 0, 1]))
        XCTAssertEqual(response.command, BWRPCatalog.ancGet)
        XCTAssertEqual(response.payload?.intValue, 1)
        XCTAssertEqual(response.errorCode, 0)

        let notification = try BWRPC.decode(Data([0x0D, 0x92, 0x01, 0x03, 1, 0, 2]))
        XCTAssertEqual(notification.command, BWRPCatalog.ancGet)
        XCTAssertEqual(notification.payload?.intValue, 2)
    }

    func testMessagePackCompositeValues() throws {
        let value = MessagePackValue.map([
            "enabled": .bool(true),
            "name": .string("Px7 S3"),
            "values": .array([.uint(255), .double(44_100)]),
        ])
        XCTAssertEqual(try MessagePack.decode(MessagePack.encode(value)), value)
    }

    func testMessagePackRejectsUnboundedCollectionsNestingAndTrailingBytes() {
        XCTAssertThrowsError(try MessagePack.decode(Data([0xDD, 0xFF, 0xFF, 0xFF, 0xFF]))) { error in
            guard case MessagePackError.collectionTooLarge = error else {
                return XCTFail("Expected collectionTooLarge, received \(error)")
            }
        }

        XCTAssertThrowsError(try MessagePack.decode(Data(Array(repeating: 0x91, count: 66) + [0xC0]))) { error in
            guard case MessagePackError.nestingTooDeep = error else {
                return XCTFail("Expected nestingTooDeep, received \(error)")
            }
        }

        XCTAssertThrowsError(try MessagePack.decode(Data([0xC0, 0xC0]))) { error in
            guard case MessagePackError.trailingBytes = error else {
                return XCTFail("Expected trailingBytes, received \(error)")
            }
        }
    }

    @MainActor
    func testAudioAndBLEDeviceNameMatching() {
        XCTAssertTrue(BowersWilkinsProvider.deviceNamesMatch("Px7 S3", "PX7-S3"))
        XCTAssertTrue(BowersWilkinsProvider.deviceNamesMatch("Bowers & Wilkins Px7 S3", "Px7 S3"))
        XCTAssertFalse(BowersWilkinsProvider.deviceNamesMatch("AirPods Pro", "Px7 S3"))
        XCTAssertFalse(BowersWilkinsProvider.deviceNamesMatch("Px8", "Px7 S3"))
        XCTAssertTrue(BowersWilkinsProvider.isSupportedHeadphoneName("Px7 S3"))
        XCTAssertTrue(BowersWilkinsProvider.isSupportedHeadphoneName("Bowers & Wilkins Px8"))
        XCTAssertTrue(BowersWilkinsProvider.isSupportedHeadphoneName("Pi5 S2"))
        XCTAssertTrue(BowersWilkinsProvider.isSupportedHeadphoneName("Pi8"))
        XCTAssertFalse(BowersWilkinsProvider.isSupportedHeadphoneName("P5 Wireless"))
        XCTAssertFalse(BowersWilkinsProvider.isSupportedHeadphoneName("Bowers & Wilkins Zeppelin"))
    }

    func testBowersWilkinsWriteQueueIsBoundedAndCoalescesPendingCommands() {
        var queue = BWRPCWriteQueue(capacity: 2)
        let firstANC = BWRPCPendingWrite(
            commandKey: "03:02",
            commandName: "ANC one",
            data: Data([1])
        )
        let battery = BWRPCPendingWrite(
            commandKey: "08:0C",
            commandName: "Battery",
            data: Data([2])
        )
        let latestANC = BWRPCPendingWrite(
            commandKey: "03:02",
            commandName: "ANC two",
            data: Data([3])
        )
        let overflow = BWRPCPendingWrite(
            commandKey: "04:29",
            commandName: "EQ",
            data: Data([4])
        )

        XCTAssertEqual(queue.enqueue(firstANC), .appended)
        XCTAssertEqual(queue.enqueue(battery), .appended)
        XCTAssertEqual(queue.enqueue(latestANC), .replaced)
        XCTAssertEqual(queue.enqueue(overflow), .rejectedFull)
        XCTAssertEqual(queue.items.count, 2)
        XCTAssertEqual(queue.popFirst(), latestANC)
        XCTAssertEqual(queue.popFirst(), battery)
        XCTAssertNil(queue.popFirst())
    }

    func testBowersWilkinsTransportRequiresConfirmedResponseNotifications() {
        var readiness = BWRPCTransportReadiness(
            requestDiscovered: true,
            responseDiscovered: true,
            responseNotificationsConfirmed: false
        )
        XCTAssertFalse(readiness.isReady)

        readiness.responseNotificationsConfirmed = true
        XCTAssertTrue(readiness.isReady)
    }

    func testBowersWilkinsPeripheralSessionRejectsStaleGenerationAndWrongIdentity() {
        let peripheralID = UUID()
        let identity = BWPeripheralSessionIdentity(peripheralID: peripheralID, generation: 7)

        XCTAssertTrue(identity.accepts(peripheralID: peripheralID, generation: 7))
        XCTAssertFalse(identity.accepts(peripheralID: peripheralID, generation: 6))
        XCTAssertFalse(identity.accepts(peripheralID: UUID(), generation: 7))
    }

    func testBowersWilkinsBluetoothRadioTransitionAllowsSamePeripheralToReconnect() {
        let peripheralID = UUID()
        var tracker = BWAutomaticConnectionTracker()
        tracker.markAttempted(peripheralID)
        tracker.reconnectAttempt = 2
        tracker.isSuppressed = true

        tracker.resetForBluetoothRadioTransition()

        XCTAssertFalse(tracker.hasAttempted(peripheralID))
        XCTAssertEqual(tracker.reconnectAttempt, 0)
        XCTAssertFalse(tracker.isSuppressed)
    }

    func testBatteryMenuBarModes() {
        XCTAssertFalse(BatteryDisplayMode.never.shouldDisplay(level: 10))
        XCTAssertTrue(BatteryDisplayMode.low.shouldDisplay(level: 19))
        XCTAssertFalse(BatteryDisplayMode.low.shouldDisplay(level: 20))
        XCTAssertTrue(BatteryDisplayMode.always.shouldDisplay(level: 100))
        XCTAssertFalse(BatteryDisplayMode.always.shouldDisplay(level: nil))
        XCTAssertEqual(HeadphoneBatterySymbol.name(for: 0), "battery.0percent")
        XCTAssertEqual(HeadphoneBatterySymbol.name(for: 13), "battery.25percent")
        XCTAssertEqual(HeadphoneBatterySymbol.name(for: 38), "battery.50percent")
        XCTAssertEqual(HeadphoneBatterySymbol.name(for: 63), "battery.75percent")
        XCTAssertEqual(HeadphoneBatterySymbol.name(for: 88), "battery.100percent")
        XCTAssertEqual(HeadphoneBatterySymbol.name(for: 250), "battery.100percent")
    }

    @MainActor
    func testVolumeSynchronizationPreferencesAreProviderScopedAndMigrateSonyValue() {
        let suiteName = "HeadBridgeTests.Settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "SonyVolumeSync")

        let settings = AppSettings(defaults: defaults)
        settings.registerVolumeSynchronization(providerID: "sony-mdr", defaultEnabled: true)
        settings.registerVolumeSynchronization(providerID: "future-provider", defaultEnabled: true)

        XCTAssertFalse(settings.volumeSynchronizationEnabled(for: "sony-mdr"))
        XCTAssertTrue(settings.volumeSynchronizationEnabled(for: "future-provider"))
        XCTAssertNil(defaults.object(forKey: "SonyVolumeSync"))
        XCTAssertEqual(defaults.object(forKey: "VolumeSyncEnabled.sony-mdr") as? Bool, false)

        settings.setVolumeSynchronizationEnabled(false, for: "future-provider")
        XCTAssertFalse(settings.volumeSynchronizationEnabled(for: "future-provider"))
        XCTAssertEqual(defaults.object(forKey: "VolumeSyncEnabled.future-provider") as? Bool, false)
    }

    @MainActor
    func testBatteryHistoryIsPersistentAndIsolatedPerDevice() {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeadBridgeBatteryHistory-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let start = Date()
        var store: BatteryHistoryStore? = BatteryHistoryStore(
            providers: [],
            storageURL: storageURL,
            samplingInterval: 300,
            now: { start }
        )
        store?.recordSample(
            providerID: "sony-mdr",
            deviceID: "AA:BB",
            displayName: "WH-1000XM3",
            vendorName: "Sony",
            level: 80,
            isCharging: false,
            at: start
        )
        store?.recordSample(
            providerID: "sony-mdr",
            deviceID: "AA:BB",
            displayName: "WH-1000XM3",
            vendorName: "Sony",
            level: 80,
            isCharging: false,
            at: start.addingTimeInterval(60)
        )
        store?.recordSample(
            providerID: "sony-mdr",
            deviceID: "AA:BB",
            displayName: "WH-1000XM3",
            vendorName: "Sony",
            level: 80,
            isCharging: false,
            at: start.addingTimeInterval(300)
        )
        store?.recordSample(
            providerID: "sony-mdr",
            deviceID: "CC:DD",
            displayName: "WH-1000XM3",
            vendorName: "Sony",
            level: 55,
            isCharging: true,
            at: start.addingTimeInterval(300)
        )

        let firstSession = store?.history(providerID: "sony-mdr", deviceID: "aa:bb")?
            .samples.last?.sessionID
        XCTAssertEqual(
            store?.history(providerID: "sony-mdr", deviceID: "AA:BB")?.samples.count,
            2,
            "An unchanged value inside the five-minute interval must be coalesced"
        )
        XCTAssertEqual(
            store?.history(providerID: "sony-mdr", deviceID: "CC:DD")?.samples.count,
            1
        )

        store?.endSession(providerID: "sony-mdr", deviceID: "AA:BB")
        store?.recordSample(
            providerID: "sony-mdr",
            deviceID: "AA:BB",
            displayName: "WH-1000XM3",
            vendorName: "Sony",
            level: 79,
            isCharging: false,
            at: start.addingTimeInterval(600)
        )
        XCTAssertNotEqual(
            firstSession,
            store?.history(providerID: "sony-mdr", deviceID: "AA:BB")?.samples.last?.sessionID
        )

        store = nil
        let restored = BatteryHistoryStore(
            providers: [],
            storageURL: storageURL,
            samplingInterval: 300,
            now: { start.addingTimeInterval(600) }
        )
        XCTAssertEqual(
            restored.history(providerID: "sony-mdr", deviceID: "AA:BB")?.samples.map(\.level),
            [80, 80, 79]
        )
        XCTAssertEqual(
            restored.history(providerID: "sony-mdr", deviceID: "CC:DD")?.latestSample?.level,
            55
        )
        let attributes = try? FileManager.default.attributesOfItem(atPath: storageURL.path)
        XCTAssertEqual((attributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        restored.clearHistory(providerID: "sony-mdr", deviceID: "AA:BB")
        XCTAssertNil(restored.history(providerID: "sony-mdr", deviceID: "AA:BB"))
        XCTAssertNotNil(restored.history(providerID: "sony-mdr", deviceID: "CC:DD"))
        restored.clearAllHistory()
        XCTAssertTrue(restored.histories.isEmpty)
    }

    @MainActor
    func testBowersWilkinsPersistentHardwareIdentifier() {
        XCTAssertEqual(
            BowersWilkinsProvider.persistentDeviceIdentifier(
                macAddress: "0xAA BB CC DD EE FF",
                serialNumber: "SERIAL-IGNORED"
            ),
            "mac:aa:bb:cc:dd:ee:ff"
        )
        XCTAssertEqual(
            BowersWilkinsProvider.persistentDeviceIdentifier(
                macAddress: "—",
                serialNumber: "PX7-1234"
            ),
            "serial:px7-1234"
        )
        XCTAssertNil(
            BowersWilkinsProvider.persistentDeviceIdentifier(
                macAddress: "—",
                serialNumber: "—"
            ))
    }

    @MainActor
    func testRestoreProfilesAreIsolatedByProviderAndDevice() {
        struct Profile: Codable, Equatable { let mode: Int }
        let suiteName = "HeadBridgeTests.Restore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(HeadphoneProfileStore.isRestoreEnabled(for: "sony", defaults: defaults))
        HeadphoneProfileStore.setRestoreEnabled(true, for: "sony", defaults: defaults)
        XCTAssertTrue(HeadphoneProfileStore.isRestoreEnabled(for: "sony", defaults: defaults))
        XCTAssertFalse(HeadphoneProfileStore.isRestoreEnabled(for: "bw", defaults: defaults))

        HeadphoneProfileStore.save(
            Profile(mode: 2),
            providerID: "sony",
            deviceID: "AA:BB",
            defaults: defaults
        )
        XCTAssertEqual(
            HeadphoneProfileStore.load(
                Profile.self,
                providerID: "sony",
                deviceID: "aa:bb",
                defaults: defaults
            ),
            Profile(mode: 2)
        )
        XCTAssertNil(
            HeadphoneProfileStore.load(
                Profile.self,
                providerID: "sony",
                deviceID: "CC:DD",
                defaults: defaults
            ))
    }

    @MainActor
    func testSonyDiscoveryAndVolumeMapping() {
        XCTAssertTrue(SonyMDRProvider.isSupportedHeadphoneName("WH-1000XM3"))
        XCTAssertTrue(SonyMDRProvider.isSupportedHeadphoneName("WH-CH720N"))
        XCTAssertTrue(SonyMDRProvider.isSupportedHeadphoneName("MDR-XB950BT"))
        XCTAssertTrue(SonyMDRProvider.isSupportedHeadphoneName("LinkBuds S"))
        XCTAssertTrue(SonyMDRProvider.isSupportedHeadphoneName("Sony Headphones"))
        XCTAssertFalse(SonyMDRProvider.isSupportedHeadphoneName("Px7 S3"))
        XCTAssertEqual(SonyMDRProvider.volumeStep(for: -1), 0)
        XCTAssertEqual(SonyMDRProvider.volumeStep(for: 0.5), 15)
        XCTAssertEqual(SonyMDRProvider.volumeStep(for: 2), 30)
    }

    func testSonyMDRFramingRoundTripWithEscapedMarkers() {
        let original = SonyMDRPacket(
            dataType: SonyMDRPacket.commandType,
            sequence: 1,
            payload: [0x3C, 0x3D, 0x3E, 0x00]
        )
        let encoded = SonyMDRFraming.encode(original)
        let parser = SonyMDRFrameParser()
        let split = encoded.count / 2

        XCTAssertTrue(parser.append(encoded.prefix(split)).isEmpty)
        XCTAssertEqual(parser.append(encoded.suffix(from: split)), [original])
    }

    func testSonyMDRParserResynchronizesAfterOversizedFrame() {
        let parser = SonyMDRFrameParser(maximumPayloadLength: 2)
        XCTAssertTrue(parser.append(Data([SonyMDRFraming.startMarker] + Array(repeating: 0, count: 10))).isEmpty)

        let expected = SonyMDRPacket(
            dataType: SonyMDRPacket.commandType,
            sequence: 0,
            payload: [SonyV1Opcode.batteryGet, 0x00]
        )
        XCTAssertEqual(parser.append(SonyMDRFraming.encode(expected)), [expected])
    }

    func testSonyProtocolVersionDetectionUsesInitReplyShape() {
        XCTAssertEqual(
            SonyMDRProtocolVersion.detect(fromInitReply: [0x01, 0x00, 0x40, 0x10]),
            .v1
        )
        XCTAssertEqual(
            SonyMDRProtocolVersion.detect(
                fromInitReply: [0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00]
            ),
            .v2
        )
        XCTAssertNil(SonyMDRProtocolVersion.detect(fromInitReply: [0x01, 0x00]))
    }

    func testSonyV1ProfilesDescribeFeaturesInsteadOfProviderIdentity() {
        let xm2 = SonyV1DeviceProfile(deviceName: "WH-1000XM2")
        let xm3 = SonyV1DeviceProfile(deviceName: "WH-1000XM3")
        let xm4 = SonyV1DeviceProfile(deviceName: "WH-1000XM4")
        let unknown = SonyV1DeviceProfile(deviceName: "Sony MDR V1 Headphones")

        XCTAssertTrue(xm2.features.contains(.virtualSound))
        XCTAssertFalse(xm2.features.contains(.touchSensor))
        XCTAssertTrue(xm3.features.contains(.touchSensor))
        XCTAssertTrue(xm3.features.contains(.soundQualityMode))
        XCTAssertTrue(xm4.features.contains(.equalizer))
        XCTAssertFalse(xm4.features.contains(.virtualSound))
        XCTAssertTrue(unknown.features.isEmpty)
    }

    func testSonyMDRParserRejectsBadChecksum() {
        var encoded = [UInt8](
            SonyMDRFraming.encode(
                SonyMDRPacket(
                    dataType: SonyMDRPacket.commandType,
                    sequence: 0,
                    payload: [SonyV1Opcode.batteryGet, 0x00]
                )))
        encoded[encoded.count - 2] ^= 0x01
        XCTAssertTrue(SonyMDRFrameParser().append(Data(encoded)).isEmpty)
    }

    func testSonyXM3CombinedNoiseProfilePackets() {
        let profile = SonyV1DeviceProfile(deviceName: "WH-1000XM3")
        func frame(_ mode: SonyV1NoiseMode, level: Int = 20) -> String {
            SonyMDRFraming.encode(
                SonyMDRPacket(
                    dataType: SonyMDRPacket.commandType,
                    sequence: 1,
                    payload: profile.noisePayload(
                        mode: mode,
                        ambientLevel: level,
                        reportedNCType: 0x02,
                        reportedASMType: 0x01,
                        reportedASMID: 0x00
                    )
                )
            ).hexString
        }

        XCTAssertEqual(
            frame(.ambient),
            "3E 0C 01 00 00 00 08 68 02 11 02 00 01 00 14 A7 3C"
        )
        XCTAssertEqual(
            frame(.noiseCancellation),
            "3E 0C 01 00 00 00 08 68 02 11 02 02 01 00 00 95 3C"
        )
        XCTAssertEqual(
            frame(.windReduction),
            "3E 0C 01 00 00 00 08 68 02 11 02 01 01 00 00 94 3C"
        )
        XCTAssertEqual(
            frame(.off),
            "3E 0C 01 00 00 00 08 68 02 00 02 00 01 00 00 82 3C"
        )
    }

    func testSonyWindReductionIsDistinctFromAmbientLevelOne() {
        XCTAssertEqual(
            SonyV1NoiseMode.decode(effect: 0x11, ncSettingType: 0x02, ncValue: 0x01, ambientLevel: 0),
            .windReduction
        )
        XCTAssertEqual(
            SonyV1NoiseMode.decode(effect: 0x11, ncSettingType: 0x02, ncValue: 0x00, ambientLevel: 1),
            .ambient
        )
        XCTAssertEqual(
            SonyV1NoiseMode.decode(effect: 0x11, ncSettingType: 0x00, ncValue: 0x01, ambientLevel: 0),
            .noiseCancellation
        )
    }

    func testSonyXM3VolumePacket() {
        let packet = SonyMDRPacket(
            dataType: SonyMDRPacket.commandType,
            sequence: 0,
            payload: [SonyV1Opcode.playbackSet, 0x01, 0x20, 0x07]
        )
        XCTAssertEqual(
            SonyMDRFraming.encode(packet).hexString,
            "3E 0C 00 00 00 00 04 A8 01 20 07 E0 3C"
        )
    }

    func testSonyXM3ExtendedControlPayloads() {
        XCTAssertEqual(
            SonyV1Payloads.equalizerPreset(.bassBoost),
            [0x58, 0x01, 0x16, 0x00]
        )
        XCTAssertEqual(
            SonyV1Payloads.equalizerBands([-10, -5, 0, 5, 10, 3]),
            [0x58, 0x01, 0xFF, 0x06, 13, 0, 5, 10, 15, 20]
        )
        XCTAssertEqual(SonyV1Payloads.surroundMode(.concertHall), [0x48, 0x01, 0x03])
        XCTAssertEqual(SonyV1Payloads.soundPosition(.rearRight), [0x48, 0x02, 0x12])
        XCTAssertEqual(SonyV1Payloads.dsee(enabled: true), [0xE8, 0x02, 0x00, 0x01])
        XCTAssertEqual(
            SonyV1Payloads.soundQuality(.prioritizeStableConnection),
            [0xE8, 0x01, 0x00, 0x01]
        )
        XCTAssertEqual(SonyV1Payloads.touchSensor(enabled: false), [0xD8, 0xD2, 0x01, 0x00])
        XCTAssertEqual(SonyV1Payloads.optimizer(start: true), [0x84, 0x01, 0x00, 0x01])
        XCTAssertEqual(
            SonyV1Payloads.automaticPowerOff(.after30Minutes),
            [0xF8, 0x04, 0x01, 0x01, 0x01]
        )
    }

    func testSonyXM3ExtendedControlCodeMapping() {
        XCTAssertEqual(SonyV1EqualizerPreset(rawValue: 0xA2), .custom2)
        XCTAssertEqual(SonyV1AutomaticPowerOff(first: 0x02, second: 0x02), .after1Hour)
        XCTAssertEqual(SonyV1SoundQualityMode(rawValue: 0x00), .prioritizeSoundQuality)
        XCTAssertTrue(SonyV1OptimizerStatus.analyzing.isRunning)
        XCTAssertFalse(SonyV1OptimizerStatus.finished.isRunning)
    }
}

@MainActor
private final class TestHeadphoneProvider: ObservableObject, HeadphoneProvider {
    let providerID = "test-provider"
    let vendorName = "Test"
    let connectedDeviceID: String? = "test-device"
    @Published private(set) var connectionState = HeadphoneConnectionState.idle
    @Published private(set) var connectedName = "Test Headphones"
    let batteryPercent: Int? = 50
    let isCharging: Bool? = false
    let codecName: String? = "AAC"
    let capabilities: HeadphoneCapabilities = [.battery]
    let noiseMode: HeadphoneNoiseMode? = nil
    let supportedNoiseModes: [HeadphoneNoiseMode] = []
    let restoreOnConnectEnabled = false
    private(set) var disconnectCallCount = 0

    var connectionStatePublisher: AnyPublisher<HeadphoneConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    func rename(_ name: String) {
        connectedName = name
    }

    func connect(name: String) {
        connectedName = name
        connectionState = .ready
    }

    func matches(audioDevice: SystemAudioDevice) -> Bool { false }
    func recognizesBluetoothDevice(named name: String) -> Bool { name == "Test Headphones" }
    func updateAudioConnectedDevices(_ devices: [SystemAudioDevice]) {}
    func refresh() {}
    func disconnect() { disconnectCallCount += 1 }
    func setNoiseMode(_ mode: HeadphoneNoiseMode) {}
    func setRestoreOnConnectEnabled(_ enabled: Bool) {}
}
