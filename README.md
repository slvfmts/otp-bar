# otp-bar

`otp-bar` is a tiny, native, offline TOTP utility for the macOS menu bar. I
made it for myself and am sharing the source in case it is useful to someone
else.

It reads TOTP QR images, keeps the imported seeds in macOS Keychain, computes
codes locally, and copies a code with one click. It makes no network requests.
The current UI is in Russian; the English installation guide includes the
labels you will see in the app.

## What it does

- Runs as a small native SwiftUI menu-bar app.
- Imports standard `otpauth://totp` QR images.
- Imports Google Authenticator migration QR images, including multiple accounts.
- Supports six- and eight-digit TOTP codes with SHA-1, SHA-256, and SHA-512.
- Stores seeds in macOS Keychain and computes codes offline.
- Copies only the generated code; it attempts to clear it at the next TOTP
  window boundary, but only if the clipboard has not changed meanwhile.

There are no third-party dependencies, networking, telemetry, analytics, cloud
sync, or update checker.

## What it is not

This is a convenience utility, not a replacement for a security key or a
full-featured authenticator. It currently does not support HOTP, Steam tokens,
camera scanning, account search or editing, encrypted export, cloud backup,
sync, Touch ID locking, mobile clients, or automatic updates. It is not an App
Store, Developer ID, or notarized distribution.

## Security and convenience

An imported TOTP seed is sensitive provisioning data: anyone who gets it can
generate the same codes. Keychain protects the stored data at rest, but the app
can read it while your macOS session is unlocked. Keeping your password flow
and TOTP generator on the same Mac is convenient, but reduces device and factor
separation. TOTP is also not phishing-resistant; use passkeys or hardware
security keys when a service supports them.

Treat every QR image as a secret-bearing file. Keep it local during import,
then delete it and empty Trash. Do not put it in email, messaging apps, cloud
drives, or synced screenshot folders. This reduces exposure but does not
guarantee secure erasure on SSD/APFS.

## Build from source

Requirements: macOS 14 or newer and Xcode Command Line Tools or Xcode with a
working Swift toolchain.

```sh
git clone https://github.com/slvfmts/otp-bar.git
cd otp-bar
swift test
./build-app.sh
./scripts/check-version.sh
open otp-bar.app
```

The project is source-only. Releases do not include a prebuilt application or
binary archive; GitHub Releases contain only GitHub-generated source archives.
Build from the reviewed source yourself and do not download or run binaries
from unofficial sources. See [INSTALL.md](INSTALL.md) for the complete setup
and troubleshooting guide.

## Contributing

Keep changes small, native, dependency-free, and offline. Run `swift test`,
`./build-app.sh`, and `./scripts/check-version.sh` before opening a change. Do
not include seeds, QR images, account exports, generated binaries, personal
notes, or machine-specific data.

See the [MIT License](LICENSE), [security reporting policy](SECURITY.md), and
[changelog](CHANGELOG.md).
