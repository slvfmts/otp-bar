# Changelog

All notable changes to otp-bar are documented here. This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

Changes after the initial source release will be listed here.

## [0.1.0] — 2026-09-02

Initial source-only release of the small macOS menu-bar utility.

### Added

- Native Swift/SwiftUI menu-bar app for local TOTP computation and one-click copying.
- Standard `otpauth://` and Google Authenticator migration QR image import.
- macOS Keychain storage with fail-closed loading and injected fake stores for tests.
- TOTP support for SHA-1, SHA-256, and SHA-512 with six- or eight-digit codes.
- Clipboard expiry cleanup that leaves newer clipboard contents untouched.
- Consistent universal-app metadata derived from the single `VERSION` source.
- Source-only CI and annotated-tag release validation; GitHub Releases carry no binaries.

### Security

- Documented the convenience trade-off of keeping password and TOTP flows on one Mac.
- Documented QR/seed handling, phishing limitations, and the absence of networking,
  telemetry, analytics, and sync.
- Added private vulnerability reporting guidance and a full-history secret scan in CI.

[Unreleased]: https://github.com/slvfmts/otp-bar/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/slvfmts/otp-bar/releases/tag/v0.1.0
