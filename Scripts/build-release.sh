#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
VERSION="${HEADBRIDGE_VERSION:-${1:-}}"
BUILD_NUMBER="${HEADBRIDGE_BUILD_NUMBER:-${2:-}}"
FEED_URL="${HEADBRIDGE_UPDATE_FEED_URL:-https://github.com/herenickname/HeadBridge/releases/latest/download/appcast.xml}"
DERIVED_DATA_DIR="$PROJECT_DIR/.build/ReleaseDerived"
BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release/HeadBridge.app"
RELEASE_DIR="$PROJECT_DIR/dist/release"
APP_DIR="$RELEASE_DIR/HeadBridge.app"
ARCHIVE_PATH="$RELEASE_DIR/HeadBridge.zip"
CHECKSUM_PATH="$RELEASE_DIR/HeadBridge.zip.sha256"
SIGNING_CERTIFICATE="$PROJECT_DIR/Signing/HeadBridge-Release.pem"
EXPECTED_SIGNING_AUTHORITY="HeadBridge Self-Signed Release"
EXPECTED_CERTIFICATE_SHA1="E085832D21031D6CDAFEE799AB413904A9038E21"
EXPECTED_CERTIFICATE_SHA256="3283f0344e74d62492e9f4f4aac8b0e0f59bb540519e5ab2602b2e627f8b4ff8"
SIGNING_IDENTITY="${HEADBRIDGE_CODESIGN_IDENTITY:-$EXPECTED_CERTIFICATE_SHA1}"
RELEASE_PHASE="${HEADBRIDGE_RELEASE_PHASE:-all}"

case "$RELEASE_PHASE" in
    all | build | package) ;;
    *)
        echo "HEADBRIDGE_RELEASE_PHASE must be all, build, or package." >&2
        exit 64
        ;;
esac

if [[ -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
    echo "Usage: $0 <version> <build-number>" >&2
    exit 64
fi

if ! /usr/bin/printf '%s\n' "$VERSION" | /usr/bin/grep -Eq '^[0-9]+([.][0-9]+){1,3}([.-][0-9A-Za-z.-]+)?$'; then
    echo "Invalid release version: $VERSION" >&2
    exit 64
fi

if ! /usr/bin/printf '%s\n' "$BUILD_NUMBER" | /usr/bin/grep -Eq '^[1-9][0-9]*$'; then
    echo "Build number must be a positive integer: $BUILD_NUMBER" >&2
    exit 64
fi

if [[ "$FEED_URL" != https://* ]]; then
    echo "HEADBRIDGE_UPDATE_FEED_URL must be an HTTPS URL." >&2
    exit 64
fi

[[ -f "$SIGNING_CERTIFICATE" ]] || {
    echo "The public HeadBridge release certificate is missing." >&2
    exit 66
}

CERTIFICATE_SHA1="$(
    /usr/bin/openssl x509 -in "$SIGNING_CERTIFICATE" -noout -fingerprint -sha1 \
        | /usr/bin/cut -d= -f2 \
        | /usr/bin/tr -d ':'
)"
CERTIFICATE_SHA256="$(
    /usr/bin/openssl x509 -in "$SIGNING_CERTIFICATE" -outform DER \
        | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)"
if [[ "$CERTIFICATE_SHA1" != "$EXPECTED_CERTIFICATE_SHA1" \
      || "$CERTIFICATE_SHA256" != "$EXPECTED_CERTIFICATE_SHA256" ]]; then
    echo "The checked-in HeadBridge release certificate has an unexpected fingerprint." >&2
    exit 78
fi
if [[ "$RELEASE_PHASE" == "all" ]]; then
    if [[ "${SIGNING_IDENTITY:u}" != "$EXPECTED_CERTIFICATE_SHA1" ]]; then
        echo "HEADBRIDGE_CODESIGN_IDENTITY must be the project-owned self-signed identity." >&2
        exit 78
    fi
    if ! /usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/grep -F "$EXPECTED_CERTIFICATE_SHA1" >/dev/null; then
        echo "The HeadBridge self-signed release identity is not available in the Keychain." >&2
        exit 78
    fi
fi

TEMP_DIRECTORY="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/headbridge-release.XXXXXX")"
trap '/bin/rm -rf -- "$TEMP_DIRECTORY"' EXIT

if [[ "$RELEASE_PHASE" != "package" ]]; then
    if [[ "$RELEASE_PHASE" == "build" ]]; then
        BUILD_SIGNING_IDENTITY="-"
        BUILD_AD_HOC_ALLOWED=YES
    else
        BUILD_SIGNING_IDENTITY="$EXPECTED_CERTIFICATE_SHA1"
        BUILD_AD_HOC_ALLOWED=NO
    fi

    cd "$PROJECT_DIR"
    xcodebuild \
        -quiet \
        -project "$PROJECT_DIR/HeadBridge.xcodeproj" \
        -scheme HeadBridge \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -derivedDataPath "$DERIVED_DATA_DIR" \
        ARCHS="arm64 x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        HEADBRIDGE_UPDATE_FEED_URL="$FEED_URL" \
        CODE_SIGN_IDENTITY="$BUILD_SIGNING_IDENTITY" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        AD_HOC_CODE_SIGNING_ALLOWED="$BUILD_AD_HOC_ALLOWED" \
        DEVELOPMENT_TEAM="" \
        ENABLE_HARDENED_RUNTIME=NO \
        clean build

    mkdir -p "$RELEASE_DIR"
    /bin/rm -rf -- "$APP_DIR"
    /usr/bin/ditto "$BUILT_APP" "$APP_DIR"
elif [[ ! -d "$APP_DIR" ]]; then
    echo "The release app must be built before the package phase." >&2
    exit 66
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if [[ "$RELEASE_PHASE" == "build" ]]; then
    echo "$APP_DIR"
    exit 0
fi

require_ad_hoc_signature() {
    local code_path="$1"
    local signature_details

    signature_details="$(/usr/bin/codesign -dv --verbose=4 "$code_path" 2>&1)"
    if ! /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -Fx 'Signature=adhoc' >/dev/null; then
        echo "Release code is not ad-hoc signed: $code_path" >&2
        exit 78
    fi
    if /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -E '^Authority=' >/dev/null; then
        echo "Release unexpectedly contains an Apple signing authority: $code_path" >&2
        exit 78
    fi
    if ! /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -Fx 'TeamIdentifier=not set' >/dev/null; then
        echo "Release unexpectedly contains a TeamIdentifier: $code_path" >&2
        exit 78
    fi
}

require_headbridge_signature() {
    local code_path="$1"
    local signature_details certificate_prefix extracted_fingerprint

    signature_details="$(/usr/bin/codesign -dv -r- --verbose=4 "$code_path" 2>&1)"
    if /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -Fx 'Signature=adhoc' >/dev/null; then
        echo "HeadBridge release code is still ad-hoc signed: $code_path" >&2
        exit 78
    fi
    if ! /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -Fx "Authority=$EXPECTED_SIGNING_AUTHORITY" >/dev/null; then
        echo "HeadBridge release code has the wrong signing authority: $code_path" >&2
        exit 78
    fi
    if /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -E '^Authority=' \
        | /usr/bin/grep -Fvx "Authority=$EXPECTED_SIGNING_AUTHORITY" >/dev/null; then
        echo "HeadBridge release code contains an unexpected signing authority: $code_path" >&2
        exit 78
    fi
    if ! /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -Fx 'TeamIdentifier=not set' >/dev/null; then
        echo "HeadBridge release code unexpectedly contains a TeamIdentifier: $code_path" >&2
        exit 78
    fi
    if ! /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -F 'designated => identifier' >/dev/null \
        || ! /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -Fi \
            "certificate root = H\"$EXPECTED_CERTIFICATE_SHA1\"" >/dev/null; then
        echo "HeadBridge release code has an unstable designated requirement: $code_path" >&2
        exit 78
    fi

    certificate_prefix="$TEMP_DIRECTORY/signing-certificate-$RANDOM-"
    /usr/bin/codesign -d --extract-certificates="$certificate_prefix" "$code_path" 2>/dev/null
    extracted_fingerprint="$(
        /usr/bin/shasum -a 256 "${certificate_prefix}0" \
            | /usr/bin/awk '{print $1}'
    )"
    if [[ "$extracted_fingerprint" != "$EXPECTED_CERTIFICATE_SHA256" ]]; then
        echo "HeadBridge release code embeds the wrong certificate: $code_path" >&2
        exit 78
    fi
}

require_headbridge_or_ad_hoc_signature() {
    local code_path="$1"
    local signature_details

    signature_details="$(/usr/bin/codesign -dv --verbose=4 "$code_path" 2>&1)"
    if /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -Fx 'Signature=adhoc' >/dev/null; then
        if [[ "${HEADBRIDGE_REQUIRE_FULL_SELF_SIGNING:-0}" == "1" ]]; then
            echo "Release helper is still ad-hoc signed: $code_path" >&2
            exit 78
        fi
        require_ad_hoc_signature "$code_path"
    else
        require_headbridge_signature "$code_path"
    fi
}

require_universal_binary() {
    local binary_path="$1"
    local architectures

    [[ -f "$binary_path" ]] || {
        echo "Required release executable is missing: $binary_path" >&2
        exit 65
    }
    architectures="$(/usr/bin/lipo -archs "$binary_path")"
    if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
        echo "Release executable is not universal ($architectures): $binary_path" >&2
        exit 65
    fi
}

MAIN_EXECUTABLE="$APP_DIR/Contents/MacOS/HeadBridge"
CONTROL_EXTENSION="$APP_DIR/Contents/PlugIns/HeadBridgeControls.appex"
SPARKLE_ROOT="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/Current"
RELEASE_EXECUTABLES=(
    "$MAIN_EXECUTABLE"
    "$CONTROL_EXTENSION/Contents/MacOS/HeadBridgeControls"
    "$SPARKLE_ROOT/Sparkle"
    "$SPARKLE_ROOT/Autoupdate"
    "$SPARKLE_ROOT/Updater.app/Contents/MacOS/Updater"
    "$SPARKLE_ROOT/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
    "$SPARKLE_ROOT/XPCServices/Installer.xpc/Contents/MacOS/Installer"
)
for executable in "${RELEASE_EXECUTABLES[@]}"; do
    require_universal_binary "$executable"
done
require_headbridge_signature "$APP_DIR"
require_headbridge_signature "$CONTROL_EXTENSION"
require_headbridge_signature "$SPARKLE_ROOT"
require_headbridge_signature "$SPARKLE_ROOT/Sparkle"
require_headbridge_or_ad_hoc_signature "$SPARKLE_ROOT/Autoupdate"
require_headbridge_or_ad_hoc_signature "$SPARKLE_ROOT/Updater.app/Contents/MacOS/Updater"
require_headbridge_or_ad_hoc_signature "$SPARKLE_ROOT/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
require_headbridge_or_ad_hoc_signature "$SPARKLE_ROOT/XPCServices/Installer.xpc/Contents/MacOS/Installer"

if /usr/bin/codesign -d --entitlements :- "$APP_DIR" 2>/dev/null \
    | /usr/bin/plutil -extract com.apple.security.get-task-allow raw -o - - 2>/dev/null \
    | /usr/bin/grep -Fx true >/dev/null; then
    echo "Published builds must not contain the get-task-allow entitlement." >&2
    exit 78
fi

/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP_DIR/Contents/Info.plist" \
    | /usr/bin/grep -Fx "$VERSION" >/dev/null
/usr/bin/plutil -extract CFBundleVersion raw "$APP_DIR/Contents/Info.plist" \
    | /usr/bin/grep -Fx "$BUILD_NUMBER" >/dev/null
/usr/bin/plutil -extract CFBundleIdentifier raw "$APP_DIR/Contents/Info.plist" \
    | /usr/bin/grep -Fx "io.github.herenickname.HeadBridge" >/dev/null
/usr/bin/plutil -extract CFBundleIdentifier raw "$CONTROL_EXTENSION/Contents/Info.plist" \
    | /usr/bin/grep -Fx "io.github.herenickname.HeadBridge.controls" >/dev/null
/usr/bin/plutil -extract SUFeedURL raw "$APP_DIR/Contents/Info.plist" \
    | /usr/bin/grep -Fx "$FEED_URL" >/dev/null
/usr/bin/plutil -extract SUPublicEDKey raw "$APP_DIR/Contents/Info.plist" \
    | /usr/bin/grep -Fx "QVFEhERTOJ7TbZAYuXlhAax6exDkuJJD1tvXgEKVhF4=" >/dev/null
/usr/bin/plutil -extract SURequireSignedFeed raw "$APP_DIR/Contents/Info.plist" \
    | /usr/bin/grep -Fx true >/dev/null
/usr/bin/plutil -extract SUVerifyUpdateBeforeExtraction raw "$APP_DIR/Contents/Info.plist" \
    | /usr/bin/grep -Fx true >/dev/null
[[ -d "$APP_DIR/Contents/Frameworks/Sparkle.framework" ]]
[[ -d "$APP_DIR/Contents/PlugIns/HeadBridgeControls.appex" ]]
[[ -f "$APP_DIR/Contents/Resources/LICENSE" ]]
[[ -f "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]
[[ -f "$APP_DIR/Contents/Resources/Sparkle-LICENSE.txt" ]]

/bin/rm -f -- "$ARCHIVE_PATH" "$CHECKSUM_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"
(
    cd "$RELEASE_DIR"
    /usr/bin/shasum -a 256 HeadBridge.zip > HeadBridge.zip.sha256
    /usr/bin/shasum -a 256 -c HeadBridge.zip.sha256
)

VERIFY_DIRECTORY="$TEMP_DIRECTORY/unpacked"
/bin/mkdir -p "$VERIFY_DIRECTORY"
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$VERIFY_DIRECTORY"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$VERIFY_DIRECTORY/HeadBridge.app"
require_universal_binary "$VERIFY_DIRECTORY/HeadBridge.app/Contents/MacOS/HeadBridge"
require_headbridge_signature "$VERIFY_DIRECTORY/HeadBridge.app"

echo "$ARCHIVE_PATH"
