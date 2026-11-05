import AppKit
import AudioToolbox
import Combine
import CoreAudio
import os

@MainActor
final class HostEqualizerController: ObservableObject {
    enum State: Equatable {
        case off, waiting, active(sampleRate: Double), failed(String)
    }

    @Published private(set) var state: State = .off
    @Published private(set) var preGainDB: Double = 0
    internal private(set) var reconcileCount: Int = 0
    internal lazy var makeSession: (String) async throws -> EQSession = { [weak self] uid in
        guard let self, let device = self.systemAudio.devices.first(where: { $0.uid == uid }) else {
            throw EQSession.Failure.message("The Px8 output is unavailable")
        }
        let processor = self.processor
        let token = self.generation
        let task = Task.detached {
            try await EQSession(
                device: device, processor: processor,
                isCurrent: { [weak self] in
                    self?.generation == token && self?.isShutdown == false
                })
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    private(set) var processor = HostEqualizerProcessor()

    private let settings: AppSettings
    private let systemAudio: SystemAudioController
    private var subscriptions: Set<AnyCancellable> = []
    private var session: EQSession?
    private var activeDevice: SystemAudioDevice?
    private var startingDevice: SystemAudioDevice?
    private var startupTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var failure: String?
    private var appliedSettings: EQSettings?
    private var isAsleep = false
    private var isShutdown = false
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var bufferCheck: AnyCancellable?

    init(
        settings: AppSettings, systemAudio: SystemAudioController,
        makeSession: ((String) async throws -> EQSession)? = nil
    ) {
        self.settings = settings
        self.systemAudio = systemAudio
        if makeSession == nil, #available(macOS 14.2, *) {
            for id in SystemAudioController.allDeviceIDs()
            where SystemAudioController.stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
                == EQSession.aggregateUID
            {
                AudioHardwareDestroyAggregateDevice(id)
            }
        }
        if let makeSession { self.makeSession = makeSession }
        let changes = Publishers.MergeMany([
            settings.$hostEQEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$hostEQSettings.map { _ in () }.eraseToAnyPublisher(),
            systemAudio.$defaultDeviceID.map { _ in () }.eraseToAnyPublisher(),
            systemAudio.$devices.map { _ in () }.eraseToAnyPublisher(),
        ])
        changes.receive(on: RunLoop.main)
            .sink { [weak self] in self?.reconcile() }.store(in: &subscriptions)
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.publisher(for: NSWorkspace.willSleepNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.isAsleep = true
                self?.reconcile()
            }.store(in: &subscriptions)
        notifications.publisher(for: NSWorkspace.didWakeNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.isAsleep = false
                self?.systemAudio.refresh()
                self?.reconcile()
            }.store(in: &subscriptions)
    }

    func reconcile() {
        reconcileCount += 1
        guard !isShutdown else { return }
        let enabled = settings.hostEQEnabled
        guard stopTask == nil else { return }
        let device = systemAudio.devices.first { $0.id == systemAudio.defaultDeviceID }
        guard enabled, !isAsleep, let device, BowersWilkinsProvider.isOriginalPx8Name(device.name) else {
            stopSession()
            if !enabled { failure = nil }
            guard stopTask == nil else { return }
            state = enabled ? .waiting : .off
            return
        }
        if let failure {
            state = .failed(failure)
            return
        }
        if let session, activeDevice == device {
            applySettings(sampleRate: session.sampleRate)
            return
        }
        if let startingDevice {
            if startingDevice != device { stopSession() }
            return
        }
        stopSession()
        processor = HostEqualizerProcessor()
        startingDevice = device
        state = .waiting
        let token = generation
        startupTask = Task { [weak self, makeSession] in
            let task = self?.startupTask
            let result: Result<EQSession, Error>
            do { result = .success(try await makeSession(device.uid)) } catch { result = .failure(error) }
            guard let self else {
                if case .success(let session) = result { session.stop() }
                return
            }
            guard !Task.isCancelled, self.generation == token, !self.isShutdown,
                self.settings.hostEQEnabled, !self.isAsleep,
                self.systemAudio.devices.first(where: { $0.id == self.systemAudio.defaultDeviceID }) == device
            else {
                if case .success(let session) = result { session.stop() }
                if self.startupTask == task {
                    self.startupTask = nil
                    self.startingDevice = nil
                }
                self.reconcile()
                return
            }
            self.startupTask = nil
            self.startingDevice = nil
            do {
                let session = try result.get()
                self.session = session
                self.activeDevice = device
                self.applySettings(sampleRate: session.sampleRate)
                try self.installDeviceListeners(device.id, generation: token)
                try session.start()
                self.bufferCheck = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
                    .sink { [weak self, weak session] _ in
                        guard let self, session?.hasInvalidBuffers == true else { return }
                        self.stopSession()
                        let message = "Unsupported buffer layout"
                        self.failure = message
                        self.state = .failed(message)
                    }
                self.state = .active(sampleRate: session.sampleRate)
            } catch {
                self.stopSession()
                self.failure = error.localizedDescription
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func retry() {
        failure = nil
        reconcile()
    }

    func shutdown() {
        isShutdown = true
        subscriptions.removeAll()
        stopSession()
        if stopTask == nil { state = .off }
    }

    private func applySettings(sampleRate: Double) {
        guard appliedSettings != settings.hostEQSettings else { return }
        processor.apply(settings.hostEQSettings, sampleRate: sampleRate)
        appliedSettings = settings.hostEQSettings
        preGainDB = 20 * log10(Double(processor.preGain))
    }

    private func installDeviceListeners(_ id: AudioDeviceID, generation token: UInt64) throws {
        guard session?.usesCoreAudio == true else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            let rateChanged = (0..<Int(count)).contains {
                addresses[$0].mSelector == kAudioDevicePropertyNominalSampleRate
            }
            Task { @MainActor in
                guard let self, self.generation == token, !self.isShutdown else { return }
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsAlive,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var alive: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive)
                if rateChanged || status != noErr || alive == 0 {
                    self.stopSession()
                    self.systemAudio.refresh()
                    self.reconcile()
                }
            }
        }
        deviceListener = listener
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListenerBlock(id, &address, .main, listener)
            guard status == noErr else {
                throw EQSession.Failure.message("Could not monitor the Px8 output (Core Audio \(status))")
            }
        }
    }

    private func stopSession() {
        generation &+= 1
        bufferCheck = nil
        if let id = activeDevice?.id, let listener = deviceListener {
            for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(id, &address, .main, listener)
            }
        }
        deviceListener = nil
        session?.stop()
        session = nil
        activeDevice = nil
        appliedSettings = nil
        preGainDB = 0
        guard stopTask == nil, let startupTask else { return }
        startupTask.cancel()
        stopTask = Task {
            await startupTask.value
            self.startupTask = nil
            self.startingDevice = nil
            self.stopTask = nil
            if self.isShutdown {
                self.state = .off
            } else {
                self.reconcile()
            }
        }
    }
}

internal final class EQSession {
    static let aggregateUID = "com.headbridge.HeadBridge.eq-aggregate"
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let message) = self { return message }
            return nil
        }
    }

    let sampleRate: Double
    let usesCoreAudio: Bool
    private let processor: HostEqualizerProcessor?
    private let invalidBuffers = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var callbackFaulted = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var started = false
    private var onStop: (() -> Void)?

    var hasInvalidBuffers: Bool { invalidBuffers.withLock { $0 } }

    deinit {
        stop()
    }

    init(sampleRate: Double, onStop: @escaping () -> Void) {
        self.sampleRate = sampleRate
        self.onStop = onStop
        processor = nil
        usesCoreAudio = false
    }

    init(
        device: SystemAudioDevice, processor: HostEqualizerProcessor, isCurrent: @MainActor () -> Bool
    ) async throws {
        self.processor = processor
        usesCoreAudio = true
        guard #available(macOS 14.2, *) else {
            throw Failure.message("The equalizer requires macOS 14.2 or later")
        }
        guard let px8UID = SystemAudioController.stringProperty(device.id, selector: kAudioDevicePropertyDeviceUID),
            px8UID == device.uid
        else { throw Failure.message("The Px8 output is unavailable") }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nominalRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let rateStatus = AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &nominalRate)
        guard rateStatus == noErr, nominalRate.isFinite, nominalRate > 0 else {
            throw Failure.message("Could not read the Px8 sample rate (Core Audio \(rateStatus))")
        }
        sampleRate = nominalRate
        do {
            var ownPID = pid_t(getpid())
            var own = AudioObjectID(kAudioObjectUnknown)
            address.mSelector = kAudioHardwarePropertyTranslatePIDToProcessObject
            size = UInt32(MemoryLayout<AudioObjectID>.size)
            let processStatus = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &ownPID, &size, &own
            )
            guard processStatus == noErr, own != kAudioObjectUnknown else {
                throw Failure.message("Could not identify HeadBridge's audio process (Core Audio \(processStatus))")
            }
            let description = CATapDescription(excludingProcesses: [own], deviceUID: px8UID, stream: 0)
            description.isMixdown = false
            description.isMono = false
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            description.name = "HeadBridge EQ"
            guard !Task.isCancelled, await isCurrent() else { throw CancellationError() }
            let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
            guard !Task.isCancelled, await isCurrent() else { throw CancellationError() }
            guard tapStatus == noErr else {
                throw Failure.message(
                    "Audio tap failed (status \(tapStatus)). If macOS did not allow system audio recording, allow HeadBridge under System Settings > Privacy & Security > Screen & System Audio Recording, then retry."
                )
            }
            var format = AudioStreamBasicDescription()
            address.mSelector = kAudioTapPropertyFormat
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let formatStatus = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
            guard formatStatus == noErr, format.mSampleRate == nominalRate, format.mChannelsPerFrame == 2,
                format.mFormatID == kAudioFormatLinearPCM,
                format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                format.mFormatFlags & (kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsNonInterleaved) == 0,
                format.mBitsPerChannel == 32, format.mBytesPerFrame == 8
            else {
                throw Failure.message(
                    "Unsupported audio format: \(format.mSampleRate) Hz \(format.mChannelsPerFrame) ch")
            }
            var tapUIDReference: Unmanaged<CFString>?
            address.mSelector = kAudioTapPropertyUID
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let uidStatus = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &tapUIDReference)
            guard uidStatus == noErr, let tapUID = tapUIDReference?.takeRetainedValue() as String? else {
                throw Failure.message("Could not read the audio tap UID (Core Audio \(uidStatus))")
            }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceUIDKey: Self.aggregateUID,
                kAudioAggregateDeviceNameKey: "HeadBridge EQ",
                kAudioAggregateDeviceIsPrivateKey: 1,
                kAudioAggregateDeviceMainSubDeviceKey: px8UID,
                kAudioAggregateDeviceClockDeviceKey: px8UID,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: px8UID, kAudioSubDeviceInputChannelsKey: 0]
                ],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 0]],
                kAudioAggregateDeviceTapAutoStartKey: 1,
            ]
            let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
            guard !Task.isCancelled, await isCurrent() else { throw CancellationError() }
            guard aggregateStatus == noErr else {
                throw Failure.message("Could not create the equalizer aggregate (Core Audio \(aggregateStatus))")
            }
            let callback: AudioDeviceIOProc = { _, _, input, _, output, _, context in
                guard let context else { return noErr }
                let session = Unmanaged<EQSession>.fromOpaque(context).takeUnretainedValue()
                session.process(input, output)
                return noErr
            }
            let ioStatus = AudioDeviceCreateIOProcID(
                aggregateID, callback, Unmanaged.passUnretained(self).toOpaque(), &ioProcID
            )
            guard !Task.isCancelled, await isCurrent() else { throw CancellationError() }
            guard ioStatus == noErr else {
                throw Failure.message("Could not create the equalizer IOProc (Core Audio \(ioStatus))")
            }
        } catch {
            stop()
            throw error
        }
    }

    func start() throws {
        guard usesCoreAudio else { return }
        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            throw Failure.message("Could not start the equalizer (Core Audio \(status))")
        }
        started = true
    }

    func stop() {
        if started, let ioProcID { AudioDeviceStop(aggregateID, ioProcID) }
        started = false
        if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        onStop?()
        onStop = nil
    }

    private func process(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let destination = UnsafeMutableAudioBufferListPointer(output)
        if callbackFaulted {
            invalidBuffers.withLockIfAvailable { $0 = true }
            for buffer in destination {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return
        }
        guard source.count == 1, destination.count == 1,
            source[0].mNumberChannels == 2, destination[0].mNumberChannels == 2,
            source[0].mDataByteSize == destination[0].mDataByteSize,
            source[0].mDataByteSize % 8 == 0,
            let inputData = source[0].mData, let outputData = destination[0].mData, let processor
        else {
            callbackFaulted = true
            for buffer in destination {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return
        }
        processor.process(
            inputData.assumingMemoryBound(to: Float.self), outputData.assumingMemoryBound(to: Float.self),
            frames: Int(source[0].mDataByteSize) / 8, channels: 2
        )
    }
}
