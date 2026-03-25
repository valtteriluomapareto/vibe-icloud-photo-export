# GitHub Actions Publishing Plan For Photo Export

## Status

This document is a plan only. Nothing described here is implemented.

Written against the repository state on 2026-03-25.

## Scope

This plan covers one thing only:

- ship `v1.0.0` as a direct download from GitHub Releases

Explicitly out of scope for this document:

- Homebrew
- in-app update notifier / auto-update
- App Store / TestFlight workflow planning

If direct distribution works and the app gets real usage, write a separate App Store plan later.

---

## 1. Validated Current State

These points were checked against the repo before updating this plan.

### Code and project state

- `MARKETING_VERSION` is still `1.0`
- app bundle ID is still `valtteriluoma.photo-export`
- logger subsystems already use `com.valtteriluoma.photo-export`
- `PhotoLibraryManager.swift` still has 3 production `print()` calls
- Release build settings do not currently set Hardened Runtime in the project
- app category is not currently set in the project
- deployment target is currently `15.4`

### CI state

Current [ci.yml](/Users/valtsu/personal/photo-export/.github/workflows/ci.yml):

- uses a best-effort Xcode selection instead of a pinned path
- installs lint tools with `brew install ... || true`
- runs `swiftlint --strict || true`
- runs `swift-format lint ... || true`
- does not use concurrency control
- already generates `TestResults.xcresult` and uploads coverage to Codecov via `xccov2lcov.sh`
- does not upload `.xcresult` as a downloadable GHA artifact (useful for debugging test failures)

### App icon state

- [AppIcon.appiconset](/Users/valtsu/personal/photo-export/photo-export/Assets.xcassets/AppIcon.appiconset) contains only [Contents.json](/Users/valtsu/personal/photo-export/photo-export/Assets.xcassets/AppIcon.appiconset/Contents.json)
- there are slot entries for standard macOS sizes
- there are no actual image files in the asset catalog
- this is a release blocker — see section 3.1 for details

### Privacy manifest state

Do not treat `PrivacyInfo.xcprivacy` as a blocker for direct GitHub Releases right now.

- Apple’s current privacy-manifest enforcement is documented around App Store Connect uploads, not Developer ID notarization
- this repo does use APIs like `UserDefaults` and file metadata APIs, so if a privacy manifest is added later it must be accurate, not a stub

### Architecture

- the first public build is intentionally `arm64`-only
- the release workflow must explicitly set `ARCHS=arm64` to prevent a universal binary

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

## 3. What Needs To Be Done

Two work buckets, sequenced around the Apple Developer enrollment blocker.

### 3.1 While waiting for enrollment

These are all unblocked now.

#### CI hardening

1. Pin Xcode to a specific installed version path
2. Remove `|| true` from the blocking lint steps
3. Add workflow concurrency to cancel stale runs
4. Upload `.xcresult` as a downloadable GHA artifact (complements the existing Codecov upload)
5. Keep the Release build in CI with `CODE_SIGNING_ALLOWED=NO`

Note on `swift-format`:

- current CI already uses `lint`, not `format`
- if the repo is not clean enough to make it blocking immediately, use a short warning-only transition and then make it blocking

#### Code fixes

1. Change `MARKETING_VERSION` to `1.0.0`
2. Align the app bundle ID to `com.valtteriluoma.photo-export`
3. Replace the 3 `print()` calls in [PhotoLibraryManager.swift](/Users/valtsu/personal/photo-export/photo-export/Managers/PhotoLibraryManager.swift) with `os.Logger`
4. Enable Hardened Runtime for the Release configuration in the Xcode project
5. Add `LSApplicationCategoryType = public.app-category.photography`

#### App icon (design dependency)

The icon is the only release blocker that requires design work, not just code changes.

- [AppIcon.appiconset](/Users/valtsu/personal/photo-export/photo-export/Assets.xcassets/AppIcon.appiconset) has `Contents.json` slot entries but no actual image files
- a 1024x1024 source image is needed; Xcode 16 can generate all required sizes from it
- this cannot be parallelized with engineering work — it either needs to be designed or commissioned

### 3.2 After enrollment is complete

Create one workflow: `release-direct.yml`

Operational requirements:

- pin the macOS runner image and exact Xcode path, just like CI hardening
- add release-specific concurrency so two release runs do not race
- grant `contents: write` so the workflow can create a draft GitHub Release
- keep Automatic signing for local development; override to Manual signing inside the release workflow only
- allow `workflow_dispatch` only as a dry-run from `main`; it should build, sign, notarize, and upload workflow artifacts but must not create a GitHub Release

It should:

1. trigger on `v*` tags and optional `workflow_dispatch` dry-runs
2. create a temporary keychain, unlock it, add it to the keychain search list, import the Developer ID Application certificate, and run `security set-key-partition-list` so `codesign` can use the identity non-interactively
3. store `notarytool` credentials in that temporary keychain
4. archive a Release build with `ARCHS=arm64`, `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY="Developer ID Application"`, `DEVELOPMENT_TEAM=$APPLE_TEAM_ID`, and `OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN_PATH"`
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
- lowering deployment target below `15.4` (verify against codebase first)
- universal binary (`arm64` + `x86_64`)

If any of those become real requirements, plan them in separate documents when they are actually next.
