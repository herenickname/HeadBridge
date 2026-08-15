# HeadBridge privacy

HeadBridge has no analytics, advertising SDK, account, or cloud sync. Headphone
control happens locally over Bluetooth and Core Audio.

## Data stored on this Mac

HeadBridge stores preferences and optional restore-on-connect profiles in the
app's macOS preferences domain. It stores battery history for up to 90 days in:

```text
~/Library/Application Support/HeadBridge/BatteryHistory.plist
```

Battery history contains the provider ID, a stable local device identifier
(for example a Bluetooth address or Core Bluetooth UUID), display/vendor names,
timestamps, battery percentages, charging state, and random local session IDs.
The archive is written with owner-only file permissions. Each device page has a
**Clear…** action, and the data is never uploaded by HeadBridge.

## Network access

Sparkle contacts the configured GitHub Releases feed when automatic update
checks are enabled or the user chooses **Check for Updates…**. Update checks can
be disabled in HeadBridge Settings. Provider control and battery history do not
require an internet connection.

## Diagnostics

Advanced protocol diagnostics are disabled by default. When enabled, raw values
and transport logs may contain headphone names, serial numbers, Bluetooth
addresses, and paired-source information. HeadBridge does not upload these
diagnostics automatically.
