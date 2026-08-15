## What changed

Describe the user-visible behavior and the provider/protocol boundary affected.

## Hardware verification

- Device model:
- Firmware:
- macOS:
- Codec (if relevant):
- Tested controls:

## Implementation assistance

- Method: manual / Codex / Claude Code / other
- Model (if applicable):
- What the author personally reviewed:

## Checklist

- [ ] `swift test` passes.
- [ ] `HEADBRIDGE_SKIP_REGISTRATION=1 ./Scripts/build-app.sh` passes.
- [ ] `./Scripts/check-publication.sh` passes.
- [ ] New protocol behavior has exact-frame and malformed-input tests.
- [ ] Disconnect/reconnect and restore-on-connect behavior were checked where relevant.
- [ ] For device/protocol changes, I tested the result on the exact hardware listed above or clearly marked it unverified.
- [ ] I reviewed all submitted code, including AI-assisted changes.
- [ ] No vendor/decompiled/incompatible source or binary asset was copied.
- [ ] Documentation and compatibility status are updated.
