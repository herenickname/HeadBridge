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
