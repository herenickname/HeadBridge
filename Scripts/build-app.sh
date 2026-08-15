#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/HeadBridge.app"
DERIVED_DATA_DIR="$PROJECT_DIR/.build/XcodeDerived"
BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release/HeadBridge.app"
CONTROL_EXTENSION_RELATIVE_PATH="Contents/PlugIns/HeadBridgeControls.appex"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# HeadBridge intentionally ships without an Apple Developer ID identity or
# notarization. Xcode still applies an ad-hoc signature to the complete product
# graph because macOS requires internally consistent signatures for the
# embedded Sparkle helpers and Control Center extension.

cd "$PROJECT_DIR"
xcodebuild \
    -quiet \
    -project "$PROJECT_DIR/HeadBridge.xcodeproj" \
    -scheme HeadBridge \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    ARCHS="${HEADBRIDGE_ARCHS:-$(/usr/bin/uname -m)}" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
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
verify_ad_hoc_signature "$APP_DIR"
verify_ad_hoc_signature "$APP_DIR/$CONTROL_EXTENSION_RELATIVE_PATH"
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
