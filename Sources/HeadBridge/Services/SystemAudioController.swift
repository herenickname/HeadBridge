import AudioToolbox
import CoreAudio
import Foundation

struct SystemAudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var iconName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeUSB:
            return "cable.connector"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual:
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.2.fill"
        }
    }

    var inputIconName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeUSB:
            return "mic.fill"
        default:
            return "mic.fill"
        }
    }
}

@MainActor
final class SystemAudioController: ObservableObject {
    @Published private(set) var devices: [SystemAudioDevice] = []
    @Published private(set) var inputDevices: [SystemAudioDevice] = []
    @Published private(set) var defaultDeviceID: AudioDeviceID?
    @Published private(set) var defaultInputDeviceID: AudioDeviceID?
    @Published private(set) var stickyInputUID: String?
    @Published private(set) var volume: Float = 0.5
    @Published private(set) var volumeCanBeChanged = false
    @Published private(set) var errorMessage: String?

    private var systemPropertyListener: AudioObjectPropertyListenerBlock?
    private var volumePropertyListener: AudioObjectPropertyListenerBlock?
    private var volumeListenerDeviceID: AudioDeviceID?
    private var volumeListenerAddresses: [AudioObjectPropertyAddress] = []
    private var isShutdown = false
    private static let stickyInputUIDDefaultsKey = "StickyInputDeviceUID"

    init() {
        stickyInputUID = UserDefaults.standard.string(forKey: Self.stickyInputUIDDefaultsKey)
        refresh()
        installSystemPropertyListeners()
        configureVolumeListeners(for: defaultDeviceID)
    }

    func refresh() {
        guard !isShutdown else { return }
        let allDeviceIDs = Self.allDeviceIDs()
        let outputDevices =
            allDeviceIDs
            .filter(Self.hasOutputStreams)
            .compactMap(Self.makeDevice)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let availableInputDevices =
            allDeviceIDs
            .filter(Self.hasInputStreams)
            .compactMap(Self.makeDevice)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if devices != outputDevices { devices = outputDevices }
        if inputDevices != availableInputDevices { inputDevices = availableInputDevices }
        let newDefaultID = Self.defaultOutputDeviceID()
        if defaultDeviceID != newDefaultID {
            defaultDeviceID = newDefaultID
            configureVolumeListeners(for: newDefaultID)
        }

        var newDefaultInputID = Self.defaultInputDeviceID()
        if let stickyInputUID,
            let stickyDevice = availableInputDevices.first(where: { $0.uid == stickyInputUID }),
            newDefaultInputID != stickyDevice.id,
            Self.setDefaultDevice(stickyDevice.id, selector: kAudioHardwarePropertyDefaultInputDevice) == noErr
        {
            newDefaultInputID = stickyDevice.id
        }
        if defaultInputDeviceID != newDefaultInputID {
            defaultInputDeviceID = newDefaultInputID
        }
        refreshVolume()
    }

    /// Symmetric counterpart to listener installation in `init`. Explicit
    /// shutdown avoids retaining Core Audio listener blocks until process exit
    /// and prevents already-queued callbacks from rebuilding listeners.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        removeVolumeListeners()
        removeSystemPropertyListeners()
    }

    func selectInput(_ device: SystemAudioDevice) {
        // Once sticky mode is enabled, an explicit user choice moves the pin.
        if stickyInputUID != nil {
            setStickyInputUID(device.uid)
        }

        let status = Self.setDefaultDevice(device.id, selector: kAudioHardwarePropertyDefaultInputDevice)
        if status == noErr {
            errorMessage = nil
            defaultInputDeviceID = device.id
        } else {
            errorMessage = "Could not switch input (Core Audio \(status))"
        }
    }

    func toggleStickyInput(_ device: SystemAudioDevice) {
        if stickyInputUID == device.uid {
            setStickyInputUID(nil)
        } else {
            setStickyInputUID(device.uid)
            let status = Self.setDefaultDevice(device.id, selector: kAudioHardwarePropertyDefaultInputDevice)
            if status == noErr {
                errorMessage = nil
                defaultInputDeviceID = device.id
            } else {
                errorMessage = "Could not pin input (Core Audio \(status))"
            }
        }
    }

    func setStickyInputEnabled(_ enabled: Bool) {
        if enabled {
            guard let selectedID = defaultInputDeviceID,
                let selectedDevice = inputDevices.first(where: { $0.id == selectedID })
            else { return }
            setStickyInputUID(selectedDevice.uid)
        } else {
            setStickyInputUID(nil)
        }
    }

    func isStickyInput(_ device: SystemAudioDevice) -> Bool {
        stickyInputUID == device.uid
    }

    private func setStickyInputUID(_ uid: String?) {
        stickyInputUID = uid
        if let uid {
            UserDefaults.standard.set(uid, forKey: Self.stickyInputUIDDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.stickyInputUIDDefaultsKey)
        }
    }

    func select(_ device: SystemAudioDevice) {
        var id = device.id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )

        if status == noErr {
            errorMessage = nil
            defaultDeviceID = id
            configureVolumeListeners(for: id)
            refreshVolume()
        } else {
            errorMessage = "Could not switch output (Core Audio \(status))"
        }
    }

    func setVolume(_ newValue: Float) {
        guard let id = defaultDeviceID else { return }
        let clamped = min(1, max(0, newValue))

        if Self.setScalarVolume(
            clamped, deviceID: id, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            element: kAudioObjectPropertyElementMain)
        {
            volume = clamped
            errorMessage = nil
            return
        }

        let left = Self.setScalarVolume(clamped, deviceID: id, selector: kAudioDevicePropertyVolumeScalar, element: 1)
        let right = Self.setScalarVolume(clamped, deviceID: id, selector: kAudioDevicePropertyVolumeScalar, element: 2)
        if left || right {
            volume = clamped
            errorMessage = nil
        } else {
            errorMessage = "This output does not expose software volume control"
            refreshVolume()
        }
    }

    private func refreshVolume() {
        guard let id = defaultDeviceID else {
            volumeCanBeChanged = false
            return
        }

        if let master = Self.scalarVolume(
            deviceID: id, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            element: kAudioObjectPropertyElementMain)
        {
            volume = master
            volumeCanBeChanged = Self.volumeIsSettable(
                deviceID: id, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                element: kAudioObjectPropertyElementMain)
            return
        }

        let channels = [1, 2].compactMap {
            Self.scalarVolume(
                deviceID: id, selector: kAudioDevicePropertyVolumeScalar, element: AudioObjectPropertyElement($0))
        }
        if !channels.isEmpty {
            volume = channels.reduce(0, +) / Float(channels.count)
            volumeCanBeChanged = [1, 2].contains {
                Self.volumeIsSettable(
                    deviceID: id, selector: kAudioDevicePropertyVolumeScalar, element: AudioObjectPropertyElement($0))
            }
        } else {
            volumeCanBeChanged = false
        }
    }

    private func installSystemPropertyListeners() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, !self.isShutdown else { return }
                self.refresh()
            }
        }
        systemPropertyListener = listener

        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                listener
            )
        }
    }

    private func removeSystemPropertyListeners() {
        guard let listener = systemPropertyListener else { return }
        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                listener
            )
        }
        systemPropertyListener = nil
    }

    private func configureVolumeListeners(for deviceID: AudioDeviceID?) {
        guard volumeListenerDeviceID != deviceID else { return }
        removeVolumeListeners()
        guard !isShutdown, let deviceID else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, !self.isShutdown else { return }
                self.refreshVolume()
            }
        }
        volumePropertyListener = listener
        volumeListenerDeviceID = deviceID

        let candidates = [
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: 1
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: 2
            ),
        ]

        for candidate in candidates {
            var address = candidate
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, listener) == noErr {
                volumeListenerAddresses.append(candidate)
            }
        }
    }

    private func removeVolumeListeners() {
        guard let deviceID = volumeListenerDeviceID,
            let listener = volumePropertyListener
        else { return }
        for storedAddress in volumeListenerAddresses {
            var address = storedAddress
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, listener)
        }
        volumeListenerAddresses.removeAll()
        volumeListenerDeviceID = nil
        volumePropertyListener = nil
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
            id != kAudioObjectUnknown
        else { return nil }
        return id
    }

    private static func setDefaultDevice(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> OSStatus {
        var id = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func makeDevice(_ id: AudioDeviceID) -> SystemAudioDevice? {
        guard let name = stringProperty(id, selector: kAudioObjectPropertyName) else { return nil }
        let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? String(id)
        let transport = uint32Property(id, selector: kAudioDevicePropertyTransportType) ?? 0
        return SystemAudioDevice(id: id, uid: uid, name: name, transportType: transport)
    }

    private static func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private static func uint32Property(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func scalarVolume(
        deviceID: AudioDeviceID, selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement
    ) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func volumeIsSettable(
        deviceID: AudioDeviceID, selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func setScalarVolume(
        _ value: Float, deviceID: AudioDeviceID, selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> Bool {
        guard volumeIsSettable(deviceID: deviceID, selector: selector, element: element) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        var mutableValue = Float32(value)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &mutableValue)
            == noErr
    }
}
