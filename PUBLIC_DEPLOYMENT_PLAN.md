# Public Deployment Plan — Photo Export (macOS)

This document describes the exact steps to ship the app publicly via direct download: a notarized Developer ID build hosted on your site or GitHub Releases. It includes update delivery with Sparkle, notarization commands, and required metadata.

---

## 0) Prerequisites

- Apple Developer Program membership (paid)
- Installed tools: Xcode 16.x, Xcode command line tools
- Certificates in Keychain Access:
  - Developer ID Application (for signing the app)
  - Optional: Developer ID Installer (only if you ship a `.pkg`, not required for `.zip`/`.dmg`)
- Repository access and a hosting location for downloads and appcast (e.g., GitHub Releases, S3/CloudFront, or your site over HTTPS)

---

## 1) Pre-release hardening (codebase)

- Verify bundle identifier is consistent (used in logs: `com.valtteriluoma.photo-export`).
- Ensure Photos permission string exists (`NSPhotoLibraryUsageDescription` in Info.plist).
- Keep App Sandbox with:
  - `com.apple.security.app-sandbox = true`
  - `com.apple.security.personal-information.photos-library = true`
  - `com.apple.security.files.user-selected.read-write = true`
- For updates (Sparkle), add:
  - `com.apple.security.network.client = true`
- Replace any `print` with `os.Logger`.
- Ensure temp-file write + atomic move is used during export (in place).
- Optionally add a Privacy Manifest (`PrivacyInfo.xcprivacy`).
- Add `LSApplicationCategoryType = public.app-category.photography` to Info.plist.

---

## 2) Versioning & metadata

- Update in Xcode project (Targets → General or Info):
  - `CFBundleShortVersionString` = marketing version (e.g., 1.0.0)
  - `CFBundleVersion` = build number (e.g., 1, 2, 3…)
- Update `README.md` with release notes if needed.
- Create/Update `CHANGELOG.md` with changes.

---

## 3) Direct Distribution — Step-by-step

### 3.1 Configure Release build

- Scheme: Use `photo-export` with `Release` configuration.
- Enable Hardened Runtime (Signing & Capabilities → Hardened Runtime).
- Ensure App Sandbox entitlements are present (`photo_export.entitlements`).
- Add network client entitlement if using Sparkle for updates.

### 3.2 Archive a Release build

From Xcode: Product → Archive → Distribute App → Developer ID → Export.

From CLI (build; signing must be configured for Release):
```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Release \
  -destination 'platform=macOS' \
  clean build
```

### 3.3 Notarize and staple

1) Create a ZIP (or DMG) of the built app:
```bash
ditto -c -k --sequesterRsrc --keepParent "photo-export.app" "photo-export-1.0.0.zip"
```
2) Store credentials (one-time):
```bash
xcrun notarytool store-credentials "AC_PROFILE" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```
3) Submit and wait:
```bash
xcrun notarytool submit "photo-export-1.0.0.zip" \
  --keychain-profile "AC_PROFILE" \
  --wait
```
4) Staple the ticket:
```bash
xcrun stapler staple "photo-export.app"
```

### 3.4 Host the build

- Upload the notarized, stapled `.zip` (or `.dmg`) to your HTTPS host.
- Create a GitHub Release (or equivalent) with release notes; attach the artifact.

### 3.5 Add automatic updates (Sparkle 2)

1) Add Sparkle 2 via Swift Package Manager (Xcode → Add Package → `https://github.com/sparkle-project/Sparkle`)
2) Link Sparkle to the app target; embed the Sparkle framework XPC installer per Sparkle 2 docs.
3) Generate Ed25519 keys (keep the private key offline):
```bash
# From Sparkle's bin tools (or build tools from the repo)
./bin/generate_keys
# Produces: ed25519_public.pem and ed25519_private.pem
```
4) Embed Sparkle public key in the app (Info.plist or code):
   - Set `SUPublicEDKey` to the contents of the public key (base64) or configure via API.
5) Add the appcast URL to Info.plist (or set programmatically):
   - `SUFeedURL = https://your.host/path/appcast.xml`
6) Sign your release ZIP with Sparkle’s `sign_update`:
```bash
./bin/sign_update "photo-export-1.0.0.zip" \
  --ed-key-file ed25519_private.pem \
  --ds-store
# This prints a signature you place into the appcast entry
```
7) Create and host `appcast.xml` over HTTPS. Minimal example entry:
```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Photo Export Updates</title>
    <item>
      <title>Version 1.0.0</title>
      <sparkle:releaseNotesLink>https://your.host/releases/1.0.0.html</sparkle:releaseNotesLink>
      <enclosure url="https://your.host/downloads/photo-export-1.0.0.zip"
                 sparkle:edSignature="REPLACE_WITH_SIGNATURE"
                 sparkle:version="1.0.0"
                 length="12345678"
                 type="application/octet-stream" />
    </item>
  </channel>
</rss>
```
8) In-app wiring:
   - Add “Check for Updates…” menu item calling Sparkle’s `SUUpdater`.
   - Optionally enable automatic update checks on launch.
9) Test end-to-end: ship 1.0.0, then build 1.0.1 and verify in-app update flow.

### 3.6 Verify on a clean machine

- Download the ZIP from your host, unzip, and launch. Gatekeeper should not block (signed + notarized + stapled).
- Run through core flows (Photos permission, selecting export destination, exporting a small month, Sparkle update check).

---

## 4) QA checklist (preflight)

- Permissions: first run, denied, restricted, limited, revoked mid-session.
- Destinations: internal disk, external drive (un/mount), network share; read-only and low-space scenarios.
- Photos libraries: small, large, iCloud-optimized (missing originals).
- Filenames: non-ASCII, very long, collisions.
- Resilience: force-quit during export → resume; no partial files left behind.
- Performance: month grid loads, memory stable; export throughput acceptable.
- Sparkle: update 1.0.0 → 1.0.1 succeeds and signature verifies.

---

## 5) Release checklist

- [ ] Bump version/build numbers
- [ ] Update changelog and README
- [ ] Commit and tag (e.g., `v1.0.0`)
- [ ] Build Release, sign, notarize, staple
- [ ] Publish GitHub Release with notes; attach artifacts
- [ ] Update and validate `appcast.xml`
- [ ] Smoke test download/update on clean machine

---

## 6) Post-release

- Monitor user feedback and crash reports (if added; keep crash reporting opt-in).
- Plan next patch release; repeat notarization/Sparkle steps.

---

## 7) Appendix

### 7.1 Notarization cheat sheet
```bash
# Create ZIP
ditto -c -k --sequesterRsrc --keepParent "photo-export.app" "photo-export-1.0.0.zip"

# Submit + wait
xcrun notarytool submit "photo-export-1.0.0.zip" \
  --keychain-profile "AC_PROFILE" \
  --wait

# Staple
xcrun stapler staple "photo-export.app"
```

### 7.2 Suggested Info.plist additions

- `LSApplicationCategoryType = public.app-category.photography`
- If Sparkle:
  - `SUFeedURL = https://your.host/path/appcast.xml`
  - `SUPublicEDKey = <base64 public key>` (or provide via API)

### 7.3 Entitlements summary

- `com.apple.security.app-sandbox = true`
- `com.apple.security.personal-information.photos-library = true`
- `com.apple.security.files.user-selected.read-write = true`
- For Sparkle/updates: `com.apple.security.network.client = true`

### 7.4 Privacy Manifest (optional but recommended)

Create `PrivacyInfo.xcprivacy`:
```json
{
  "version": 1,
  "privacy": {
    "tracking": false,
    "dataCategories": []
  }
}
```

Keep this document updated as the project evolves.
