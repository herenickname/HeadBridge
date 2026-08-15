# Changelog

All notable user-visible changes will be documented here. HeadBridge follows
[Semantic Versioning](https://semver.org/) once public releases begin.

## 0.1.0 - 2026-08-15

### Added

- Multi-provider menu-bar and Settings architecture.
- Bowers & Wilkins RPC and Sony MDR V1 providers.
- Persistent battery history, restore on connect, Sticky Input, Launch at
  Login, Control Center controls, and EdDSA-verified Sparkle updates.
- Universal ad-hoc macOS release and inspectable `/Applications` installer.

### Security

- Bounded Sony framing and MessagePack collection/depth parsing.
- Early duplicate-instance guard before Bluetooth providers are constructed.
- Owner-only permissions for persisted battery history.
- Ad-hoc-only build checks that reject Apple signing identities and team IDs.
