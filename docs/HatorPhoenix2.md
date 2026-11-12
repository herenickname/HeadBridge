# HATOR Phoenix 2 Wireless — provider integration notes

Status: **experimental HeadBridge implementation; partially validated on physical hardware**. On 2026-11-12 (headset firmware `V0.0.116`), HeadBridge connected over BLE with 2.4 GHz USB audio active, read battery, Spatial, RGB and microphone state, and verified RGB and microphone-mute writes with live readback. App relaunch/reconnect was successful. Bluetooth-audio Spatial switching, radio loss, full power cycles and dongle unplug/replug still need hardware testing.

## Audio output is not the control transport

Phoenix 2 Wireless can present a Bluetooth audio output or a 2.4 GHz USB-dongle audio output (`379A:6303`). Both must resolve to **one physical headset** and one HATOR provider instance. The provider should use one authenticated Bluetooth LE control session for either audio route; do not open a separate BLE connection for each audio output, and do not assume the dongle implements JieLi RCSP over USB HID.

Local hardware tests confirmed that the 2.4 GHz USB audio output remained selected and audio continued normally while authenticated BLE commands toggled headset RGB on/off, with successful independent readback. Repeated BLE reconnects and a controlled in-process reconnect also succeeded. The earlier RGB-over-dongle tests were conducted with the separate research prototype; the HeadBridge app has since independently confirmed RGB and microphone-mute SET/GET while the dongle is the active audio output. Radio-loss and full power-cycle tests remain outstanding.

Known BLE control endpoint: JieLi RCSP over GATT service `AE00`, write characteristic `AE01`, notify characteristic `AE02`, with verified mutual authentication. A strict advertised-service-filtered scan may miss this device; discovery must still narrowly validate the headset identity before connecting. Do not publish local identifiers, authentication material, or raw private captures.

## Context-dependent capabilities

Keep **hardware capabilities** (what the physical headset supports) distinct from **effective capabilities** (what controls are meaningful for the selected audio route). A verified function must not be advertised in a context where it has no effect.

| Selected audio output | BLE control | Headset Spatial Audio setting |
| --- | --- | --- |
| Phoenix 2 Bluetooth audio | Allowed when authenticated | Available when capability and readback are confirmed |
| Phoenix 2 2.4 GHz USB dongle | Allowed when authenticated | **Hidden / unavailable** |
| Other or unidentified output | No automatic association | Not exposed |

The headset's BLE Spatial command (`FF/02`: verified values `00` off and `02` on) is **not** a control for the USB-dongle audio path. Do not surface or send this command as a spatial-audio setting while the 2.4 GHz dongle is the selected output, even though BLE remains connected and the command itself may ACK. Do not infer support for value `01` or additional spatial modes.

HeadBridge currently exposes a single `HeadphoneProvider.capabilities` value and matches providers using Core Audio devices. During implementation, explicitly provide the selected-output context to the provider or to a capability-filtering layer, so that `spatialAudio` is excluded from **effective** capabilities for dongle audio. Apply that gate consistently to Settings, menu bar, Control Center and command dispatch; hiding just the UI control is insufficient. Switching audio routes must refresh effective capabilities without opening a second BLE session. A Bluetooth connection existing in the inventory is not evidence that Bluetooth is the currently selected audio route.

Do not automatically duplicate per-audio-output restore profiles: headset-level preferences should be keyed to the stable physical headset identity; route-specific preferences require explicit design. A saved Spatial Audio value must not be restored through the BLE command while USB-dongle audio is selected. Confirm the intended behavior when switching back to Bluetooth audio before enabling restore.

Other controls (ANC, EQ, RGB, microphone mute, battery) must be exposed only when their write/readback behavior and relevance to the current audio route are confirmed. Do not assume that an EQ or Spatial setting affects USB audio merely because the headset acknowledges the BLE command. USB HID control reports remain unidentified; no guessed HID output writes, firmware changes, or OTA commands.

## In-app hardware test results (2026-11-12)

- **PASS:** 2.4 GHz dongle recognized as active USB audio output; a single authenticated BLE session independently connected while USB audio remained selected.
- **PASS:** live battery/status and RGB/microphone-mute readbacks; RGB OFF → ON → OFF and microphone muted → unmuted → muted with verified BLE SET/GET. Original headset settings were restored.
- **PASS:** Spatial Audio absent from USB-dongle Settings, with setter additionally gated by the selected audio route.
- **PASS:** HeadBridge quit/relaunch reestablished BLE and reread the headset. With Restore on Connect temporarily enabled, original RGB/microphone states remained intact. The preference was returned to OFF. This did **not** prove reapplication of a differing saved state.
- **PASS:** generic settings view correctly updates observed controls after BLE readback (UI observation fix).
- **NOT TESTED:** Bluetooth audio route and Spatial write; macOS currently exposes only the 2.4 GHz USB audio output for this headset. Do not force a route that does not exist.
- **NOT TESTED:** physical device power cycle, dongle removal/reinsert, real radio loss, long-running reconnection under all failure paths.

## Minimum acceptance tests for implementation

1. Both Bluetooth and USB audio outputs are recognized narrowly and associated with one physical HATOR device; unrelated or similarly named outputs never match.
2. Switching the default audio output between Bluetooth and USB leaves one BLE control session and updates effective capabilities promptly.
3. Spatial Audio is shown and controllable with confirmed Bluetooth audio, but absent and not callable with the USB dongle selected, including from Settings, menu bar and Control Center.
4. BLE status/verified controls remain usable while USB audio plays; test disconnect, reconnect, stale callbacks, and headphone / dongle unplug-replug separately.
5. Restore-on-connect does not inadvertently write Spatial Audio while USB is the active audio route; all command writes require acknowledgement/readback where supported.
6. Run `swift test`, `HEADBRIDGE_SKIP_REGISTRATION=1 ./Scripts/build-app.sh`, and `./Scripts/check-publication.sh` after implementation, and report real-hardware results.

These notes follow the lifecycle, capability, and clean-room rules in [PROVIDERS.md](PROVIDERS.md) and [CONTRIBUTING.md](../CONTRIBUTING.md).
