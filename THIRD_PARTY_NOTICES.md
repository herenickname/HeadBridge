# Third-party notices and research credits

## Distributed dependency

HeadBridge links [Sparkle](https://github.com/sparkle-project/Sparkle) 2.9.5 for
signed software updates. Sparkle and its bundled third-party components are
distributed under the terms reproduced in
[`Resources/Licenses/Sparkle-LICENSE.txt`](Resources/Licenses/Sparkle-LICENSE.txt).

## Protocol research

HeadBridge does not vendor or link a third-party headphone protocol client. Its
Bowers & Wilkins, Sony, and OPPO transports and protocol implementations are
written in Swift and distributed under HeadBridge's MIT license. Fact-oriented
contributor documentation is available in the
[`Bowers & Wilkins RPC notes`](docs/BowersWilkinsRPC.md),
[`Sony MDR V1 notes`](docs/SonyMDRV1.md),
[`Sony MDR V2 adapter notes`](docs/SonyMDRV2.md), and
[`OPPO Enco RFCOMM notes`](docs/OppoRFCOMM.md).

Public reverse-engineering projects used to cross-check protocol facts and independently captured traffic include:

- [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) (MIT);
- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) (AGPL-3.0-or-later);
- [omarchy-bw-headphones](https://github.com/DominicBoettger/omarchy-bw-headphones) (MIT, revision `b04ffb8`), for the Bowers & Wilkins bass/treble command identifiers and per-model ANC values;
- [QuickBuds](https://github.com/spizganed/QuickBuds) (GPL-3.0), used only to cross-check OPPO command ids, ANC slots, and the product catalogue entry;
- [sony-connect-osx](https://github.com/tanat/sony-connect-osx) (reference only; no license file was present when reviewed).

No source from Gadgetbridge, QuickBuds, or sony-connect-osx is incorporated
into HeadBridge; only wire facts and packet layouts were used.

HeadBridge is not affiliated with or endorsed by Sony Corporation or Bowers & Wilkins.
