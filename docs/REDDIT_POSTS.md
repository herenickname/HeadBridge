# Reddit announcement drafts

These are ready-to-post English drafts. They have not been submitted anywhere.
Open each community's rules again in the composer before publishing.

## Posting order and current rules

1. Start with `r/BowersWilkins` and `r/SonyHeadphones`. Use the community-specific
   screenshots below and answer hardware questions in the comments.
2. Use `r/macapps` only after the account has at least 10 community-karma points
   and has completed its **Read The Rules** step. The title must start with
   `[OS]`, the post needs Problem / Comparison / Pricing, and self-promotion is
   limited to once per developer in 30 days. A new repository may have to be
   submitted to the **App Pile** megathread instead of the main feed.
3. `r/MacOS` permits self-promotion only on Saturdays, 00:00-23:59 UTC, once per
   week. The post must disclose that its author is the developer, explain the
   project, link the public repository, and include a good screenshot.

The public screenshots contain no visible Bluetooth address, serial number, or
firmware value.

## r/BowersWilkins

**Title**

> I built a free native macOS controller for B&W headphones

**Post**

> I own a Px7 S3 and got tired of reaching for the phone app whenever I wanted to change something, so I built HeadBridge.
>
> It lives in the macOS menu bar and deliberately looks like the native Sound panel. On my Px7 S3 it controls ANC / pass-through / off, five-band EQ, True Immersion, wear detection and sensitivity, standby time, the quick-action button, and voice prompts. It also shows battery history and can restore my preferred settings after a phone changes them.
>
> This is not meant to pretend that unofficial headphone tools never existed. I wanted one free, open-source app that can support B&W, Sony, and future community providers in the same UI.
>
> Px7 S3 is the only B&W model I can personally test, so other recent PX/PI models are marked experimental rather than "supported". Reports and hardware-tested PRs are welcome.
>
> It is an early beta, MIT licensed, with no account or analytics. The GitHub build is self-signed rather than Apple-notarized, and the README explains the installer and Gatekeeper behavior before the download command.
>
> GitHub: https://github.com/herenickname/HeadBridge
>
> I would love feedback from other B&W owners. Please include the exact model and which controls worked or did not work.

**Attach in this order**

1. `assets/screenshots/menu-controls.png`
2. `assets/screenshots/bowers-wilkins-settings.png`
3. `assets/screenshots/battery-history.png`

## r/SonyHeadphones

**Title**

> I made a free native macOS controller for Sony headphones (WH-1000XM3 tested)

**Post**

> I still use a WH-1000XM3. Its separate headset volume on macOS was the annoyance that pushed me to build HeadBridge.
>
> HeadBridge is a free, open-source menu-bar app styled after the native macOS Sound panel. On my XM3 it supports ANC, ambient sound, wind reduction, ambient level, EQ presets and manual bands / Clear Bass, Surround (VPT), sound position, DSEE HX, touch control, NC optimizer, automatic power-off, sound-quality mode, battery, codec, and optional macOS-to-headphone volume sync.
>
> SonyConnect already provides a useful desktop controller for Sony models. The difference here is the all-in-one approach: Sony and Bowers & Wilkins providers share the same system-style menu, audio routing, battery history, and restore-on-connect behavior.
>
> WH-1000XM3 is the only Sony model I physically own and test. Other MDR V1 devices are experimental, and V2 / Link2 is detected but not implemented yet. Hardware-tested reports and PRs are welcome.
>
> HeadBridge is an early beta, MIT licensed, and has no account or analytics. The current release is self-signed rather than Apple-notarized; the README explains the install and Gatekeeper details plainly.
>
> GitHub: https://github.com/herenickname/HeadBridge
>
> If you try it, I am especially interested in reconnect reliability, noise modes, and volume behavior on your exact model.

**Attach in this order**

1. `assets/screenshots/menu-sony-controls.png`
2. `assets/screenshots/sony-settings.png`
3. `assets/screenshots/sony-battery-history.png`

## r/macapps

Post to the main feed only if the account satisfies the current trust and
community-karma rules. Otherwise use the current App Pile megathread. Select the
appropriate open-source/free flair offered by the composer.

**Title**

> [OS] HeadBridge: native macOS controls for B&W and Sony headphones (free)

**Post**

> I built HeadBridge because macOS can play audio through third-party headphones, but most of their useful controls are still trapped in vendor phone apps.
>
> It adds a native Sound-style menu for supported Bowers & Wilkins and Sony headphones: output and input switching, battery, ANC / ambient modes, sticky microphone selection, restore-on-connect, local battery history, and vendor-specific controls. I have tested it on a Px7 S3 and WH-1000XM3.
>
> Comparison: SonyConnect is a solid Sony-specific desktop utility, while apps such as eqMac focus on processing system audio. HeadBridge is different because it combines vendor protocol controls from multiple headphone makers with macOS audio routing in one extensible menu.
>
> Price: $0. No subscription, IAP, account, ads, analytics, or telemetry. The source is MIT licensed.
>
> Caveat: this is an early beta. The release uses a stable project self-signed certificate, not Apple Developer ID notarization. The README explains what the installer verifies, why it removes quarantine, and how to inspect it or build from source.
>
> GitHub, screenshots, and install instructions: https://github.com/herenickname/HeadBridge

**Attach in this order**

1. `assets/screenshots/menu-controls.png`
2. `assets/screenshots/menu-sony-controls.png`
3. `assets/screenshots/bowers-wilkins-settings.png`
4. `assets/screenshots/sony-settings.png`

## r/MacOS (Saturday UTC only)

**Title**

> I built a native macOS Sound-style menu for third-party headphones

**Post**

> I am the developer of HeadBridge, a free and open-source menu-bar app that gives supported Bowers & Wilkins and Sony headphones an AirPods-like place in macOS.
>
> It combines system output/input controls with battery, ANC / ambient modes, sticky microphone selection, restore-on-connect, local battery history, and vendor controls. I have tested it on a Px7 S3 and WH-1000XM3; other models are clearly marked experimental until an owner validates them.
>
> Vendor-specific desktop utilities already exist. My goal was an all-in-one, contributor-extensible version that follows the native macOS Sound-menu style and remains free under MIT.
>
> There is no account, analytics, or cloud sync. It supports macOS 14+, while the optional Control Center extension needs macOS 26. The current GitHub release is project-self-signed but not Apple-notarized, and the README explains the installer and Gatekeeper behavior up front.
>
> Source, release, screenshots, and install instructions: https://github.com/herenickname/HeadBridge

**Attach in this order**

1. `assets/screenshots/menu-controls.png`
2. `assets/screenshots/menu-sony-controls.png`
3. `assets/screenshots/bowers-wilkins-settings.png`
4. `assets/screenshots/sony-settings.png`
