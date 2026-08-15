#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

fail() {
    print -u2 -- "publication check failed: $1"
    exit 1
}

for ignored in .DS_Store .build dist; do
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
[[ -f PRIVACY.md ]] || fail "PRIVACY.md is missing"
[[ -f SECURITY.md ]] || fail "SECURITY.md is missing"
[[ -x Scripts/install.sh ]] || fail "Scripts/install.sh must be executable"

/bin/bash -n Scripts/install.sh
/bin/zsh -n Scripts/build-app.sh Scripts/build-release.sh Scripts/check-publication.sh

/usr/bin/plutil -lint Resources/Info.plist Resources/HeadBridgeControls-Info.plist \
    Resources/HeadBridgeControls.entitlements >/dev/null
/usr/bin/xcrun swift-format lint \
    --configuration .swift-format \
    --recursive Sources Tests Package.swift

print -- "Publication checks passed."
