# HeadBridge press kit

## Product facts

| Field | Value |
| --- | --- |
| Name | HeadBridge |
| Category | Native macOS menu-bar utility for Bluetooth headphones |
| Price | Free |
| License | MIT |
| Platform | macOS 14 or newer; macOS 26 for the optional Control Center extension |
| Distribution | GitHub Releases; project self-signed and not Apple-notarized |
| Source | <https://github.com/herenickname/HeadBridge> |
| Validated hardware | Bowers & Wilkins Px7 S3 and Sony WH-1000XM3 |
| Privacy | No account, analytics, ads, telemetry, or cloud sync |

## Positioning

HeadBridge gives non-Apple Bluetooth headphones a native, AirPods-like home in the macOS Sound menu. Vendor-specific headphone utilities already exist, but they generally target one brand or protocol. HeadBridge is a free, open-source attempt to put multiple independently implemented providers behind one consistent macOS interface.

It is an early beta, not a claim of universal headphone support. The maintainer owns and hardware-tests only Px7 S3 and WH-1000XM3. Other compatible-looking models remain experimental until somebody who owns that exact hardware tests and contributes them.

## Copy deck

### One-line description

AirPods-style controls for third-party Bluetooth headphones in the macOS menu bar.

### Short description

HeadBridge is a free, open-source macOS menu-bar app that unifies battery, noise control, EQ, device settings, and audio routing for supported Bowers & Wilkins and Sony headphones.

### Full description

HeadBridge brings vendor-specific Bluetooth headphone controls into a native interface modeled after the macOS Sound menu. It combines system output and input selection with headphone battery, noise modes, restore-on-connect profiles, and provider-specific controls such as Bowers & Wilkins True Immersion and Sony MDR V1 EQ, ambient sound, DSEE HX, and one-way volume synchronization.

The project is designed around contributor-owned providers rather than a hard-coded model list. New hardware support can be added and tested by people who own the device, while the shared app keeps the interaction consistent. HeadBridge is MIT-licensed, has no analytics or account, and stores device history locally.

## Feature highlights

- Native menu-bar UI modeled after the macOS Sound menu.
- Output selection, live system volume, and `Option`-click input selection.
- Sticky Input to stop macOS from silently replacing a preferred microphone.
- Battery percentage in the menu bar and persistent per-device battery history.
- Noise cancellation, ambient/pass-through, wind reduction, and off where supported.
- Restore-on-connect profiles after a phone or another source changes settings.
- Bowers & Wilkins RPC controls including EQ, True Immersion, sensors, and timers.
- Sony MDR V1 controls including EQ, VPT, DSEE HX, NC optimizer, touch sensor, and macOS-to-headphones volume sync.
- Launch at Login and signed Sparkle update archives distributed through GitHub Releases.
- Local operation with no account, analytics, advertising, or cloud sync.

## Compatibility statement

Hardware-validated:

- Bowers & Wilkins Px7 S3 using the Bowers & Wilkins RPC provider.
- Sony WH-1000XM3 using the Sony MDR V1 provider.

Other recent Bowers & Wilkins RPC and Sony MDR V1 devices are experimental. Sony MDR V2/Link2 is detected but not implemented. Exact support depends on model, firmware, and returned capabilities.

## Screenshots

The repository includes six hardware-backed captures from the working release
build. Replacement images should use the same macOS appearance and wallpaper,
keep the menu-bar icon visible where relevant, avoid debug overlays, and omit
device serial numbers, Bluetooth addresses, and firmware versions.

| Filename | Capture | Suggested caption | Alt text |
| --- | --- | --- | --- |
| `assets/screenshots/menu-controls.png` | Included: menu open with both validated headphones listed and B&W expanded | HeadBridge keeps audio routing and active-headphone controls in a familiar macOS Sound-style menu. | HeadBridge menu showing Mac audio outputs, Px7 S3, WH-1000XM3, battery levels, and noise controls. |
| `assets/screenshots/menu-sony-controls.png` | Included: menu open with both validated headphones listed and Sony expanded | Sony noise, sound-quality, EQ, and system-volume controls live beside macOS audio routing. | HeadBridge menu showing Mac audio outputs, Px7 S3, WH-1000XM3, battery levels, and Sony controls. |
| `assets/screenshots/bowers-wilkins-settings.png` | Included: Px7 S3 connection, Bluetooth Audio, Noise Control, and Five-band Equalizer | Bowers & Wilkins controls follow the same native settings layout as every other provider. | HeadBridge settings for Bowers & Wilkins Px7 S3 with Bluetooth audio, noise control, and five-band equalizer. |
| `assets/screenshots/sony-settings.png` | Included: WH-1000XM3 settings with Noise Control, Bluetooth Audio, and Equalizer visible | Sony MDR V1 support includes ambient sound, wind reduction, sound-quality selection, and EQ. | HeadBridge settings for Sony WH-1000XM3 with noise modes, Bluetooth audio, and equalizer controls. |
| `assets/screenshots/battery-history.png` | Included: Px7 S3 controls, redacted device identity values, and 24-hour battery chart | Battery history is sampled locally while a headset is connected and remains available per device. | HeadBridge Bowers & Wilkins settings and battery chart with firmware, serial number, and Bluetooth address blurred. |
| `assets/screenshots/sony-battery-history.png` | Included: WH-1000XM3 controls and 24-hour battery chart | Local history makes headset battery behavior visible without an account or cloud service. | HeadBridge battery chart showing charge percentage over 24 hours for a connected Sony headset. |

## Installation disclosure

Public releases use a stable, project-owned self-signed identity so macOS can preserve Bluetooth consent across updates. They are not signed or notarized by Apple. The optional installer validates the exact public certificate fingerprint and removes quarantine from the installed `HeadBridge.app` bundle so it can open. That remains a Gatekeeper bypass and should be described plainly wherever the installation command is shared. Users can inspect the installer, download manually, or build from source.

## Maintainer and contributor note

The maintainer cannot honestly validate hardware they do not own. Owners of other models are invited to clone the repository, open it in Codex or Claude Code using the latest capable model available to them, adapt the closest provider, test every exposed control on their actual headphones, and submit a GitHub Pull Request. AI assistance is welcome; the contributor remains responsible for reviewing the code and reporting real hardware results.

## Links

- Repository: <https://github.com/herenickname/HeadBridge>
- Releases: <https://github.com/herenickname/HeadBridge/releases/latest>
- Compatibility and installation: <https://github.com/herenickname/HeadBridge#readme>
- Contributing: <https://github.com/herenickname/HeadBridge/blob/main/CONTRIBUTING.md>
- Privacy: <https://github.com/herenickname/HeadBridge/blob/main/PRIVACY.md>
- Security reports: <https://github.com/herenickname/HeadBridge/security/advisories/new>
