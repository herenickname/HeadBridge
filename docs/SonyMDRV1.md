# Sony MDR V1 protocol notes

HeadBridge's Sony transport and packet parser are implemented independently in
Swift. This document records wire-level facts useful to future provider
contributors; it is not copied source code from another client.

## Transport envelope

- RFCOMM service UUID: `96CC203E-5068-46AD-B32D-E316F5E069BA`
- Frame: `3E | type | sequence | payload length (big endian, 4 bytes) | payload | checksum | 3C`
- Checksum: wrapping sum of every byte from `type` through the final payload byte
- Bytes `3C`, `3D`, and `3E` inside the frame body are escaped as `3D` followed by `byte & EF`
- Incoming command packets are acknowledged with packet type `01` and the same sequence bit

## WH-1000XM3 noise-control payload

The combined NC/ambient `SET` payload is eight bytes:

| Offset | Meaning | WH-1000XM3 values |
| ---: | --- | --- |
| 0 | opcode | `68` |
| 1 | combined NC/ASM inquiry | `02` |
| 2 | effect | `00` off, `11` enabled/adjustment complete |
| 3 | NC setting type | `02` (wind + dual-microphone ANC) |
| 4 | NC value | `00` ambient, `01` wind reduction, `02` ANC |
| 5 | ambient setting type | `01` (level adjustment) |
| 6 | ambient ID / focus on voice | normally `00`, focus-on-voice uses `01` |
| 7 | ambient level | `01...14` hex (1...20 decimal), otherwise `00` |

The corresponding `GET`, return, and notify opcodes are `66`, `67`, and `69`.
In particular, byte 3 must remain `02` when selecting ANC; treating it as a
simple level field (`01`) makes some firmware accept the frame but retain or
restore the previous mode.

## Feature families found on WH-1000XM3

| Feature | V1 opcode family | HeadBridge status |
| --- | --- | --- |
| Battery | `10 / 11 / 13` | implemented |
| Active codec | `18 / 19 / 1B` | implemented |
| Noise, ambient level | `66 / 67 / 68 / 69` | implemented |
| Headphone volume | `A6 / A7 / A8 / A9` | implemented |
| Sound position / surround | `46...49` command type 1 | implemented for WH-1000XM3 |
| Equalizer presets and custom bands | capability `50/51`, values `56...59` | implemented for WH-1000XM3 |
| ANC optimizer | `84...89` | implemented for WH-1000XM3 |
| Touch sensor | general settings `D6...D9`, XM3 slot `D2` | implemented for WH-1000XM3 |
| DSEE / sound-quality preference | `E6...E9` | implemented for WH-1000XM3 |
| Automatic power-off | `F6...F9` command type 4 | implemented for WH-1000XM3 |
| Voice notifications | `46...49` command type 2 | mapped, not exposed |
| Power off | `22` | mapped, deliberately not exposed yet |

`SonyMDRProvider` is shared by the V1 family. A `SonyV1DeviceProfile` decides
which extended state queries are safe for a known model, and the provider only
advertises a capability after receiving that state. Unknown V1 devices still
use common battery, codec, noise-control, and volume queries without inheriting
XM3-only controls. Equalizer, sound-position, and surround settings are
constrained by the active codec (notably SBC-only combinations); changing the
sound-quality preference can therefore reconnect Bluetooth audio.

The restore-on-connect profile persists user-selected values and reapplies them
after the initial state exchange. One-shot operations such as running the ANC
optimizer are intentionally not persisted.

## Cross-check references

- [Gadgetbridge Sony headphones implementation](https://codeberg.org/Freeyourgadget/Gadgetbridge) (AGPL-3.0)
- [sony-connect-osx](https://github.com/tanat/sony-connect-osx) (no license file at the time of review)
- [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) (MIT)

These projects were used to cross-check protocol facts and device capability
names. No Gadgetbridge or unlicensed `sony-connect-osx` source is incorporated
into HeadBridge.
