# GitHub Actions Publishing Plan

## Status

**Fully implemented.** The release workflow shipped with v1.0.0 and is in active use. This document is kept as a decision record — it explains why the workflow was built the way it was.

Written against the repository state on 2026-03-25. The current release workflow is [`release-direct.yml`](../../.github/workflows/release-direct.yml) and the release process is documented in [`release-process.md`](release-process.md).

For App Store distribution planning, see [`app-store-plan.md`](app-store-plan.md).

## Scope

This plan covers one thing only:

- ship `v1.0.0` as a direct download from GitHub Releases

Explicitly out of scope for this document:

- Homebrew
- in-app update notifier / auto-update
- App Store / TestFlight workflow planning

If direct distribution works and the app gets real usage, write a separate App Store plan later.

---

## 1. State When Written (2026-03-25)

These items described the repo state when this plan was written. All have since been addressed:

- `MARKETING_VERSION` was `1.0` → now `1.0.2`
- bundle ID was `valtteriluoma.photo-export` → now `com.valtteriluoma.photo-export`
- `PhotoLibraryManager.swift` had `print()` calls → replaced with `os.Logger`
- Hardened Runtime was not set → now enabled for Release
- app category was not set → now `public.app-category.photography`
- deployment target was `15.4` → now `15.0`
- CI used `|| true` for lints → now strict
- app icon had no image files → `appstore.png` (1024x1024) now present
- privacy manifest did not exist → `PrivacyInfo.xcprivacy` now present and complete

---

## 2. Release Model

Keep the release flow simple:

1. Push tag `vX.Y.Z`
2. GitHub Actions builds, signs, notarizes, staples, and uploads a `.dmg`
3. Workflow creates a **draft** GitHub Release
4. Verify the draft `.dmg` on a separate macOS user account or machine
5. Publish the draft manually in the GitHub UI

Why this is enough:

- draft first is the right safety check
- manual publish is fine for a solo project
- a second workflow just to flip `draft=false` is not justified

No updater is planned for `v1.0.0`. Users update by downloading the latest release from GitHub.

---

## 3. What Was Done

Everything below is complete. Kept for decision-record context.

### 3.1 While waiting for enrollment (all done)

- CI hardening: Xcode pinned, `|| true` removed, concurrency control added, `.xcresult` uploaded
- Code fixes: `MARKETING_VERSION` set, bundle ID aligned, `print()` replaced with `os.Logger`, Hardened Runtime enabled, app category set
- App icon: `appstore.png` (1024x1024) added to asset catalog

### 3.2 After enrollment is complete (all done)

Created `release-direct.yml`. The implemented workflow differs from the original plan in one way: it also triggers on `push.branches: [main]` (in addition to `v*` tags and `workflow_dispatch`), so every merge to `main` runs the full build/sign/notarize pipeline against the protected `direct-release` environment.

Original operational requirements (all met):

- pin the macOS runner image and exact Xcode path, just like CI hardening
- add release-specific concurrency so two release runs do not race
- grant `contents: write` so the workflow can create a draft GitHub Release
- keep Automatic signing for local development; override to Manual signing inside the release workflow only
- `workflow_dispatch` runs build, sign, notarize, and upload workflow artifacts but do not create a GitHub Release

It does:

1. trigger on `v*` tags, `push` to `main`, and optional `workflow_dispatch` dry-runs
2. create a temporary keychain, unlock it, add it to the keychain search list, import the Developer ID Application certificate, and run `security set-key-partition-list` so `codesign` can use the identity non-interactively
3. store `notarytool` credentials in that temporary keychain
4. archive a universal Release build with `ARCHS=arm64 x86_64`, `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY="Developer ID Application"`, `DEVELOPMENT_TEAM=$APPLE_TEAM_ID`, and `OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN_PATH"`
5. export the archive with an `ExportOptions.plist` using `method = developer-id`, `signingStyle = manual`, `signingCertificate = Developer ID Application`, and `teamID = $APPLE_TEAM_ID`
6. create a `.dmg` with an `/Applications` symlink
7. notarize the `.dmg` and staple the `.dmg` because the `.dmg` is the shipped artifact users actually download
8. compute SHA-256 checksums
9. upload the `.dmg` and checksum file to the workflow run on every run
10. create a **draft** GitHub Release on tag pushes only
11. delete the temporary keychain in `always()`

Do not add:

- a publish workflow
- an update notifier
- distribution-channel build settings
- App Store workflow logic

---

## 4. Required Secrets

Store these in a protected GitHub Environment, for example `direct-release`:

- `DEVELOPER_ID_CERTIFICATE_P12_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_TEAM_ID`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

`APPLE_APP_SPECIFIC_PASSWORD` means the Apple ID app-specific password used by `notarytool`, not the Apple account password.

The temporary keychain password is generated at runtime (`uuidgen`), not stored as a secret.

---

## 5. Release Checklist

Before first public release:

1. Apple Developer Program enrollment complete
2. Developer ID Application certificate created and exported as a `.p12`
3. Apple ID app-specific password created for notarization
4. protected GitHub Environment `direct-release` created
5. release secrets added to `direct-release`
6. app icon 1024x1024 source image added to asset catalog
7. version set to `1.0.0`
8. bundle ID aligned to `com.valtteriluoma.photo-export`
9. Hardened Runtime enabled for Release
10. app category set
11. CI hardening merged
12. `release-direct.yml` implemented with pinned runner/Xcode, Manual Developer ID signing override, and temporary keychain cleanup
13. `workflow_dispatch` dry-run succeeds from `main`: `.dmg` is produced, no GitHub Release is created, `spctl --assess --type open` passes on the `.dmg`, and after mounting the `.dmg`, `spctl --assess --type execute` passes on the app bundle

For `v1.0.0`:

1. push tag `v1.0.0`
2. wait for draft release assets
3. download the `.dmg` on a separate macOS user account (or different Mac)
4. verify Gatekeeper on the `.dmg`: no `xattr -cr`, no "unidentified developer" dialog, and the mounted app passes launch checks
5. verify launch, Photos permission flow, destination selection, and a small export
6. publish the draft manually

---

## 6. Rollback

Keep rollback simple.

- bad draft: delete the draft release, delete the tag, fix the issue, retag
- bad public release: delete the release if appropriate, then ship a new patch version

Fix forward. Do not build complicated rollback process around a solo release flow.

---

## 7. Deferred Work

These are valid future topics, but not part of `v1.0.0`:

- `.zip` artifact (useful if Homebrew cask is added later)
- App Store packaging and App Store Connect automation
- in-app update checks
- Sparkle
- Homebrew
- provenance attestation
- fancy DMG layout
- lowering deployment target below `15.0` (verify against codebase first; currently `15.0`)
- separate per-architecture builds (currently shipping universal)

If any of those become real requirements, plan them in separate documents when they are actually next.
