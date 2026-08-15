# Contributing to HeadBridge

HeadBridge exists to make vendor-specific headphone controls available on
macOS without depending on proprietary mobile applications at runtime. Device
access is hardware-dependent, so small, well-documented contributions are more
valuable than broad unverified compatibility claims.

## Development setup

Requirements:

- macOS 14 or newer;
- Xcode 26 for the macOS 26 Control Center extension;
- a paired test device for transport or lifecycle changes.

Build and verify a checkout:

```shell
swift test
HEADBRIDGE_SKIP_REGISTRATION=1 ./Scripts/build-app.sh
./Scripts/check-publication.sh
```

The local app is written to `dist/HeadBridge.app`. Generated files in
`.build/`, `DerivedData/`, and `dist/` must not be committed.

## AI-assisted device workflow

The maintainer has physical access only to a Bowers & Wilkins Px7 S3 and a
Sony WH-1000XM3. Other models cannot be hardware-validated by the maintainer,
so support for a new device needs a contributor who owns or can repeatedly test
that device.

Codex and Claude Code are both welcome for this work. A practical workflow is:

1. fork or clone HeadBridge and open the checkout in Codex or Claude Code;
2. use the latest capable coding model available to you;
3. provide the exact model and firmware, then ask the agent to read this file,
   `docs/PROVIDERS.md`, and the closest protocol note before editing code;
4. adapt a protocol-family provider or add a new provider and capability
   profile without inventing unsupported wire facts;
5. build and run the app while you operate the real headphones, feeding actual
   replies and behavior back into the implementation;
6. test every exposed control, disconnect/reconnect, stale-session cleanup, and
   restore-on-connect;
7. run the verification commands above and open a GitHub Pull Request with the
   hardware results and tests.

The coding agent cannot replace hardware verification. Review every submitted
change yourself and keep unsupported controls hidden until the real device has
confirmed them. If the first pass is incomplete, a draft Pull Request is still
useful as long as its unverified behavior is stated clearly.

## Repository map

- `Sources/HeadBridge/Core`: shared provider contracts, settings, routing, and
  battery history;
- `Sources/HeadBridge/Providers`: vendor transports, protocol adapters, and
  device capability profiles;
- `Sources/HeadBridge/Views`: Settings and menu-bar UI;
- `Sources/HeadBridgeControls`: macOS 26 Control Center extension;
- `Tests/HeadBridgeTests`: wire-format, mapping, persistence, and parser tests;
- `docs`: protocol notes and release documentation.

## Provider lifecycle

A provider must:

1. prefilter only devices plausibly belonging to its vendor/protocol family;
2. attach a control transport only while matching Bluetooth audio is present;
3. own no more than one live transport for its active session;
4. complete initial reads before publishing `.ready`;
5. derive capabilities from replies or a documented model profile;
6. bound parsers and queues, and ignore callbacks from stale sessions;
7. stop scans, timers, tasks, notifications, and native transports on every
   disconnect or failure path;
8. persist restore profiles by stable `providerID` and device ID;
9. expose only controls that are safe and supported by the connected device.

Register the provider in the composition root in `HeadBridgeApp.swift`.
Common connection, battery, status, and noise controls flow through
`HeadphoneProvider`; the Settings sidebar and a generic detail page are created
automatically. Rich vendor-specific Settings or menu controls currently need a
small UI registration alongside the provider implementation.

See [`docs/PROVIDERS.md`](docs/PROVIDERS.md) for the complete contract.

## Protocol research and clean-room rules

Contributions may use independently observed Bluetooth traffic, public wire
facts, public documentation, and behavior verified on hardware. Do not submit:

- decompiled source copied from a vendor APK or application;
- vendor artwork, firmware, APKs, signing material, or other redistributed
  binaries;
- code copied from a project whose license is incompatible with MIT;
- private keys or certificates.

When public projects helped cross-check a protocol fact, record the project,
license, and relevant revision in `THIRD_PARTY_NOTICES.md` or the protocol note.
Packet bytes and independently implemented behavior are welcome; copied
implementation code is not.

Current fact-oriented contributor references are the
[`Bowers & Wilkins RPC notes`](docs/BowersWilkinsRPC.md),
[`Sony MDR V1 notes`](docs/SonyMDRV1.md), and
[`Sony MDR V2 adapter notes`](docs/SonyMDRV2.md).

## Tests and hardware verification

Protocol changes should include deterministic tests for exact frames, malformed
input, range mapping, and capability detection. Lifecycle changes should cover
cleanup, reconnect, stale callbacks, or queue behavior when a test seam exists.

In a pull request, record:

- headphone model and firmware;
- macOS and app versions;
- Bluetooth codec when relevant;
- which controls were tested on hardware;
- whether behavior was verified after disconnect/reconnect and after another
  source changed the setting.

## Pull requests

Keep provider changes focused and avoid unrelated formatting. Run the three
verification commands above and complete the pull request checklist. New
destructive operations, pairing-list mutation, firmware
updates, and DFU paths are out of scope for the default application.
