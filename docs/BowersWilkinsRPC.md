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
Bowers & Wilkins Px7 S3 firmware `3.17.4.17`. Recent PX/PI names are accepted as
discovery candidates, but other models have not yet been verified. Their actual
compatibility must be established by characteristic discovery, successful
command replies, and a device-support report containing the exact model,
firmware, macOS version, and tested controls.
