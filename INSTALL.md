# Install and run otp-bar

`otp-bar` is distributed as source only. There is no supported binary
installer. These steps build the app locally on your Mac.

The app's current interface is in Russian. The labels below show the exact
buttons as they appear in the app, followed by their English meaning.

## 1. Check the requirements

You need:

- macOS 14 (Sonoma) or newer;
- Xcode Command Line Tools, or Xcode with a working Swift toolchain;
- an internet connection only to clone the source repository.

The built app itself makes no network requests and has no third-party runtime
dependencies.

## 2. Download the source

Open Terminal and run:

```sh
git clone https://github.com/slvfmts/otp-bar.git
cd otp-bar
```

Review the source before building if you like. Do not copy real QR images,
TOTP seeds, or account exports into the repository.

## 3. Run the tests

From the project directory, run:

```sh
swift test
```

This tests the parser and TOTP logic without importing anything into your
Keychain.

## 4. Build the app

Run:

```sh
./build-app.sh
./scripts/check-version.sh
```

The build creates `otp-bar.app` in the project directory. It contains a
universal executable for Apple Silicon and Intel Macs, and is signed
ad-hoc locally. The generated app is ignored by Git and is not a release
artifact.

## 5. Launch it

Run:

```sh
open otp-bar.app
```

Look for the lock-shield icon in the menu bar and click it. Because this is an
ad-hoc source build, macOS may warn that it cannot verify the developer. If
that happens, try opening the app once, then open **System Settings → Privacy &
Security**, find the message about `otp-bar`, and choose **Open Anyway**. You
can also Control-click the app in Finder and choose **Open**. Approve this
specific app only; do not disable Gatekeeper globally, remove its quarantine
attributes, or use an unofficial binary.

## 6. Import your first account

1. Click the menu-bar lock-shield icon.
2. Choose **Добавить аккаунт…** (Add account…).
3. In the file picker, select one or more local images containing either a
   standard TOTP QR code or a Google Authenticator migration QR code.
4. Click **Импортировать** (Import) in the picker.
5. Review the import summary. The app reports issuer and account labels, never
   the secret itself.
6. Click **Готово** (Done).

The app supports TOTP accounts only. HOTP entries and unsupported or malformed
entries are skipped. For a migration QR, the app can import multiple TOTP
accounts in one operation. If an existing account is imported again with a
different seed or configuration, the app reports it as overwritten.

## 7. Handle the QR image safely

The QR image contains the provisioning secret. Keep it on local storage while
importing. After a successful import, delete the image and empty Trash. Do not
send it through email or messaging, store it in a cloud drive, or leave it in a
synced screenshots folder. These steps reduce exposure but cannot guarantee
secure erasure on SSD/APFS.

Clicking an account copies the current code. The app tries to clear that code
at the next TOTP window boundary, but will leave newer clipboard content alone.

## 8. Update and rebuild

When you want a newer revision:

```sh
cd otp-bar
git pull --ff-only
swift test
./build-app.sh
./scripts/check-version.sh
open otp-bar.app
```

Quit the old copy before replacing it if macOS keeps showing the old menu-bar
process. Your imported accounts remain in macOS Keychain; rebuilding the app
does not export or sync them.

## Troubleshooting

### `swift` is not available

Install Xcode Command Line Tools with `xcode-select --install`, or install
Xcode from Apple and select it in **Xcode → Settings → Locations → Command
Line Tools**. Then open a new Terminal window and retry.

### `Permission denied` when running a script

From the repository directory, run:

```sh
chmod +x build-app.sh scripts/check-version.sh
```

Then rerun the build commands. This changes only the executable permission on
the local scripts.

### macOS still refuses to open the app

Make sure you built `otp-bar.app` yourself from the repository, attempt to open
that exact copy once, and use **System Settings → Privacy & Security → Open
Anyway** for the specific app. Do not disable Gatekeeper globally, run
`xattr -cr`, or replace the app with an unofficial download.

### The app is open but I cannot find it

It does not open a normal window. Look for the lock-shield icon in the menu bar;
on a crowded menu bar it may be hidden behind the Control Center or a menu-bar
management tool.

### The QR code is not recognized

Make sure the image contains the complete, sharp QR code and select the image
file itself, not a web-page preview. The supported inputs are standard TOTP QR
codes and Google Authenticator migration QR codes. HOTP and other OTP variants
are intentionally not imported.

### An import or Keychain operation fails

Retry from the menu-bar icon. If the app shows **Повторить** (Retry), use that
button to reload the vault before importing or deleting. Existing accounts are
not intentionally replaced when a Keychain save fails. If the problem persists,
quit and relaunch the app, then report the behavior with macOS version and
steps to reproduce—never attach a QR image or secret.

## Source-only releases

`VERSION` is the single release-version source and is embedded in the app
bundle. Maintainers publish an annotated tag such as `v0.1.0` only when its
version matches `VERSION`. GitHub Releases contain no prebuilt app, ZIP, or
other binary; they provide GitHub-generated source archives only.
