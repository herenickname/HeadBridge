#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/HeadBridge.app"
DERIVED_DATA_DIR="$PROJECT_DIR/.build/XcodeDerived"
BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release/HeadBridge.app"
CONTROL_EXTENSION_RELATIVE_PATH="Contents/PlugIns/HeadBridgeControls.appex"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SIGNING_CERTIFICATE="$PROJECT_DIR/Signing/HeadBridge-Release.pem"
EXPECTED_SIGNING_AUTHORITY="HeadBridge Self-Signed Release"
EXPECTED_CERTIFICATE_SHA1="E085832D21031D6CDAFEE799AB413904A9038E21"

# HeadBridge intentionally ships without an Apple Developer ID identity or
# notarization. Maintainer builds use the project-owned self-signed identity so
# macOS can retain Bluetooth consent across rebuilds. Contributors without that
# private identity get an ad-hoc local build; this script never selects an Apple
# Development or distribution identity.

CERTIFICATE_SHA1="$(
    /usr/bin/openssl x509 -in "$SIGNING_CERTIFICATE" -noout -fingerprint -sha1 \
        | /usr/bin/cut -d= -f2 \
        | /usr/bin/tr -d ':'
)"
if [[ "$CERTIFICATE_SHA1" != "$EXPECTED_CERTIFICATE_SHA1" ]]; then
    print -u2 -- "The checked-in HeadBridge release certificate has an unexpected fingerprint."
    exit 78
fi

if /usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/grep -F "$EXPECTED_CERTIFICATE_SHA1" >/dev/null; then
    SIGNING_IDENTITY="$EXPECTED_CERTIFICATE_SHA1"
    AD_HOC_CODE_SIGNING_ALLOWED=NO
    USE_HEADBRIDGE_IDENTITY=1
else
    SIGNING_IDENTITY="-"
    AD_HOC_CODE_SIGNING_ALLOWED=YES
    USE_HEADBRIDGE_IDENTITY=0
    print -u2 -- "HeadBridge release identity not found; creating an ad-hoc contributor build."
fi

cd "$PROJECT_DIR"
xcodebuild \
    -quiet \
    -project "$PROJECT_DIR/HeadBridge.xcodeproj" \
    -scheme HeadBridge \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    ARCHS="${HEADBRIDGE_ARCHS:-$(/usr/bin/uname -m)}" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    AD_HOC_CODE_SIGNING_ALLOWED="$AD_HOC_CODE_SIGNING_ALLOWED" \
    DEVELOPMENT_TEAM="" \
    ENABLE_HARDENED_RUNTIME=NO \
    clean build

mkdir -p "$PROJECT_DIR/dist"
/bin/rm -rf -- "$APP_DIR"
/usr/bin/ditto "$BUILT_APP" "$APP_DIR"

/usr/bin/codesign --verify --deep --strict "$APP_DIR"
verify_ad_hoc_signature() {
    local code_path="$1"
    local signature_details

    signature_details="$(/usr/bin/codesign -dv --verbose=4 "$code_path" 2>&1)"
    if ! /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -Fx 'Signature=adhoc' >/dev/null; then
        print -u2 -- "Code is not ad-hoc signed: $code_path"
        exit 78
    fi
    if /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -E '^Authority=' >/dev/null; then
        print -u2 -- "Code unexpectedly contains an Apple signing authority: $code_path"
        exit 78
    fi
    if ! /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -Fx 'TeamIdentifier=not set' >/dev/null; then
        print -u2 -- "Code unexpectedly contains a TeamIdentifier: $code_path"
        exit 78
    fi
}
verify_headbridge_signature() {
    local code_path="$1"
    local signature_details

    signature_details="$(/usr/bin/codesign -dv --verbose=4 "$code_path" 2>&1)"
    if /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -Fx 'Signature=adhoc' >/dev/null; then
        print -u2 -- "Code is unexpectedly ad-hoc signed: $code_path"
        exit 78
    fi
    if ! /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -Fx "Authority=$EXPECTED_SIGNING_AUTHORITY" >/dev/null; then
        print -u2 -- "Code does not use the HeadBridge self-signed identity: $code_path"
        exit 78
    fi
    if ! /usr/bin/printf '%s\n' "$signature_details" \
        | /usr/bin/grep -Fx 'TeamIdentifier=not set' >/dev/null; then
        print -u2 -- "Code unexpectedly contains a TeamIdentifier: $code_path"
        exit 78
    fi
}
if [[ "$USE_HEADBRIDGE_IDENTITY" == "1" ]]; then
    verify_headbridge_signature "$APP_DIR"
    verify_headbridge_signature "$APP_DIR/$CONTROL_EXTENSION_RELATIVE_PATH"
else
    verify_ad_hoc_signature "$APP_DIR"
    verify_ad_hoc_signature "$APP_DIR/$CONTROL_EXTENSION_RELATIVE_PATH"
fi
[[ -f "$APP_DIR/Contents/Resources/LICENSE" ]]
[[ -f "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]
[[ -f "$APP_DIR/Contents/Resources/Sparkle-LICENSE.txt" ]]
if [[ "${HEADBRIDGE_SKIP_REGISTRATION:-0}" != "1" ]]; then
    "$LSREGISTER" -u "$BUILT_APP" 2>/dev/null || true
    "$LSREGISTER" -f "$APP_DIR"
    /usr/bin/pluginkit -r "$BUILT_APP/$CONTROL_EXTENSION_RELATIVE_PATH" 2>/dev/null || true
    /usr/bin/pluginkit -a "$APP_DIR/$CONTROL_EXTENSION_RELATIVE_PATH"
fi

echo "$APP_DIR"
