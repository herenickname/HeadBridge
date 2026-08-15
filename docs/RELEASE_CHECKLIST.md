# First public release checklist

The code and automation can be prepared without publishing. Complete the human
and account-specific items below before announcing HeadBridge on GitHub or
Reddit.

## Identity and assets

- [ ] Confirm the canonical GitHub owner/repository and update the default feed
  URL plus issue-template security link if it is not `herenickname/HeadBridge`.
- [ ] Treat `io.github.herenickname.HeadBridge` and its Control Center extension
  ID as frozen after the first distributed build.
- [x] Add a real application icon before the first downloadable release.
- [x] Add menu and Settings screenshots to the repository.
- [ ] Capture optional Sony-controls and battery-history close-ups.
- [ ] Add a 1280×640 GitHub social preview.

## Hardware matrix

- [ ] Record the Sony WH-1000XM3 firmware version used for validation.
- [ ] Re-test Px7 S3 and WH-1000XM3 after a clean launch, Bluetooth off/on,
  sleep/wake, disconnect/reconnect, and another source changing settings.
- [ ] Verify one-way Sony volume synchronization at 0%, 50%, and 100%.
- [ ] Confirm unsupported Sony V2 devices fail with the documented message and
  do not receive V1 commands.

## Distribution

- [ ] Enable GitHub private vulnerability reporting.
- [ ] Configure the Sparkle private-key release secret.
- [ ] Confirm the GitHub Actions build is ad-hoc only and contains no Apple
  signing authority or Team Identifier.
- [ ] Install the published archive on a clean Mac and verify Bluetooth permission,
  Launch at Login, menu-bar presence, Control Center (macOS 26), and Sparkle.
- [ ] Verify the ZIP checksum and installer flow from the public release.
- [ ] Verify an update from the previous public version before the second
  release.

## Announcement

- [ ] State clearly that this is an early beta with two hardware-validated
  models; matching related models are experimental.
- [ ] Link compatibility, privacy, contributing, and release notes.
- [ ] Ask testers to use the device-support issue template.
