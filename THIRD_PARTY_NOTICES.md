# Third-party notices and research credits

## Distributed dependency

HeadBridge links [Sparkle](https://github.com/sparkle-project/Sparkle) 2.9.5 for
signed software updates. Sparkle and its bundled third-party components are
distributed under the terms reproduced in
[`Resources/Licenses/Sparkle-LICENSE.txt`](Resources/Licenses/Sparkle-LICENSE.txt).

## Protocol research

HeadBridge does not vendor or link a third-party headphone protocol client. Its
Bowers & Wilkins and Sony transports and protocol implementations are written
in Swift and distributed under HeadBridge's MIT license. Fact-oriented
contributor documentation is available in the
[`Bowers & Wilkins RPC notes`](docs/BowersWilkinsRPC.md),
[`Sony MDR V1 notes`](docs/SonyMDRV1.md), and
[`Sony MDR V2 adapter notes`](docs/SonyMDRV2.md).

Public reverse-engineering projects used to cross-check protocol facts and independently captured traffic include:

- [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) (MIT);
- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) (AGPL-3.0-or-later);
- [sony-connect-osx](https://github.com/tanat/sony-connect-osx) (reference only; no license file was present when reviewed).

No source from Gadgetbridge or sony-connect-osx is incorporated into HeadBridge.

HeadBridge is not affiliated with or endorsed by Sony Corporation or Bowers & Wilkins.
