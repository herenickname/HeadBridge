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
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" \
    ENABLE_HARDENED_RUNTIME=NO \
    clean build

mkdir -p "$RELEASE_DIR"
/bin/rm -rf -- "$APP_DIR"
/usr/bin/ditto "$BUILT_APP" "$APP_DIR"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

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
    require_ad_hoc_signature "$executable"
done
require_ad_hoc_signature "$APP_DIR"
require_ad_hoc_signature "$CONTROL_EXTENSION"

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

VERIFY_DIRECTORY="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/headbridge-release-verify.XXXXXX")"
trap '/bin/rm -rf -- "$VERIFY_DIRECTORY"' EXIT
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$VERIFY_DIRECTORY"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$VERIFY_DIRECTORY/HeadBridge.app"
require_universal_binary "$VERIFY_DIRECTORY/HeadBridge.app/Contents/MacOS/HeadBridge"

echo "$ARCHIVE_PATH"
