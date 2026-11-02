# Changelog

All notable user-visible changes will be documented here. HeadBridge follows
[Semantic Versioning](https://semver.org/) once public releases begin.

## Unreleased

## 0.2.0 - 2026-11-02

### Added

- OPPO Enco Air5s support, verified by a contributor on firmware `163.163.102`:
  per-bud/case battery, noise modes and ANC depth, spatial and game controls,
  built-in and custom EQ, gestures, multipoint, codec settings, and wearing state.
- Guarded Find Earbuds for Air5s: both earbuds must have fresh out-of-ear reports;
  in-ear or partial reports stop ringing, as does a manual disconnect.
- Original Bowers & Wilkins Px8 support: generic BLE discovery, correct ANC values,
  bass/treble controls, automatic reconnection, and restore-on-connect.
- Optional Dock/Cmd+Tab presence while the Settings window is open.
- Millisecond protocol-log timestamps and copy/save export with owner-only files.

### Fixed

- Expanded menu-bar controls resize their popover, and Option-click input
  selection is re-evaluated each time the menu opens.
- Bowers & Wilkins settings read back after setter acknowledgements; a transient
  read error no longer hides a previously confirmed control.
- Generic Bowers & Wilkins control links are checked against paired Bluetooth
  addresses, and Px8 connection state/battery appear correctly in the sidebar.

### Updated

- Sparkle 2.10.1 is selected consistently by both SwiftPM and the Xcode project.
- Release build numbers remain higher than the public 0.1.7 build so existing
  installations can receive the update through Sparkle.

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
