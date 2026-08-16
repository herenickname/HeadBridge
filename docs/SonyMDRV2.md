# Sony MDR V2 / Link2 adapter notes

Sony MDR V2 keeps the framed/escaped message envelope used by V1, but it is a
separate protocol adapter rather than a new model provider.

## Detection

- V1 RFCOMM service: `96CC203E-5068-46AD-B32D-E316F5E069BA`
- V2 RFCOMM service: `956C7B26-D49A-4BA8-B03F-B17D393CB6E2`
- A known V1 init reply is four bytes including opcode `01`.
- A known V2 init reply is eight bytes including opcode `01`.

HeadBridge currently probes the V1 service and recognizes the V2 service. A V2
device receives an explicit unsupported-adapter error; it is never sent V1 SET
packets accidentally.

## Adapter boundary

The future V2 implementation belongs behind `SonyMDRProvider` alongside the V1
client. It can reuse framing, ACK sequencing, queue ownership, device routing,
battery history, and shared UI. It must provide V2-specific payload mappings;
notably battery and codec opcode families and NC/ambient subtypes differ, and
headphone volume is not assumed to exist until confirmed by the device.

Capabilities must be selected from the detected protocol plus a model/device
profile and then confirmed by successful state replies. A model name alone is
not sufficient proof of V1 or V2 compatibility.

## Cross-check references

- [Gadgetbridge Sony headphones implementation](https://codeberg.org/Freeyourgadget/Gadgetbridge) (AGPL-3.0)
- [SonyHeadphonesClient](https://github.com/Plutoberth/SonyHeadphonesClient) (MIT)

These sources were used to cross-check wire facts. Their implementation code is
not incorporated into HeadBridge.
