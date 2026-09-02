#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_INFO_PLIST="${1:-otp-bar.app/Contents/Info.plist}"
if [[ ! -f VERSION || ! -f "$APP_INFO_PLIST" ]]; then
    echo "usage: $0 [path/to/Info.plist] (VERSION and plist must exist)" >&2
    exit 2
fi

VERSION="$(<VERSION)"
if [[ "$(awk 'END {print NR}' VERSION)" -ne 1 ||
      ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "VERSION must be exactly X.Y.Z on one line" >&2
    exit 1
fi
SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_INFO_PLIST")"
BUNDLE_VERSION="$(plutil -extract CFBundleVersion raw -o - "$APP_INFO_PLIST")"
if [[ "$VERSION" != "$SHORT_VERSION" ]]; then
    echo "version mismatch: VERSION=$VERSION short=$SHORT_VERSION bundle=$BUNDLE_VERSION" >&2
    exit 1
fi
if [[ "$VERSION" != "$BUNDLE_VERSION" ]]; then
    echo "version mismatch: VERSION=$VERSION short=$SHORT_VERSION bundle=$BUNDLE_VERSION" >&2
    exit 1
fi
printf 'version OK: %s\n' "$VERSION"
