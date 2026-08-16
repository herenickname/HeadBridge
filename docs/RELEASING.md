# Releasing HeadBridge

HeadBridge publishes universal builds signed with a project-owned self-signed
identity through GitHub Releases. The release workflow never reads the
maintainer's Apple Keychain, imports an Apple certificate, selects a development
team, or submits the app for Apple notarization.

The repository is expected to live at `herenickname/HeadBridge`. The app reads
its stable update feed from:

```text
https://github.com/herenickname/HeadBridge/releases/latest/download/appcast.xml
```

Forks automatically use their own repository URL inside the tagged GitHub
Actions release build.

## What is signed

There are two unrelated trust mechanisms:

- The main app and Control Center extension use the stable **HeadBridge
  Self-Signed Release** identity. It has no Apple Team Identifier and does not
  bypass Gatekeeper, but its stable designated requirement lets macOS preserve
  Bluetooth consent across HeadBridge updates. Prebuilt Sparkle helpers remain
  ad-hoc signed and are sealed by the outer app signature.
- Sparkle uses an EdDSA key to authenticate downloaded update archives and the
  appcast. This cryptographic update signature is independent of Apple code
  signing and does not involve an Apple developer account.

The build scripts fail if a release does not embed the exact public certificate
in [`Signing/HeadBridge-Release.pem`](../Signing/HeadBridge-Release.pem), if the
designated requirement changes, or if a produced bundle contains an Apple Team
Identifier.

## One-time self-signed identity setup

The public release certificate is committed. Its fingerprints are:

```text
SHA-1   E085832D21031D6CDAFEE799AB413904A9038E21
SHA-256 3283f0344e74d62492e9f4f4aac8b0e0f59bb540519e5ab2602b2e627f8b4ff8
```

The matching PKCS#12 archive and its password are stored only as the repository
secrets `HEADBRIDGE_CODESIGN_P12_BASE64` and
`HEADBRIDGE_CODESIGN_PASSWORD`. The workflow materializes the archive in the
runner's temporary directory and passes it directly to the pinned open-source
`rcodesign` action; it never imports the identity into a macOS Keychain. The
package phase explicitly verifies the embedded certificate fingerprint and
designated requirement before publication, then the temporary PKCS#12 file is
deleted. Keep an offline backup of the private identity. Rotating this
certificate changes HeadBridge's designated requirement and makes macOS ask
for Bluetooth permission again.

## One-time Sparkle setup

The checked-in public EdDSA key is:

```text
QVFEhERTOJ7TbZAYuXlhAax6exDkuJJD1tvXgEKVhF4=
```

Its private seed is stored in the local macOS Keychain under the Sparkle
account `io.github.herenickname.HeadBridge`. After creating the GitHub
repository, export it to a temporary file and create the only release secret:

```shell
SPARKLE_KEYS=".build/artifacts/sparkle/Sparkle/bin/generate_keys"
SPARKLE_SECRET_FILE="$(mktemp)"
"$SPARKLE_KEYS" --account io.github.herenickname.HeadBridge -x "$SPARKLE_SECRET_FILE"
gh secret set SPARKLE_PRIVATE_KEY --repo herenickname/HeadBridge < "$SPARKLE_SECRET_FILE"
/bin/rm -f -- "$SPARKLE_SECRET_FILE"
```

The exported value is equivalent to a password: keep an offline backup. Losing
it prevents installed versions from trusting future updates. Do not commit the
private seed.

## Local release build

`Scripts/build-release.sh` creates a universal `arm64` + `x86_64` application,
requires the exact HeadBridge self-signed identity, verifies all nested code,
the feed URL, and Sparkle public key, then creates a ZIP and SHA-256 checksum:

```shell
./Scripts/build-release.sh 0.1.0 1
```

Outputs:

- `dist/release/HeadBridge.app`
- `dist/release/HeadBridge.zip`
- `dist/release/HeadBridge.zip.sha256`

Nothing is uploaded by this command.

## Publishing a release

1. Merge and verify CI on `main`.
2. Update `CHANGELOG.md` and confirm the version.
3. Create and push an annotated tag, for example `v0.1.0`.
4. The `Release` workflow runs publication checks and tests, creates the
   universal self-signed build, signs and verifies the Sparkle archive/appcast, and
   publishes `HeadBridge.zip`, `HeadBridge.zip.sha256`, `appcast.xml`, and the
   matching `install.sh` in a GitHub Release.
5. Stable tags become the latest release. A tag containing a suffix, such as
   `v0.2.0-beta.1`, becomes a prerelease and does not replace the stable feed.
6. Install the published archive on a second Mac or a clean user account and
   verify the checklist in [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

The workflow uses the monotonically increasing GitHub run number for
`CFBundleVersion` and the tag without its leading `v` for
`CFBundleShortVersionString`.

## Failure behavior

- A missing or non-matching `SPARKLE_PRIVATE_KEY` stops the workflow.
- A missing or non-matching HeadBridge PKCS#12 identity stops the workflow.
- A changed release certificate, designated requirement, or unexpected Apple
  Team Identifier stops the build.
- A missing architecture, invalid nested code signature, wrong bundle ID,
  malformed appcast, mismatched update signature, or checksum failure prevents
  publication.
- Release assets are uploaded only after all checks pass.

References: [Sparkle setup](https://sparkle-project.org/documentation/) and
[publishing updates](https://sparkle-project.org/documentation/publishing/).
