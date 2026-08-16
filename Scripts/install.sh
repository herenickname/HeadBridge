#!/bin/bash
set -euo pipefail

REPOSITORY="${HEADBRIDGE_REPOSITORY:-herenickname/HeadBridge}"
INSTALL_DIRECTORY="${HEADBRIDGE_INSTALL_DIRECTORY:-/Applications}"
APP_NAME="HeadBridge.app"
EXPECTED_BUNDLE_ID="io.github.herenickname.HeadBridge"
EXPECTED_SIGNING_AUTHORITY="HeadBridge Self-Signed Release"
EXPECTED_CERTIFICATE_SHA256="3283f0344e74d62492e9f4f4aac8b0e0f59bb540519e5ab2602b2e627f8b4ff8"
RELEASE_BASE_URL="https://github.com/${REPOSITORY}/releases/latest/download"

fail() {
    printf 'HeadBridge install failed: %s\n' "$1" >&2
    exit 1
}

case "$INSTALL_DIRECTORY" in
    /*) ;;
    *) fail "HEADBRIDGE_INSTALL_DIRECTORY must be an absolute path" ;;
esac

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v ditto >/dev/null 2>&1 || fail "ditto is required"
command -v shasum >/dev/null 2>&1 || fail "shasum is required"
command -v codesign >/dev/null 2>&1 || fail "codesign is required"

WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/headbridge-install.XXXXXX")"
ARCHIVE_PATH="$WORK_DIRECTORY/HeadBridge.zip"
CHECKSUM_PATH="$WORK_DIRECTORY/HeadBridge.zip.sha256"
EXTRACT_DIRECTORY="$WORK_DIRECTORY/extracted"
EXTRACTED_APP="$EXTRACT_DIRECTORY/$APP_NAME"
TARGET_APP="$INSTALL_DIRECTORY/$APP_NAME"
STAGED_APP="$INSTALL_DIRECTORY/.HeadBridge.app.install.$$"
BACKUP_APP="$INSTALL_DIRECTORY/.HeadBridge.app.backup.$$"
INSTALLATION_IN_PROGRESS=0

cleanup() {
    if [[ "${INSTALLATION_IN_PROGRESS:-0}" == "1" \
          && -d "$BACKUP_APP" \
          && ! -e "$TARGET_APP" ]] \
        && declare -F run_install_command >/dev/null 2>&1; then
        run_install_command mv "$BACKUP_APP" "$TARGET_APP" 2>/dev/null || true
    fi
    rm -rf -- "$WORK_DIRECTORY"
}
trap cleanup EXIT

printf 'Downloading the latest HeadBridge release...\n'
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --retry 3 --output "$ARCHIVE_PATH" "$RELEASE_BASE_URL/HeadBridge.zip"
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --retry 3 --output "$CHECKSUM_PATH" "$RELEASE_BASE_URL/HeadBridge.zip.sha256"

if ! LC_ALL=C grep -Eq '^[[:xdigit:]]{64}  HeadBridge[.]zip$' "$CHECKSUM_PATH"; then
    fail "the published checksum has an unexpected format"
fi

(
    cd "$WORK_DIRECTORY"
    shasum -a 256 -c HeadBridge.zip.sha256
)

mkdir -p "$EXTRACT_DIRECTORY"
ditto -x -k "$ARCHIVE_PATH" "$EXTRACT_DIRECTORY"
[[ -d "$EXTRACTED_APP" ]] || fail "the archive does not contain HeadBridge.app"
[[ -x "$EXTRACTED_APP/Contents/MacOS/HeadBridge" ]] \
    || fail "the archive does not contain the HeadBridge executable"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$EXTRACTED_APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] \
    || fail "unexpected bundle identifier: ${BUNDLE_ID:-missing}"

codesign -d --arch arm64 "$EXTRACTED_APP" >/dev/null 2>&1 \
    || fail "the release does not contain an arm64 executable"
codesign -d --arch x86_64 "$EXTRACTED_APP" >/dev/null 2>&1 \
    || fail "the release does not contain an x86_64 executable"
codesign --verify --deep --strict "$EXTRACTED_APP" \
    || fail "the downloaded app has an invalid code signature"

SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$EXTRACTED_APP" 2>&1)"
printf '%s\n' "$SIGNATURE_DETAILS" \
    | grep -Fx "Authority=$EXPECTED_SIGNING_AUTHORITY" >/dev/null \
    || fail "the downloaded app does not use the HeadBridge release identity"
printf '%s\n' "$SIGNATURE_DETAILS" \
    | grep -Fx 'TeamIdentifier=not set' >/dev/null \
    || fail "the downloaded app unexpectedly contains an Apple Team Identifier"

CERTIFICATE_PREFIX="$WORK_DIRECTORY/release-certificate-"
codesign -d --extract-certificates="$CERTIFICATE_PREFIX" "$EXTRACTED_APP" 2>/dev/null \
    || fail "the downloaded app does not contain its release certificate"
ACTUAL_CERTIFICATE_SHA256="$(
    shasum -a 256 "${CERTIFICATE_PREFIX}0" \
        | awk '{print $1}'
)"
[[ "$ACTUAL_CERTIFICATE_SHA256" == "$EXPECTED_CERTIFICATE_SHA256" ]] \
    || fail "the downloaded app uses an unexpected release certificate"

if [[ -w "$INSTALL_DIRECTORY" ]]; then
    USE_SUDO=0
else
    command -v sudo >/dev/null 2>&1 || fail "sudo is required to write to $INSTALL_DIRECTORY"
    USE_SUDO=1
fi

run_install_command() {
    if [[ "$USE_SUDO" == "1" ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

run_install_command mkdir -p "$INSTALL_DIRECTORY"
run_install_command rm -rf -- "$STAGED_APP" "$BACKUP_APP"
run_install_command ditto "$EXTRACTED_APP" "$STAGED_APP"
run_install_command xattr -dr com.apple.quarantine "$STAGED_APP" 2>/dev/null || true

if [[ -d "$TARGET_APP" ]]; then
    /usr/bin/osascript -e 'tell application id "io.github.herenickname.HeadBridge" to quit' \
        >/dev/null 2>&1 || true
    INSTALLATION_IN_PROGRESS=1
    run_install_command mv "$TARGET_APP" "$BACKUP_APP"
fi

if ! run_install_command mv "$STAGED_APP" "$TARGET_APP"; then
    if [[ -d "$BACKUP_APP" ]]; then
        run_install_command mv "$BACKUP_APP" "$TARGET_APP" || true
    fi
    fail "could not move HeadBridge into $INSTALL_DIRECTORY"
fi
INSTALLATION_IN_PROGRESS=0

run_install_command rm -rf -- "$BACKUP_APP"
run_install_command xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

printf 'Installed HeadBridge to %s\n' "$TARGET_APP"
open "$TARGET_APP"
