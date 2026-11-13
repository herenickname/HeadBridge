# HATOR Phoenix 2 Wireless — provider integration notes

Status: **experimental HeadBridge implementation; partially validated on physical hardware**. On 2026-11-12 (headset firmware `V0.0.116`), HeadBridge connected over BLE with 2.4 GHz USB audio active, read battery, ANC, EQ, Spatial, RGB and microphone state, and verified ANC, EQ, RGB and microphone-mute writes with readback. Bluetooth-audio Spatial switching, physical radio loss, full power cycles and dongle unplug/replug still require hardware testing.

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
- **PASS:** HeadBridge quit/relaunch reestablished BLE and reread the headset. Two additional consecutive relaunches connected within seven seconds. With Restore on Connect temporarily enabled, original RGB/microphone states remained intact. The preference was returned to OFF. This did **not** prove reapplication of a differing saved state.
- **PASS:** In-app Disconnect released BLE and cleared UI state; in-app Refresh reconnected and read the headset again. Periodic state updates were observed roughly every 30 seconds without overlapping poll bursts.
- **OBSERVED:** One transient Not connected state occurred during rapid rebuild/relaunch testing. The separate CLI still connected correctly; the following controlled HeadBridge launch and two consecutive relaunches were successful. Root cause not established, so this is not a stress-test pass.
- **PASS:** generic settings view correctly updates observed controls after BLE readback (UI observation fix).
- **PASS:** direct ANC SET and verified GET with USB dongle selected; all three advertised modes are discovered dynamically from SYS_INFO field `0E`. The mode was subsequently changed through the UI, so no forced ANC restoration was performed.
- **PASS:** nine EQ presets decoded from SYS_INFO field `0C`; Custom mode applied with a +1 adjustment to 400 Hz and verified with a fresh GET (field `04`). Custom 400 Hz was returned to zero and the original Normal preset reselected, with both restorations confirmed. Preset labels follow the nine-position EQ Settings grid in the installed HATOR SyncHUB application (Normal, Shooters, Rock, Movie, Action, Hip-Hop/Rap, EDM, Sport, Custom); the editor currently allows conservative ±12 gains.
- **IMPLEMENTED, HARDWARE CONFIRMATION PENDING:** device-initiated SYS_INFO_AUTO_UPDATE (`0x09`) is parsed, acknowledged when required, and merged into the current state without disrupting an in-flight transaction. Frame handling has regression tests; physical button-originated updates have not yet been independently confirmed.
- **OBSERVED:** the ad-hoc local build could remain in CoreBluetooth state `unknown` after a rebuild despite the Bluetooth permission showing enabled. Re-enabling HeadBridge access in macOS System Settings → Privacy & Security → Bluetooth restored connection. Local development uses ad-hoc signing when the project's self-signed release identity is not installed; rebuilding can therefore require reauthorization.
- **PASS (2026-11-13):** macOS exposes both the Bluetooth (44.1 kHz) and USB-dongle (48 kHz) HATOR outputs, with Bluetooth selected for the Spatial test. Independent CLI confirmed spatial OFF → ON and final ON readback (`FF/02/FF`) **when Bluetooth audio was actively streaming**. This was a near-silent PCM stream; original ON state was restored.
- **PASS (2026-11-13):** HeadBridge Settings successfully toggled Spatial ON → OFF → ON during near-silent Bluetooth playback. Both `FF/02/FF` readbacks confirmed; the original ON setting was restored and the test stream stopped. The UI showed both confirmed values.
- **PASS (2026-11-13):** Bluetooth → 2.4 GHz USB → Bluetooth CoreAudio output changes kept one connected BLE session without reauthentication. Spatial was hidden on USB and restored on Bluetooth; RGB/microphone controls remained visible. Original Bluetooth default output and Spatial ON were restored.
- **CONDITIONAL (2026-11-13):** with Bluetooth selected but no active playback, both HeadBridge and the independent CLI received successful SET acknowledgements but readback remained ON after an OFF request. The official app also says playback is necessary. HeadBridge now automatically disables its Spatial control while Core Audio reports no output activity, leaving the last confirmed device value intact. If a playback stream stops during a write, a failed device readback remains an error rather than an assumed success. Multiple failed writes were observed in this scenario; provider and BLE-client guards now reject duplicate Spatial writes while a command is pending (repeat stress test pending).
- **PASS (2026-11-13):** Core Audio output activity, scoped to the selected HATOR Bluetooth output (not the similarly named microphone device), was observed `0 → 1 → 0` across inactive, playback, and stopped states. A listener registered with `AudioObjectAddPropertyListenerBlock` received both transitions. HeadBridge uses these notifications to enable/disable Spatial Audio automatically, without capturing samples or requesting audio-recording permission. Hardware verification of the Core Audio listener succeeded; the rebuilt HeadBridge UI could not be reverified in this session because macOS left CoreBluetooth in `unknown` after ad-hoc signing, even with its permission switch enabled.
- **NOT TESTED:** physical device power cycle, dongle removal/reinsert, real radio loss, long-running reconnection under all failure paths.

## Minimum acceptance tests for implementation

1. Both Bluetooth and USB audio outputs are recognized narrowly and associated with one physical HATOR device; unrelated or similarly named outputs never match.
2. Switching the default audio output between Bluetooth and USB leaves one BLE control session and updates effective capabilities promptly.
3. Spatial Audio is shown and controllable with confirmed Bluetooth audio, but absent and not callable with the USB dongle selected, including from Settings, menu bar and Control Center.
4. BLE status/verified controls remain usable while USB audio plays; test disconnect, reconnect, stale callbacks, and headphone / dongle unplug-replug separately.
5. Restore-on-connect does not inadvertently write Spatial Audio while USB is the active audio route; all command writes require acknowledgement/readback where supported.
6. Run `swift test`, `HEADBRIDGE_SKIP_REGISTRATION=1 ./Scripts/build-app.sh`, and `./Scripts/check-publication.sh` after implementation, and report real-hardware results.

These notes follow the lifecycle, capability, and clean-room rules in [PROVIDERS.md](PROVIDERS.md) and [CONTRIBUTING.md](../CONTRIBUTING.md).
