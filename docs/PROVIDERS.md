# Provider development

Every headphone integration conforms to `HeadphoneProvider` in `Sources/HeadBridge/Core/HeadphoneProvider.swift`.

A provider is responsible for:

1. narrowly recognizing supported names from the macOS paired-device inventory;
2. matching its supported `SystemAudioDevice` names;
3. opening and owning exactly one vendor-control transport session;
4. automatically connecting only while a matching Bluetooth audio device is available;
5. publishing connection, battery, codec, noise-mode, and capability state on the main actor;
6. closing timers and native/Bluetooth resources on disconnect or failure;
7. implementing only the common commands advertised through `HeadphoneCapabilities`;
8. exposing `restoreOnConnectEnabled` and persisting a device-specific profile through `HeadphoneProfileStore`.

The current application creates one provider instance, and therefore one active
vendor-control session, per protocol family. Do not claim simultaneous support
for two devices from the same family until provider factories and per-device
sessions are introduced. Device matching must be narrow enough that volume or
control commands cannot be routed to a second similarly named output.

Provider identity describes a vendor/protocol family, not the first model used
to reverse it. Keep model-specific packet layouts and feature flags in device
profiles behind that provider. If a vendor has incompatible wire generations,
the vendor provider may select separate protocol adapters after service/init
probing while keeping one entry in shared UI and routing.

Register a provider in `HeadBridgeApp`:

```swift
let providers: [any HeadphoneProvider] = [
    bowersWilkins,
    sony,
    YourHeadphoneProvider()
]
let manager = HeadphoneManager(providers: providers)
```

`HeadphoneManager` maps the shared macOS Bluetooth inventory through
`recognizesBluetoothDevice(named:)`; only real, paired, recognized devices are
shown in the Settings sidebar. The menu-bar device list and Control Center use
the protocol rather than vendor types. A vendor-specific settings screen may
receive its concrete provider as an environment object, as the B&W and Sony
screens do.

Common connection, battery, codec, noise-control, restore-on-connect, and
system-volume synchronization behavior is provider-driven. Unknown providers
receive a generic settings screen automatically. Rich vendor-specific controls
still require a small registration in `ContentView` and `MenuPopoverView`; keep
that registration thin and keep protocol logic inside the provider.

If the device exposes a separate hardware volume, opt in with
`supportsSystemVolumeSynchronization` and advertise `.deviceVolume` only after
the connected device confirms support. `HeadphoneManager` scopes the preference
by `providerID`, observes Core Audio, and forwards changes only when the active
output matches the provider's connected device.

Capabilities must come from the connected device whenever its protocol exposes discovery. Do not advertise a control merely because another model from the same vendor supports it. Keep destructive commands and firmware update paths out of the default UI.

Restore profiles are provider-owned `Codable` values keyed by provider ID and a stable device ID (Bluetooth address or persistent peripheral UUID). Save settings selected through HeadBridge, not the initial values read during a reconnect: otherwise a phone's temporary changes would overwrite the profile before it could be restored. Apply the saved profile only after the provider's initial state queries have completed.

## Transport lifecycle

Treat every Bluetooth connection as a generation. Delegate callbacks from an
older peripheral or RFCOMM channel must not mutate the active generation. A
provider should become ready only after its response/notification path is
confirmed, and it must clear published device state when that generation ends.

Automatic attachment should follow this lifecycle:

1. observe a matching connected Core Audio output;
2. discover or resolve the vendor-control endpoint;
3. open exactly one transport session;
4. subscribe to notifications and complete initial reads;
5. publish confirmed capabilities and state;
6. apply the saved restore profile, if enabled;
7. cancel timers, queued work, delegates, and native resources on disconnect.

Command queues need bounded capacity and semantic coalescing for rapidly
changing values such as volume and ambient level: the latest queued value wins.
Parsers must bound frame size, collection size, and nesting depth before
allocating from values supplied by a Bluetooth peer.

Provider tests should cover name matching, value/range mapping, protocol frame
encoding, malformed/oversized input, queue coalescing, cleanup/reconnection,
stale callbacks, and Bluetooth power cycling. Hardware verification must record
the model, firmware, macOS version, codec, and tested controls in the README or
the pull request.
