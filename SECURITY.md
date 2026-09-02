# Security policy

Please do not disclose a suspected vulnerability in a public issue. Before this
repository goes public, the maintainer must enable GitHub private vulnerability
reporting for `slvfmts/otp-bar`. Once enabled, use **Security → Report a
vulnerability** in the repository. Until that feature is enabled, do not post
security details publicly; the project has no public issue-based security channel.

Include a concise description, affected source revision, reproduction steps that
use synthetic data, and an impact assessment. Never include real TOTP seeds, QR
images, Keychain exports, or account identifiers in a report.

## Scope and threat model

The app protects the vault at rest with macOS Keychain and makes no network
requests. An unlocked user session can still provide the app access to the vault.
A compromised Mac, unlocked session, malicious process with appropriate access,
or leaked QR image/seed is outside what this small utility can reliably defend
against.

Keeping passwords and TOTP generation on one Mac trades factor separation for
convenience. TOTP also does not protect against phishing; passkeys or hardware
security keys are preferable when available.

## Distribution

This project is source-only. There is no security warranty, and unofficial
prebuilt binaries should not be trusted or used. GitHub Releases contain no
prebuilt application, archive, or other binary assets; GitHub-generated source
archives are the only release downloads.
