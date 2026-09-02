#!/bin/bash
# Собирает otp-bar.app (LSUIElement-приложение в меню-баре) без Xcode.
set -euo pipefail
cd "$(dirname "$0")"

# VERSION is the single source of release metadata. Apple bundle versions use
# exactly three dot-separated non-negative integers (X.Y.Z).
VERSION_FILE="VERSION"
if [[ ! -f "$VERSION_FILE" ]]; then
    echo "error: missing $VERSION_FILE" >&2
    exit 1
fi
if [[ "$(awk 'END {print NR}' "$VERSION_FILE")" -ne 1 ]]; then
    echo "error: VERSION must contain exactly one line" >&2
    exit 1
fi
VERSION="$(<"$VERSION_FILE")"
if [[ "$VERSION" == *$'\n'* || "$VERSION" == *$'\r'* ||
      ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "error: VERSION must contain one X.Y.Z version (found: $VERSION)" >&2
    exit 1
fi

# SwiftPM в этом CLT-окружении нестабилен — компилируем напрямую через swiftc.
# Universal binary: собираем обе архитектуры и склеиваем lipo, чтобы .app
# запускался и на Apple Silicon, и на Intel-маках.
echo "→ swiftc arm64 (release)…"
swiftc -O Sources/otp-bar/*.swift -o otp-bar-arm64  -target arm64-apple-macosx14.0
echo "→ swiftc x86_64 (release)…"
swiftc -O Sources/otp-bar/*.swift -o otp-bar-x86_64 -target x86_64-apple-macosx14.0
echo "→ lipo (universal)…"
lipo -create -output otp-bar-bin otp-bar-arm64 otp-bar-x86_64
rm -f otp-bar-arm64 otp-bar-x86_64
lipo -info otp-bar-bin

BIN="otp-bar-bin"
APP="otp-bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/otp-bar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>otp-bar</string>
    <key>CFBundleDisplayName</key><string>OTP Bar</string>
    <key>CFBundleIdentifier</key><string>one.editors.otp-bar</string>
    <key>CFBundleExecutable</key><string>otp-bar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Check the generated metadata before signing, and keep a standalone checker
# available to CI/release jobs as well.
BUILT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
    echo "error: Info.plist version $BUILT_VERSION does not match VERSION $VERSION" >&2
    exit 1
fi

# Ad-hoc подпись (строго после lipo) — без неё GUI-приложение может не запуститься
# на свежих macOS. Ошибку НЕ глотаем: set -e оборвёт сборку, если подпись не легла.
codesign --force --deep --sign - "$APP"

echo "✓ Готово: $APP"
echo "  Запуск GUI:   open $APP"
echo "  CLI-команды:  $APP/Contents/MacOS/otp-bar {importqr|list}"
