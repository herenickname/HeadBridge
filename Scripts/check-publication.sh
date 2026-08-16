#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

fail() {
    print -u2 -- "publication check failed: $1"
    exit 1
}

for ignored in .DS_Store .build/.publication-probe dist/.publication-probe; do
    /usr/bin/git check-ignore -q "$ignored" || fail "$ignored is not ignored"
done

if /usr/bin/grep -RIlE --exclude=check-publication.sh --exclude-dir=.git --exclude-dir=.build --exclude-dir=dist \
    -- '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----' . >/dev/null; then
    fail "a private-key PEM header is present"
fi

if /usr/bin/grep -RIlE --exclude=check-publication.sh --exclude-dir=.git --exclude-dir=.build --exclude-dir=dist \
    -- '(github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})' . >/dev/null; then
    fail "a token-shaped secret is present"
fi

if /usr/bin/grep -RInE --exclude=check-publication.sh --exclude-dir=.git --exclude-dir=.build --exclude-dir=dist \
    -- '/Users/[^/<[:space:]]+' .; then
    fail "an absolute user path is present"
fi

if /usr/bin/find . -path './.git' -prune -o -path './.build' -prune -o -path './dist' -prune \
    \( -name '.env' -o -name '.env.*' -o -name 'Local.xcconfig' \) -print -quit \
    | /usr/bin/grep -q .; then
    fail "a local environment or signing configuration file is present"
fi

[[ -f LICENSE ]] || fail "project LICENSE is missing"
[[ -f Resources/Licenses/Sparkle-LICENSE.txt ]] || fail "Sparkle license is missing"
[[ -f Signing/HeadBridge-Release.pem ]] || fail "public release certificate is missing"
[[ -f PRIVACY.md ]] || fail "PRIVACY.md is missing"
[[ -f SECURITY.md ]] || fail "SECURITY.md is missing"
[[ -x Scripts/install.sh ]] || fail "Scripts/install.sh must be executable"

/bin/bash -n Scripts/install.sh
/bin/zsh -n Scripts/build-app.sh Scripts/build-release.sh Scripts/check-publication.sh

if /usr/bin/grep -Eq '(^|[^[:alnum:]_])lipo([^[:alnum:]_]|$)' Scripts/install.sh; then
    fail "the public installer must not require Xcode Command Line Tools"
fi
/usr/bin/grep -Fq 'releases/latest/download/install.sh' README.md \
    || fail "README does not use the versioned release installer"
/usr/bin/grep -Fq 'Scripts/install.sh#Installer' .github/workflows/release.yml \
    || fail "the release workflow does not publish the installer"

/usr/bin/plutil -lint Resources/Info.plist Resources/HeadBridgeControls-Info.plist \
    Resources/HeadBridgeControls.entitlements >/dev/null

CERTIFICATE_SHA1="$(
    /usr/bin/openssl x509 -in Signing/HeadBridge-Release.pem -noout -fingerprint -sha1 \
        | /usr/bin/cut -d= -f2 \
        | /usr/bin/tr -d ':'
)"
[[ "$CERTIFICATE_SHA1" == "E085832D21031D6CDAFEE799AB413904A9038E21" ]] \
    || fail "public release certificate fingerprint changed"
/usr/bin/openssl x509 -in Signing/HeadBridge-Release.pem -noout -checkend 0 >/dev/null \
    || fail "public release certificate is invalid or expired"
/usr/bin/xcrun swift-format lint \
    --configuration .swift-format \
    --recursive Sources Tests Package.swift

print -- "Publication checks passed."
