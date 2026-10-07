# Bowers & Wilkins RPC protocol notes

This document records the wire behavior implemented independently by
HeadBridge and verified against the hardware listed below. It is intended as a
clean-room reference for contributors, not as vendor documentation or a claim
that every Bowers & Wilkins model uses the same protocol.

## Transport discovery and readiness

The current provider uses CoreBluetooth. A model name is only a discovery
prefilter: HeadBridge scans BLE advertisements, matches the advertised name to
a connected Core Audio Bluetooth output, connects to that peripheral, and then
discovers all services and characteristics. It does not assume a service UUID.

Some headphones do not advertise their model name over BLE. The original Px8
advertises as `LE_BWHP` while Core Audio reports `Px8`, so that generic name is
accepted as a discovery candidate. It is selected automatically only as a
fallback when no model-named advertisement matches and a supported Bowers &
Wilkins Core Audio output is connected, and only after the scan has run for
two seconds, so that a model-named advertisement arriving later in the same
scan is not pre-empted. The required characteristics remain
the compatibility check.

A generic advertisement cannot distinguish two nearby headphones that both
advertise this way, so the strongest candidate is tried first and checked
afterwards. The headphone reports its Bluetooth address over RPC (`08:02`),
and on the original Px8 it equals the paired audio device's address. For a
generically advertised peripheral HeadBridge compares that address with the
paired headphones macOS reports as connected and drops the link on a mismatch,
before any restore profile is applied. When either side is unavailable the
link is kept.

The original Px8 advertises under a new BLE identifier after every connection,
so a rejected peripheral cannot be recognised by identifier. Automatic
connection therefore stops after three consecutive rejections until the audio
route changes, Bluetooth restarts, or the user connects manually. HeadBridge
does not yet try the other candidates of the same scan in turn.

The comparison uses the paired-device inventory, which is refreshed in the
background whenever the Core Audio device list changes. Someone who owns two
generically advertised headphones and switches between them can therefore be
compared against a list that still names the previous pair, and have the
correct headphone dropped once. The next automatic attempt, about five seconds
later, uses the refreshed list. HeadBridge does not refresh and re-check before
dropping. The check is
not applied to model-named advertisements, because the address equality has
not been confirmed on those models.

The RPC characteristic UUIDs currently used are:

| Direction | Characteristic UUID | Required for readiness |
| --- | --- | --- |
| Requests written by HeadBridge | `ada50ce9-67b8-4a97-9d8e-37e1d083156c` | Yes |
| Responses received by HeadBridge | `cb909093-3559-4b0c-9a7f-3f1773122fdc` | Yes, with notifications enabled |
| Unsolicited device notifications | `df55d475-9a32-457a-9e20-38cf14e853fb` | No |

The provider publishes the transport as ready only after both required
characteristics are present and notification setup on the response
characteristic has succeeded. It then stops scanning and sends its initial
read-only queries. Loss of the matching Core Audio route closes the BLE control
session and clears its published device state.

Writes are serialized through a bounded queue. Repeated pending writes for the
same command replace the older pending value. The request characteristic is
written with a GATT response when it supports that property, and without one
otherwise. This GATT acknowledgement is transport-level only; device state is
confirmed through the RPC response described below.

## RPC envelope

A command is identified by an eight-bit namespace and an eight-bit command ID.
HeadBridge displays that pair as `namespace:id`, while the ID appears before
the namespace on the wire. Multi-byte lengths and error values in this envelope
are little-endian.

Outgoing requests have one of these forms:

```text
size | 0B 12 | command ID | namespace
size | 0B 92 | command ID | namespace | payload length (LE16) | MessagePack payload
```

`size` is the one-byte length of the bytes that follow it. `0x120B` identifies
a request without a payload and `0x920B` identifies a request with one.

Incoming characteristic values are decoded without that leading request-size
byte:

```text
0C 12 | command ID | namespace | error
0C 92 | command ID | namespace | error (LE16) | payload length (LE16) | MessagePack payload
0D 12 | command ID | namespace
0D 92 | command ID | namespace | payload length (LE16) | MessagePack payload
```

The `0x120C`/`0x920C` forms are replies and the `0x120D`/`0x920D` forms are
notifications. A zero reply error is treated as success. Payloads are applied
to public state only after successful decoding and, for replies, a zero device
error.

The payload codec supports the MessagePack values used by the current command
catalog: null, booleans, signed and unsigned integers, floats, strings, binary
data, arrays, and string-keyed maps. Its decoder rejects trailing bytes,
unbounded collections, excessive nesting, and unsupported markers. Contributors
should extend it only when a captured, hardware-verified payload requires an
additional representation.

## Reply and notification correlation

This protocol envelope has no transaction ID in the fields currently known to
HeadBridge. Replies and notifications are correlated to state by the
`namespace:id` command key. The write queue therefore serializes GATT writes,
but it does not wait for an RPC reply with a matching sequence number.

For a writable setting, HeadBridge sends the known `SET` command and then sends
the corresponding `GET` after a short delay. The successful `GET` reply is the
authoritative confirmation. Unsolicited notifications use the same command key
and pass through the same state mapper when their payload shape is known.

## Setter read-back timing

On the original Px8 a setter is not applied instantly. In a capture of the
wear-sensor setter (`0A:02`), reads of `0A:01` sent before the setter reply
arrived returned the previous value, and one returned device error `3`; reads
sent after the reply returned the new value. HeadBridge therefore issues the
confirming read when the setter's reply arrives, and a control whose read has
succeeded once in a session is kept even if a later read returns an error.

The same model sends an unsolicited `03:01` notification with the new ANC value
when the mode is changed with the button on the headphones.

## Capability probing

After transport readiness, `BowersWilkinsProvider` sends a fixed set of safe
primary `GET` requests. A shared capability is advertised only after the
corresponding query has produced a reply with device error `0`. For example,
successful battery, ANC, EQ, wear-sensor, spatial-audio, voice-prompt, standby,
button, and local-name reads independently enable those controls.

Consequently, matching a PX/PI model name or finding the three characteristics
does not prove feature compatibility. An unsupported command may return a
nonzero device error; HeadBridge records that result but does not expose the
capability. The opt-in diagnostics screen can issue a larger read-only probe
set. Its results must not be promoted to a control until the payload and safe
value range have been verified on hardware.

## ANC mode values

The ANC mode commands (`03:01` get, `03:02` set) carry one integer, but its
meaning differs between hardware generations:

| Mode | Px7 S3 | Original Px8 |
| --- | --- | --- |
| Off | `0` | `1` |
| Noise cancellation | `1` | `2` |
| Pass-through | `2` | `3` |

The original Px8 rejects `0` with device error `6` and acknowledges an out-of-range
`4` without changing the mode. HeadBridge translates through `ANCWireProfile`.
The Px8 column is used only when the device was discovered under the generic
`LE_BWHP` name and the single connected Bowers & Wilkins Core Audio output is
named `Px8`. For any other generically advertised model the values are
unverified, so noise control stays hidden and no ANC value is written. Public
sources list other mappings for older models (for example off/low/high/auto);
add a profile only after confirming the values on that hardware.

## Bass and treble

Headphones without the five-band EQ expose a two-band tone control instead:

| Setting | Get | Set | MessagePack payload |
| --- | --- | --- | --- |
| Bass | `04:18` | `04:17` | Integer, `-60` through `60` |
| Treble | `04:1A` | `04:19` | Integer, `-60` through `60` |

On the original Px8 both setters reply with device error `0` and read back the
written value, including negative values; `61` is rejected with device error
`8`. The unit is reported elsewhere as tenths of a decibel but has not been
measured, so HeadBridge shows the raw value. The controls appear only when both
reads succeed.

## Safety boundaries

The default application exposes only the known non-destructive reads and
settings in its command catalog. Factory reset, pairing-list mutation, firmware
update, DFU, and other destructive or difficult-to-recover operations are out
of scope. The paired-source inspector is read-only.

Protocol contributions should contain independently observed wire facts and a
new Swift implementation. Do not submit decompiled vendor implementation,
vendor assets or firmware, or code copied from a project whose license is
incompatible with HeadBridge.

New commands need exact-frame and malformed-input tests, documented ranges,
successful reply handling, and hardware verification. Unknown or only inferred
values should remain diagnostics rather than writable settings.

## Hardware status

The transport, primary queries, and exposed controls are hardware-validated on
Bowers & Wilkins Px7 S3 firmware `3.17.4.17`.

The original Px8 (RPC software version `0(20.0.2.0)`) is validated with the
exceptions below. Discovery under the generic advertised name, automatic
connection, reconnect after a power cycle, restore-on-connect, and all three
ANC modes were confirmed on hardware, as were the wear sensor, quick-action
button, voice prompts, and bass and treble. The quick-action button read
(`08:2B`) replies with a boolean on this model and the integer write is
accepted. Battery, charging, local-name, version, and serial reads reply with
device error `0`.

- Wear sensitivity: values `1` and `3` are accepted and read back, but no
  difference was observed between them, and which end is the more sensitive is
  unconfirmed on this model. The control is left visible.
- Standby timer: writes read back correctly; the timer was not left to expire.
- Local name: writing it was not exercised, so renaming is hidden for
  generically advertised models. On those models the Core Audio name also
  selects the ANC wire profile.
- The five-band EQ, EQ bypass, and spatial-audio reads return device error `1`,
  so those controls stay hidden.

Recent PX/PI names are accepted as
discovery candidates, but other models have not yet been verified. Their actual
compatibility must be established by characteristic discovery, successful
command replies, and a device-support report containing the exact model,
firmware, macOS version, and tested controls.
