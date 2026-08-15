# Reddit announcement drafts

These are publication-ready drafts, not posted content. Before posting, check each community's current self-promotion rules and choose the closest available flair. Do not post all variants simultaneously or pretend to be an unaffiliated user.

The intended communities exist as `r/BowersWilkins`, `r/SonyHeadphones`, and `r/macapps`. Attach the final images listed in [`PRESS_KIT.md`](PRESS_KIT.md#screenshots), not development screenshots.

Posting notes checked before publication:

- `r/macapps` requires accepting **Read The Rules** before a post can be submitted; complete that step and re-check its promotion requirements in the composer.
- `r/MacOS` permits self-promotion only on Saturdays from 00:00 through 23:59 UTC, with at most one promotional post per week. Keep the author disclosure, project context, GitHub link, and at least one screenshot in the shorter adaptation below.
- No specific public rule text was exposed for `r/BowersWilkins` or `r/SonyHeadphones`; open each community's current rules immediately before submitting.

## r/BowersWilkins

**Suggested title**

> I built a free macOS Sound-style controller for B&W headphones (open source)

**Post**

> I wanted my Px7 S3 controls to feel like part of macOS instead of something that only exists in a phone app, so I built HeadBridge.
>
> It is a native menu-bar app styled after the macOS Sound menu. On my Px7 S3 it currently exposes battery and charging state, ANC / pass-through / off, five-band EQ, True Immersion, wear sensor and sensitivity, standby timer, quick-action behavior, and voice prompts. It also has restore-on-connect, so settings can be reapplied after a phone changes them, plus local per-device battery history.
>
> I know unofficial/vendor-specific headphone utilities already exist. The point here is not to claim that this is the first one: I wanted a free, open-source all-in-one app where B&W, Sony, and future providers share one native macOS interface.
>
> Honest compatibility note: I physically own and test only Px7 S3 on the B&W side. Other recent PX/PI models using the same RPC family are experimental until somebody tests them on the exact hardware. If you own one, the repo has a contributor guide specifically for opening it in Codex or Claude Code, adapting the provider with a current coding model, validating the controls on your headphones, and sending a Pull Request.
>
> It is an early beta, MIT licensed, and has no analytics or account. Current downloads are not signed/notarized by Apple, so the README explains the installer and Gatekeeper step plainly and also shows how to inspect the script or build from source.
>
> GitHub: https://github.com/herenickname/HeadBridge
>
> Feedback from other B&W owners would be genuinely useful—especially exact model, firmware, and which controls work.

**Attach**

1. `assets/screenshots/menu-controls.png`
2. `assets/screenshots/settings-overview.png`
3. Add `assets/screenshots/battery-history.png` later if a fresh release-build capture is available.

## r/SonyHeadphones

**Suggested title**

> I made a free native macOS controller for Sony headphones — WH-1000XM3 tested

**Post**

> I still use a WH-1000XM3, and its independent headset volume on macOS was the thing that pushed me to build HeadBridge.
>
> HeadBridge is a free, open-source menu-bar app that follows the macOS Sound-menu style. For my XM3 it currently supports noise cancellation, ambient sound, wind reduction, ambient level, EQ presets and manual bands/Clear Bass, Surround (VPT), sound position, DSEE HX, touch sensor, NC optimizer state, auto power-off, sound-quality/stable-connection mode, battery/codec, and optional one-way macOS → headphone volume sync.
>
> This is not a claim that desktop Sony controllers are new—SonyConnect and other vendor-specific projects already exist. My goal is an all-in-one architecture where Sony, Bowers & Wilkins, and community-added headphone providers live behind the same native macOS UI.
>
> Compatibility is intentionally conservative. WH-1000XM3 is the only Sony model I physically own and test. Other MDR V1 devices are experimental, and MDR V2/Link2 is detected but not implemented yet. If you have another Sony model, you can clone the repo, use Codex or Claude Code with a current capable model to adapt the provider, test it against your real hardware, and send a Pull Request. The contribution guide explains the protocol and test boundaries.
>
> HeadBridge is MIT licensed, has no account or analytics, and stores battery history locally. It is still an early beta. Releases are currently unsigned/unnotarized by Apple; the README is explicit about the install script, Gatekeeper bypass, manual install, and build-from-source options.
>
> GitHub: https://github.com/herenickname/HeadBridge
>
> If you try it, I would especially like to know the exact model/firmware and whether reconnect, noise controls, and volume behavior stay reliable.

**Attach**

1. `assets/screenshots/menu-controls.png`
2. `assets/screenshots/settings-overview.png`
3. Add `assets/screenshots/sony-settings.png` later if a fresh release-build capture is available.

## r/macapps

**Suggested title**

> HeadBridge — free open-source AirPods-style controls for B&W and Sony headphones

**Post**

> I built HeadBridge because third-party headphones show up in macOS as audio devices, but their useful controls usually remain isolated in vendor phone apps.
>
> HeadBridge is a native menu-bar app designed to look and behave like the macOS Sound menu. It combines output selection and live volume with active-headphone battery, noise modes, `Option`-click input selection, Sticky Input (restore the microphone macOS silently replaced), restore-on-connect profiles, local battery history, Launch at Login, and provider-specific controls.
>
> The current providers are Bowers & Wilkins RPC and Sony MDR V1. I have tested Px7 S3 and WH-1000XM3 on actual hardware. The B&W side includes EQ, True Immersion, sensors, and timers; the Sony side includes ambient/NC/wind modes, EQ, VPT, DSEE HX, sound-quality mode, and optional macOS-to-headphones volume sync.
>
> Similar apps already exist for individual vendors, and I am not trying to erase that work. The difference I wanted was one free, MIT-licensed app with a provider interface that other headphone owners can extend. If I do not own a model, I cannot honestly validate it; contributors can use Codex or Claude Code to adapt the closest provider, then test it on their own hardware and submit a Pull Request.
>
> Privacy-wise, there is no account, analytics, ads, telemetry, or cloud sync. Device control and battery history stay local. The optional macOS 26 Control Center extension is included; the regular menu-bar app supports macOS 14+.
>
> One important caveat: the current GitHub builds are ad-hoc signed and not Apple-notarized. The README explains exactly why Gatekeeper blocks them, what the install script changes, how to inspect it first, and how to build from source. It is an early beta, so I would rather disclose that prominently than hide it behind a vague install instruction.
>
> GitHub: https://github.com/herenickname/HeadBridge
>
> UI feedback and hardware-tested provider contributions are welcome.

**Attach**

1. `assets/screenshots/menu-controls.png`
2. `assets/screenshots/settings-overview.png`

## Optional shorter r/MacOS adaptation

Use this only if `r/MacOS` rules permit app announcements.

**Suggested title**

> A native macOS Sound-style menu for third-party Bluetooth headphones

**Post**

> I made HeadBridge, a free and open-source menu-bar app that gives supported Bowers & Wilkins and Sony headphones an AirPods-like place in macOS.
>
> It combines system audio output/input controls with battery, ANC/ambient modes, Sticky Input, restore-on-connect, battery history, and vendor controls. I have hardware-tested Px7 S3 and WH-1000XM3; other models are clearly marked experimental and need owners to validate them.
>
> There are already useful single-vendor utilities. HeadBridge is my attempt at an all-in-one, contributor-extensible version that follows the native macOS Sound-menu style and remains free under MIT.
>
> No account, analytics, or cloud sync. macOS 14+; Control Center integration needs macOS 26. Current builds are unsigned/unnotarized, and the README discloses the Gatekeeper/install flow before the download command.
>
> Source, release, screenshots, and install instructions: https://github.com/herenickname/HeadBridge
