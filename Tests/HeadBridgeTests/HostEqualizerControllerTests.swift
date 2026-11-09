import AppKit
import Combine
import CoreAudio
import XCTest
@testable import HeadBridge

@MainActor
final class HostEqualizerControllerTests: XCTestCase {
    func testNonPx8DefaultOutputDoesNotStartSession() async {
        for name in ["Speakers", "Px8 S2", "Bowers & Wilkins Px7 S3", "LE_BWHP"] {
            let fixture = Fixture()
            defer { fixture.shutdown() }
            let output = SystemAudioDevice(
                id: 103, uid: "test-other", name: name, transportType: kAudioDeviceTransportTypeBluetooth)
            fixture.devices.send([fixture.px8, output])
            fixture.output.send(output.id)
            let previous = fixture.equalizer.reconcileCount
            fixture.settings.setHostEQEnabled(true)
            await until { fixture.equalizer.reconcileCount > previous }
            XCTAssertEqual(fixture.equalizer.state, .waiting, name)
            XCTAssertTrue(fixture.startedUIDs.isEmpty, name)
        }
    }

    func testOriginalPx8NamesStartSessionWithoutProviderIdentity() async {
        for name in ["Px8", "Bowers & Wilkins Px8"] {
            let fixture = Fixture()
            defer { fixture.shutdown() }
            let output = SystemAudioDevice(
                id: fixture.px8.id, uid: fixture.px8.uid, name: name,
                transportType: kAudioDeviceTransportTypeBluetooth)
            fixture.devices.send([output, fixture.speakers])
            fixture.settings.setHostEQEnabled(true)
            await until { fixture.equalizer.state == .active(sampleRate: 48000) }
            XCTAssertEqual(fixture.startedUIDs, [output.uid], name)
            XCTAssertEqual(fixture.equalizer.state, .active(sampleRate: 48000), name)
        }
    }

    func testEnabledPx8DefaultStartsOneSessionForUID() async {
        let fixture = Fixture()
        defer { fixture.shutdown() }
        var previous = fixture.equalizer.reconcileCount
        fixture.settings.setHostEQEnabled(true)
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.equalizer.state == .active(sampleRate: 48000) }
        previous = fixture.equalizer.reconcileCount
        fixture.equalizer.reconcile()
        await until { fixture.equalizer.reconcileCount > previous }
        XCTAssertEqual(fixture.startedUIDs, [fixture.px8.uid])
        XCTAssertEqual(fixture.equalizer.state, .active(sampleRate: 48000))
        XCTAssertEqual(fixture.equalizer.preGainDB, 0)
    }

    func testSwitchingOutputAwayStopsAndWaits() async {
        let fixture = Fixture()
        defer { fixture.shutdown() }
        var previous = fixture.equalizer.reconcileCount
        fixture.settings.setHostEQEnabled(true)
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.equalizer.state == .active(sampleRate: 48000) }
        previous = fixture.equalizer.reconcileCount
        fixture.output.send(fixture.speakers.id)
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.equalizer.state == .waiting }
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertEqual(fixture.equalizer.state, .waiting)
        XCTAssertEqual(fixture.startedUIDs.count, 1)
    }

    func testDisablingStopsAndTurnsOff() async {
        let fixture = Fixture()
        defer { fixture.shutdown() }
        var previous = fixture.equalizer.reconcileCount
        fixture.settings.setHostEQEnabled(true)
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.equalizer.state == .active(sampleRate: 48000) }
        previous = fixture.equalizer.reconcileCount
        fixture.settings.setHostEQEnabled(false)
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.equalizer.state == .off }
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertEqual(fixture.equalizer.state, .off)
    }

    func testFailureDoesNotRetryUntilRequested() async {
        let fixture = Fixture()
        defer { fixture.shutdown() }
        var attempts = 0
        fixture.equalizer.makeSession = { _ in
            attempts += 1
            throw EQSession.Failure.message("Denied")
        }
        var previous = fixture.equalizer.reconcileCount
        fixture.settings.setHostEQEnabled(true)
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.equalizer.state == .failed("Denied") }
        XCTAssertEqual(fixture.equalizer.state, .failed("Denied"))
        previous = fixture.equalizer.reconcileCount
        fixture.equalizer.reconcile()
        await until { fixture.equalizer.reconcileCount > previous }
        previous = fixture.equalizer.reconcileCount
        fixture.settings.setHostEQGain(band: 0, dB: 1)
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.equalizer.state == .failed("Denied") }
        XCTAssertEqual(attempts, 1)
        previous = fixture.equalizer.reconcileCount
        fixture.equalizer.retry()
        await until { fixture.equalizer.reconcileCount > previous }
        await until { attempts == 2 && fixture.equalizer.state == .failed("Denied") }
        XCTAssertEqual(attempts, 2)
    }

    func testSleepStopsAndWakeRestarts() async {
        let fixture = Fixture()
        defer { fixture.shutdown() }
        var previous = fixture.equalizer.reconcileCount
        fixture.settings.setHostEQEnabled(true)
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.equalizer.state == .active(sampleRate: 48000) }
        previous = fixture.equalizer.reconcileCount
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.equalizer.state == .waiting }
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertEqual(fixture.equalizer.state, .waiting)
        previous = fixture.equalizer.reconcileCount
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.startedUIDs.count == 2 && fixture.equalizer.state == .active(sampleRate: 48000) }
        XCTAssertEqual(fixture.startedUIDs, [fixture.px8.uid, fixture.px8.uid])
        XCTAssertEqual(fixture.equalizer.state, .active(sampleRate: 48000))
    }

    func testLatestSettingsAreAppliedOnceAtSessionSampleRate() async {
        let fixture = Fixture()
        defer { fixture.shutdown() }
        var previous = fixture.equalizer.reconcileCount
        fixture.settings.setHostEQEnabled(true)
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.equalizer.state == .active(sampleRate: 48000) }
        let processor = fixture.equalizer.processor
        let sequence = processor._configurationSequence
        previous = fixture.equalizer.reconcileCount
        fixture.settings.setHostEQGain(band: 9, dB: 3)
        fixture.settings.setHostEQGain(band: 9, dB: 6)
        await until { fixture.equalizer.reconcileCount > previous + 1 }
        await until { processor._configurationSequence > sequence }
        previous = fixture.equalizer.reconcileCount
        fixture.equalizer.reconcile()
        await until { fixture.equalizer.reconcileCount > previous }
        XCTAssertEqual(processor._configurationSequence, sequence + 1)
        let expected = EQDesign.preGain(for: EQDesign.cascade(fixture.settings.hostEQSettings, sampleRate: 48000))
        XCTAssertEqual(processor.preGain, expected)
        XCTAssertEqual(fixture.equalizer.preGainDB, 20 * log10(Double(expected)), accuracy: 1e-9)
        XCTAssertEqual(fixture.startedUIDs.count, 1)
    }

    func testStaleStartStopsWithoutActivation() async {
        let fixture = Fixture()
        defer { fixture.shutdown() }
        var activations = 0
        let subscription = fixture.equalizer.$state.sink {
            if case .active = $0 { activations += 1 }
        }
        defer { subscription.cancel() }
        var completion: CheckedContinuation<EQSession, Never>?
        fixture.equalizer.makeSession = { _ in
            await withCheckedContinuation { completion = $0 }
        }
        var previous = fixture.equalizer.reconcileCount
        fixture.settings.setHostEQEnabled(true)
        await until { fixture.equalizer.reconcileCount > previous }
        await until { completion != nil }
        XCTAssertNotNil(completion)
        previous = fixture.equalizer.reconcileCount
        fixture.settings.setHostEQEnabled(false)
        fixture.equalizer.reconcile()
        await until { fixture.equalizer.reconcileCount > previous }
        XCTAssertEqual(fixture.equalizer.state, .waiting)
        previous = fixture.equalizer.reconcileCount
        completion?.resume(returning: EQSession(sampleRate: 44100) { fixture.stops += 1 })
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.equalizer.state == .off }
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(fixture.equalizer.state, .off)
    }

    func testStaleStartReconcilesReturnedPx8Default() async {
        let fixture = Fixture()
        defer { fixture.shutdown() }
        var completion: CheckedContinuation<EQSession, Never>?
        fixture.equalizer.makeSession = { uid in
            fixture.startedUIDs.append(uid)
            if fixture.startedUIDs.count == 1 {
                return await withCheckedContinuation { completion = $0 }
            }
            return EQSession(sampleRate: 48000) { fixture.stops += 1 }
        }
        var previous = fixture.equalizer.reconcileCount
        fixture.settings.setHostEQEnabled(true)
        await until { fixture.equalizer.reconcileCount > previous && completion != nil }
        previous = fixture.equalizer.reconcileCount
        fixture.output.send(fixture.speakers.id)
        await until { fixture.equalizer.reconcileCount > previous }
        previous = fixture.equalizer.reconcileCount
        fixture.output.send(fixture.px8.id)
        await until { fixture.equalizer.reconcileCount > previous }
        previous = fixture.equalizer.reconcileCount
        completion?.resume(returning: EQSession(sampleRate: 44100) { fixture.stops += 1 })
        await until {
            fixture.equalizer.reconcileCount > previous
                && fixture.equalizer.state == .active(sampleRate: 48000)
        }
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertEqual(fixture.startedUIDs, [fixture.px8.uid, fixture.px8.uid])
        XCTAssertEqual(fixture.equalizer.state, .active(sampleRate: 48000))
    }

    func testShutdownPreventsRestart() async {
        let fixture = Fixture()
        defer { fixture.shutdown() }
        var previous = fixture.equalizer.reconcileCount
        fixture.settings.setHostEQEnabled(true)
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.equalizer.state == .active(sampleRate: 48000) }
        fixture.equalizer.shutdown()
        previous = fixture.equalizer.reconcileCount
        fixture.equalizer.reconcile()
        await until { fixture.equalizer.reconcileCount > previous }
        await until { fixture.equalizer.state == .off }
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertEqual(fixture.equalizer.state, .off)
        XCTAssertEqual(fixture.startedUIDs.count, 1)
    }

    func testAppSettingsEqualizerRoundTripClampsAndSnaps() {
        let fixture = Fixture()
        defer { fixture.shutdown() }
        XCTAssertFalse(fixture.settings.hostEQEnabled)
        XCTAssertEqual(fixture.settings.hostEQSettings, .flat)
        fixture.settings.setHostEQGain(band: 0, dB: 9)
        fixture.settings.setHostEQGain(band: 1, dB: -9)
        fixture.settings.setHostEQGain(band: 2, dB: 1.26)
        fixture.settings.setHostEQGain(band: 10, dB: 4)
        fixture.settings.setHostEQGain(band: 3, dB: .nan)
        fixture.settings.setHostEQEnabled(true)
        let restored = AppSettings(defaults: fixture.defaults)
        XCTAssertTrue(restored.hostEQEnabled)
        XCTAssertEqual(restored.hostEQSettings.gainsDB, [6, -6, 1.5, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(fixture.defaults.array(forKey: "HostEQBandGains") as? [Double], restored.hostEQSettings.gainsDB)
        XCTAssertTrue(fixture.defaults.bool(forKey: "HostEQEnabled"))
        restored.setHostEQSettings(.flat)
        XCTAssertEqual(AppSettings(defaults: fixture.defaults).hostEQSettings, .flat)
    }

    func testInvalidStoredGainsResetAndDisable() {
        let fixture = Fixture()
        defer { fixture.shutdown() }
        for gains in [
            [Double](repeating: 0, count: 9), [Double](repeating: 0.3, count: 10),
            [Double](repeating: 7, count: 10),
        ] {
            fixture.defaults.set(true, forKey: "HostEQEnabled")
            fixture.defaults.set(gains, forKey: "HostEQBandGains")
            let restored = AppSettings(defaults: fixture.defaults)
            XCTAssertFalse(restored.hostEQEnabled)
            XCTAssertEqual(restored.hostEQSettings, .flat)
            XCTAssertFalse(fixture.defaults.bool(forKey: "HostEQEnabled"))
            XCTAssertEqual(fixture.defaults.array(forKey: "HostEQBandGains") as? [Double], EQSettings.flat.gainsDB)
        }
    }

    private func until(
        _ condition: @MainActor () -> Bool, timeout: Duration = .seconds(1),
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for transition", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    private final class Fixture {
        let suite = "HeadBridgeEQTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let settings: AppSettings
        let px8 = SystemAudioDevice(
            id: 101, uid: "test-px8", name: "Px8", transportType: kAudioDeviceTransportTypeBluetooth)
        let speakers = SystemAudioDevice(
            id: 102, uid: "test-speakers", name: "Speakers", transportType: kAudioDeviceTransportTypeBuiltIn)
        let devices: CurrentValueSubject<[SystemAudioDevice], Never>
        let output: CurrentValueSubject<AudioDeviceID?, Never>
        let audio: SystemAudioController
        var equalizer: HostEqualizerController!
        var startedUIDs: [String] = []
        var stops = 0

        init() {
            defaults = UserDefaults(suiteName: suite)!
            settings = AppSettings(defaults: defaults)
            devices = CurrentValueSubject([px8, speakers])
            output = CurrentValueSubject(px8.id)
            audio = SystemAudioController(devices: devices, defaultDeviceID: output)
            equalizer = HostEqualizerController(
                settings: settings, systemAudio: audio,
                makeSession: { [weak self] uid in
                    self?.startedUIDs.append(uid)
                    return EQSession(sampleRate: 48000) { [weak self] in self?.stops += 1 }
                })
        }

        func shutdown() {
            equalizer.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
