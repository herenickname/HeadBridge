# Changelog

All notable user-visible changes will be documented here. HeadBridge follows
[Semantic Versioning](https://semver.org/) once public releases begin.

## Unreleased

- Bowers & Wilkins: discover headphones that advertise over BLE under the
  generic `LE_BWHP` name, hardware-tested with the original Px8.
- Bowers & Wilkins: use the original Px8's ANC mode values, so Off, Noise
  Cancellation, and Pass-Through select the correct mode.
- Bowers & Wilkins: bass and treble sliders for headphones that have a two-band
  tone control instead of the five-band EQ, hardware-tested with the original
  Px8.
- Bowers & Wilkins: confirm a changed setting only after the headphones
  acknowledge it, and keep a confirmed control visible if a later read fails.
  Toggling the wear sensor on an original Px8 could bounce back or make the
  control disappear.
- Bowers & Wilkins: for generically advertised headphones, drop the control
  link when the headphone's reported Bluetooth address is not a connected
  paired headphone, so a neighbour's headphones are not controlled by mistake.
- Menu-bar popover: keep the window as tall as its content when a device's
  controls expand, instead of clipping them (seen on macOS 27).
- Menu: `Option`-click shows the input devices every time the menu opens, and
  pressing `Option` while it is open reveals them (seen broken on macOS 27).
- Protocol diagnostics: log times include seconds and milliseconds, and
  the log can be copied or saved to a text file.
- Optional Dock icon while the settings window is open (General → Dock).

- OPPO Enco RFCOMM provider with battery, noise control,
  restore-on-connect, fixed spatial audio, game mode, game sound effects, and
  equalizer presets, plus writable feature switches for auto play/pause, dual
  connection, and Windows Swift Pair. Spatial audio is switched
  through the earbuds' direct spatial-type command, plus spatial type 2,
  three ANC depth levels (Light/Deep/Smart), a selectable touch-and-hold cycle,
  alert volume, ring-my-earbuds, dual-device connect/disconnect/preferred,
  gesture remapping with every function available on every slot (grouped into
  main/call rows, split slide entries merged), a custom-EQ editor, and a
  Hi-Res switch. The Golden Sound hearing-profile UI was removed after the
  Air5s refused every hearing-test command; the EQ presets remain. The codec
  display clears on disconnect and refreshes every 15 seconds; spatial audio
  clears Hi-Res and re-applies after the reconnect, and the Hi-Res switch
  clears the flag with `0x0403 18 00`. The OPPO settings screen also shows
  firmware, codec, per-bud/case battery, wearing state, and the
  dual-connection list. Validated on an OPPO Enco Air5s
  (firmware `163.163.102`) by a contributor on the physical device.
- OPPO codec picker (AAC/LDAC/LHDC/LHDC V5), live wearing-status polling, and a
  guarded find-my-earbuds action that only rings when both earbuds are confirmed
  out of ear.

## 0.1.7 - 2026-08-16

### First public beta

- Native macOS Sound-style menu with output selection, live volume, and
  `Option`-click input selection.
- Bowers & Wilkins RPC and Sony MDR V1 providers, hardware-tested with Px7 S3
  and WH-1000XM3.
- Noise cancellation, pass-through/ambient, wind reduction, equalizers, and
  provider-specific controls including B&W True Immersion and Sony VPT,
  DSEE HX, sound position, touch sensor, NC optimizer, and sound-quality mode.
- Optional macOS-to-Sony headphone volume synchronization, Sticky Input,
  restore-on-connect profiles, Launch at Login, and macOS 26 Control Center
  controls.
- Persistent local per-device battery history and configurable menu-bar
  battery percentage.
- Extensible multi-provider architecture with bounded protocol parsers and
  opt-in decoded-value and transport-log diagnostics.
- Universal self-signed GitHub release, checksum-validating installer, and
  EdDSA-verified Sparkle updates without an Apple Developer identity.
