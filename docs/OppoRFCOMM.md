# OPPO Enco RFCOMM notes

This note covers the OPPO earphone control service used by `OppoProvider`. It
was written from packets captured on an **OPPO Enco Air5s** and cross-checked
against independent public protocol descriptions. No implementation code from
another project is included in HeadBridge.

## Scope and status

- Provider ID: `oppo-enco`.
- Recognized names: paired-device names containing both `OPPO` and `Enco`
  after normalization.
- Transport: Bluetooth Classic RFCOMM/SPP, not BLE.
- Hardware-validated model: OPPO Enco Air5s, product id `0x06C810`.
- Battery is parsed for every model that answers the battery query. Noise
  control is exposed only for a model whose write table is listed in
  `OppoModelProfile.knownProfiles`; the Air5s is the only verified entry.

## Transport

The buds expose an SPP service whose 128-bit UUID is
`0000079A-D102-11E1-9B23-00025B00A5A5`. The RFCOMM channel number is discovered
from the SDP record rather than hard-coded; on the validated unit it is channel
5. The link can be opened while the same buds are the current A2DP output.

One long-lived channel is kept per connection. Closing the lid or powering the
buds off closes the channel, which the provider reports as a failed session and
clears all published state.

## Frame format

```
AA  <total len, LEB128>  00 00  <cmd LE16>  <seq>  <payload len LE16>  <payload>
```

- `total len` counts every byte after the length field, so an empty payload
  still produces `7`.
- Below 128 the length is one byte; larger frames use standard little-endian
  LEB128 (`AA 83 01` for a length of 131).
- `seq` is `0x01`-`0xFE` and replies echo it. Pushes use `0xFF`.
- Replies use `cmd | 0x8000`.
- Write acknowledgements use `0x84xx` and carry a single status byte; `00`
  means accepted. The provider still reads the state back before trusting a
  change.

Examples captured on the Air5s:

```
battery request   AA 07 00 00 06 01 00 00 00
battery reply     AA 0D 00 00 06 81 00 06 00 00 02 01 46 02 46
ANC query         AA 09 00 00 0C 01 01 02 00 01 01
ANC query reply   AA 0C 00 00 0C 81 02 05 00 00 01 01 10 00
set ANC           AA 0A 00 00 04 04 03 03 00 01 01 02
write ack         AA 08 00 00 04 84 03 01 00 00
```

The parser accepts frames split across reads, multiple frames per read, and
resynchronizes on a stray `0xAA`. It bounds both the declared frame length and
the reassembly buffer. Sliced messages (reserved byte 1 non-zero) are not
reassembled because none of the commands HeadBridge sends or parses need them.

## Commands used

| Command | Direction | Purpose |
| --- | --- | --- |
| `0x0103` | request → `0x8103` | Product id: `00 <id LE24>` |
| `0x0105` | request → `0x8105` | Firmware description (not shown in the UI) |
| `0x0106` | request → `0x8106` | Battery |
| `0x0109` | request → `0x8109` | Wearing state (polled for the ring guard) |
| `0x010C` | request → `0x810C` | Noise-control state, payload `01 01` |
| `0x0404` | write → `0x8404` | Set noise-control mode |
| `0x0204` | unsolicited | Multiplexed events, payload byte 0 is the event code |

### Battery

Reply payload after the status byte:

```
<status=00> <count> (<id> <level|flags>)*
```

- id `1` = left bud, `2` = right bud, `3` = charging case.
- level is the low 7 bits; bit 7 means charging.
- the case appears only while the buds are docked.
- HeadBridge publishes the lower earbud percentage, falling back to the case
  when no bud level is present.

Captured undocked reply: count 2, left `0x46` (70%), right `0x46` (70%).

### Noise control

Query `0x010C 01 01` replies `00 01 01 <mode LE>`; the mode is 1-4 bytes.
Pushes use event code `03` with the same `01 01 <mode LE>` body.

Reported masks are not the same table as the write bits:

| Raw mask | Meaning |
| --- | --- |
| `0x0008` | Off |
| `0x0002` | Noise cancellation (generic) |
| `0x0010` / `0x0020` / `0x0040` / `0x0080` | ANC levels (all shown as one mode) |
| `0x0100` / `0x0200` | Ambient / transparency |

Set payload: `01 01 <mask LE>` where the mask has the model's bit set.

Air5s (`0x06C810`) bits, verified by writing each and reading the state back:

| Mode | Bit | Payload |
| --- | --- | --- |
| Off | 0 | `01 01 01` |
| Noise cancellation | 1 | `01 01 02` |
| Ambient | 2 | `01 01 04` |

Writing bit 1 while the buds were in Deep ANC restored the previous ANC level
and reported `0x0010`; writing bit 0 reported `0x0008`; writing bit 2 reported
`0x0100`. All three writes were acknowledged with status `00`.

The Air5s exposes three depth levels: Light `0x40`, Deep `0x10`, and Smart
`0x80`. Each is written with `0x0404 01 01 <bit>` and reported back through
`0x010C 01 01`. Smart's current level is read with `0x010C 04 01` ->
`00 04 01 <mask LE>`. A continuous level write `0x0404 01 02 <level>` was
rejected with ACK `02` for every tested value, and the level read
`0x010C 01 02` returns malformed data. The app therefore exposes a three-level
picker, not a strength slider.

The touch-and-hold cycle is a bitmask read with `0x010C 02 01` and written with
`0x0404 02 01 <mask>` (bit 0 off, bit 1 ANC, bit 2 ambient). The validated unit
accepted `0x03` (off + ANC) and `0x07` (off + ANC + ambient) and read them back;
the app requires at least two selected modes.

Other models use different bit tables. They must not reuse the Air5s table
without hardware validation, so HeadBridge advertises battery only until a
model profile is verified.

## Hardware verification

| Item | Value |
| --- | --- |
| Headphones | OPPO Enco Air5s |
| Product id | `0x06C810` |
| Firmware (decoded from `0x8105`) | `163.163.102` |
| macOS | 15.8.1 (24H32) |
| Date | 2026-10-24 |

Exercised on the physical device through the shipped provider code:

- automatic attachment while the buds were the Mac's A2DP output;
- initial product-id, battery, and noise-control reads before publishing ready;
- battery `70% / 70%`, not charging;
- Off → Noise Cancellation → Ambient writes, each confirmed by a follow-up
  query;
- restore-on-connect: a saved Ambient profile changed the buds from Noise
  Cancellation to Ambient after the initial reads;
- disconnect cleared battery, capabilities, and noise state;
- reconnect re-read the battery and applied the saved profile again;
- the built menu-bar app connected to the buds, displayed `70%` (later `60%`)
  live in the menu bar, and cycled Noise Cancellation -> Ambient -> Off ->
  Noise Cancellation through its Control Center notification path.

Not exercised in the initial battery/noise pass:

- models other than the Air5s;
- controlling the buds from two apps at the same time.

The later Air5s validation below covers case battery, wearing, the multipoint
list, EQ, gestures, firmware display, and the host-side ring guard. The audible
find-my-earbuds ring was not used as a validation step.

## Air5s feature discovery

The Air5s handshake (`0x8100`) returns an 8-byte command bitmap, and `0x010D`
lists the feature switches the firmware actually has. Decoding both on the
validated unit exposed more controls than the initial battery/noise
implementation:

| Feature switch | Id | Observed |
| --- | --- | --- |
| Auto play/pause | `04` | on |
| Game mode / low latency | `06` | on |
| Golden Sound (hearing profile) | `0B` | off, no profile stored |
| Dual connection | `11` | on |
| Hi-Res quality | `18` | off |
| Spatial audio | `1B` | on |
| Game sound effects | `27` | on |
| Game sound list | `28` | no selection |
| Windows Swift Pair | `37` | on |

Additional controls verified by writing and reading back, then restoring the
original value:

| Control | Frame | Result |
| --- | --- | --- |
| Spatial audio on/off | `0x0403 1B 00/01` | feature flag and `0x012A` both changed `1 <-> 0` |
| Spatial type | `0x012A` | `00 <type>`; only type 1 (fixed) was observed |
| Game mode on/off | `0x0403 06 00/01` | changed `1 <-> 0` |
| Game sound type | `0x0423 <type> 01`, read `0x012B` | types 3 (shooting) and 0 (off) |
| Equalizer preset | `0x0406 <id>`, read `0x010F` | ids 0/1/2 built-in, custom presets from `0x0122` |
| EQ change push | `0x0504 <id>` | arrives after a successful select |
| Spatial type | `0x0422 00/01` | direct switch; also updates feature `1B` |
| Feature switch | `0x0403 <id> 00/01` | `04`, `0B`, `11`, `37` verified with read-back |

Spatial audio uses `0x0422` rather than the feature write: one frame switches
the type and the buds update `1B` themselves. Any audible crossfade after that
frame is applied by the earbuds' DSP, not by an app-side delay.

The writable switches are auto play/pause (`04`), dual connection (`11`), and
Windows Swift Pair (`37`); Golden Sound (`0B`, not exposed) is writable only when `0x0115`
returns a stored record. The app also writes spatial type `0/1/2` (`0x0422`),
alert volume (`0x0427`), find-my-earbuds (`0x0400`), dual-device actions
(`0x0429`), and the full gesture table (`0x0401`). Gesture writes, alert volume,
and the dual-device list/read-back were exercised. Find-my-earbuds has a
host-side fresh-wearing guard; the audible ring itself was not used as a
validation step.

Hi-Res (`18`):
the Air5s refused it on an AAC link (ACK status `02`) and a write can close the
RFCOMM channel. Game sound effects (`27`) are implied by `0x0423`; selecting
type `0` clears `27` and type `3` sets it. Everything else in the screen is
read-only.

Air5s built-in EQ slots are `0` Ultimate, `1 Thundering Bass`, `2 Pure Vocals`.
The validated unit also had one custom 10-band preset (`"Balance v2"`, id 4,
31 Hz +0, 62 -2, 125 -1, 250 0, 500 0, 1 kHz 0, 2 kHz -3, 4 kHz +1, 8 kHz -3,
16 kHz -1 dB).

Read-only state that is available for a richer UI:

- current codec `0x0114` (AAC/`2` during validation) and offered mask `0x0123`;
- dual-connection list `0x0112` and preferred device `0x0132 02`;
- gesture table `0x0108` (14 entries: single play/pause, double voice
  assistant, triple none, hold ANC cycle, slide volume, call double
  answer/end, call long hold decline);
- wearing state `0x0109` (polled every 1.5 s and used by the fresh ring guard),
  alert volume `0x0130` (1-10, observed 10);
- firmware `0x0105`, product id `0x0103`.

Not supported or not offered by this firmware/model, so HeadBridge does not
send them:

- BassWave (`1D` absent, `0x0124` unanswered);
- personalised ANC (`0x0412` bit clear, `0x011A` reports no stored result);
- wind reduction;
- the `0x03xx` firmware-upgrade command range, which HeadBridge never sends.

Golden Sound (`0B`) is OPPO's hearing-profile enhancement: it needs a record
built from a hearing test (`0x040D 02`) and optionally an ear scan
(`0x040D 04`), stored on the buds. `0x0115` answers `01 03` on the validated
unit, which means no record. The Air5s refuses every `0x040D` command with
status `01`, including stop, so the hearing-profile UI has been removed from
the app; only the three preset EQs and the custom EQ remain.

Hi-Res (`18`) is tied to LHDC and is not a free-standing toggle. With the link
on AAC, `0x0403 18 01` is refused (ACK status `02`); with spatial off it is
still refused. Forcing `0x041A 08 01 00` (LHDC V5 + Hi-Res) was accepted and
restarted the link; the buds then reported codec `7` (LHDC) and `18 = 1`.
Writing `18` again closes the RFCOMM channel. The app therefore provides a
Hi-Res switch. Turning it on forces `0x041A 08 01 00`; turning it off writes
`0x0403 18 00`, because the codec command restarts the link without clearing
the flag. Both paths reconnect and then read `18` back. On the validated Mac
later reads showed the link on AAC with `18 = 1`; Hi-Res only changes LHDC V5
settings, so the UI warns when the flag is on but the current codec is not
LHDC/LDAC.

Spatial and Hi-Res are mutually exclusive. Turning spatial on while Hi-Res is
on writes `18 00`, waits for the reconnect, and then re-applies the requested
spatial type. The first such toggle therefore reconnects; later spatial
changes are direct.

## Ear scan and head tracking

The Air5s model entry has `hearingScan` but not `earScan`, and `0x011E` stays
unanswered. More importantly, the validated unit answers `01` to every
`0x040D` command, including `02 00` (stop), and to `0x040E` tones. The tests
were repeated with audio paused, dual connection off, and Golden Sound on.
The Golden Sound page has therefore been removed entirely; the three preset
EQs and the custom EQ remain usable.

`0x0422 02` is accepted and reports type 2, but `0x0134` (head gesture) is
unanswered and the model has no head-motion/spatial-mode entry. The mode is
kept as an experimental option with a warning; Fixed is the usable mode.

## Wearing and touch slots

`0x0109` reports one status byte per bud and one for the case. The exposed bits
are out-of-case (0), in-ear (1), lid-open (2), and a vendor flag (3); there is no
per-capacitive-point data in the protocol. The gesture table has 14 slots (five
per bud plus two call gestures per bud); the OPPO page exposes all of them and
writes the whole table on every change. Every function code is offered for
every slot, not just the vendor's recommended subset. The firmware accepts the
write and reads the table back (ANC cycle on a single tap was verified on
hardware); combinations the gesture engine does not implement may have no
audible effect.

The screen groups entries into "main" and "call" rows and merges the split
slide entries into one row; changing a merged row writes every table entry
that belongs to it. The table is stored on the earbuds, not in macOS, so it
survives a normal case/reconnect cycle. It is only lost on a factory reset or
firmware update that clears settings.

Find-my-earbuds only starts when a complete both-out-of-ear report is at most
3 seconds old. Polling runs every 1.5 seconds; a missing or partial report
invalidates the cache, and an in-ear report stops an active ring. Host-side
tests cover fresh, stale, no-response, partial, in-ear, and both-out states.

## Codec picker

The app exposes AAC, LDAC, LHDC, and LHDC V5 through `0x041A`. Changing the
codec restarts the link. On a multipoint connection each host negotiates its
own codec; setting LHDC here cannot force the phone's link. The phone must
support and select LHDC itself.

## Display state

The codec is read with `0x0114` on connect, on every multipoint-list event, and
every 15 seconds while ready, because the buds do not push codec changes. The
provider clears the cached codec name on every disconnect so a stale value
cannot survive into the next session. The value is the earbuds' per-link
report; macOS may negotiate a different codec than the phone. This is why the
screen can show AAC while the OPPO phone's link is LHDC.

Gesture remapping (`0x0401 <count> <entries>`), dual-device connect/disconnect
(`0x0429`), alert volume (`0x0427`), find-my-earbuds (`0x0400`), and codec
selection (`0x041A`) are accepted by this firmware. Gesture writes, alert
volume, and the dual-device list/read-back were exercised; the audible find
ring and switching the other host's audio were not used as validation steps.

## Sources

Wire facts were cross-checked with these public projects; only behavior and
packet layouts were used, and no source code was copied:

- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) (AGPL-3.0-or-later): OPPO headphones protocol, command ids, battery and firmware framing.
- [QuickBuds](https://github.com/spizganed/QuickBuds) (GPL-3.0): legacy RFCOMM protocol notes and the model catalogue entry for `06C810`, used to confirm the ANC write slots.
- [Nord Buds 2 battery notes](https://asubedi.com.np/blog/nord-buds-2-battery-mac/) (independent write-up): SPP query shape and channel discovery on macOS.
