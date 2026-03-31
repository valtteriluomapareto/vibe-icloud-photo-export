# App Store CI Plan

Written against the repository state on 2026-03-31.

## Current State

The first App Store build has been submitted manually:

- **MARKETING_VERSION:** 1.0.2
- **CURRENT_PROJECT_VERSION:** 2
- **Bundle ID:** `com.valtteriluoma.photo-export-appstore`
- **Status:** Waiting for App Review (submitted 2026-03-31)
- **Method:** Manual `xcodebuild archive` + Transporter upload

The bundle ID is registered, the Apple Distribution certificate and provisioning profile exist, and the App Store Connect app record is set up. These are no longer prerequisites — they are done.

## Scope

This plan covers one thing: a GitHub Actions workflow (`release-app-store.yml`) that builds an App Store-signed archive and produces a downloadable `.pkg` artifact. The user manually downloads the `.pkg` and uploads it to App Store Connect via Transporter.

Auto-upload to App Store Connect is designed into the workflow as a future step but is not implemented in the initial version.

This plan does **not** cover:
- App Store Connect setup (app record, metadata, screenshots) — see `app-store-plan.md`
- Website or documentation changes — see `app-store-plan.md`
- The direct distribution workflow — that's `release-direct.yml`, already shipping

## Prerequisites

Before this workflow can run:

1. ~~`com.valtteriluoma.photo-export-appstore` bundle ID registered in Apple Developer portal~~ Done
2. ~~Apple Distribution certificate created and exported as `.p12`~~ Done
3. ~~Mac App Store distribution provisioning profile created for the above bundle ID~~ Done
4. GitHub Environment `app-store-release` created with required secrets (see Secrets section)

## Workflow Design

### Triggers

```yaml
on:
  push:
    tags:
      - 'v*'
  workflow_dispatch: {}
```

Both `release-direct.yml` and `release-app-store.yml` fire on the same `v*` tag. They run in parallel with independent concurrency groups. This is intentional — one tag produces both distribution artifacts.

`workflow_dispatch` enables manual test runs from any branch without creating a tag.

No `dry_run` input — unlike the direct workflow, the App Store workflow has no side effects to gate (no GitHub Release, no upload). Every run produces the same artifact. A `dry_run` / `upload_to_asc` toggle becomes relevant only when auto-upload is added later.

No `push.branches: [main]` trigger — unlike the direct workflow, building an App Store-signed artifact on every push to `main` is wasteful. Use `workflow_dispatch` for ad-hoc testing.

### Concurrency

```yaml
concurrency:
  group: release-app-store
  cancel-in-progress: false
```

Separate group from `release-direct`. Both workflows can run simultaneously on the same tag without interfering.

### Permissions

```yaml
permissions:
  contents: read
```

Read-only — this workflow does not create releases or push anything. The direct workflow needs `contents: write` for GitHub Releases; this one doesn't.

### Environment and Secrets

The workflow runs in a protected GitHub Environment named `app-store-release`, separate from the existing `direct-release` environment. Different certificates, different approval rules if needed.

### What It Produces

On every run: a `.pkg` artifact attached to the workflow run, downloadable from the Actions UI.

On tag pushes (non-dry-run): same `.pkg` artifact. No GitHub Release — that's `release-direct.yml`'s job. No App Store Connect upload — that's manual (initially).

## Signing Differences from Direct Distribution

| | Direct (`release-direct.yml`) | App Store (`release-app-store.yml`) |
|---|---|---|
| Certificate | Developer ID Application | Apple Distribution |
| Provisioning profile | Not required | Required (Mac App Store) |
| Export method | `developer-id` | `app-store-connect` |
| Notarization | Yes (notarytool + staple) | No (App Store handles it) |
| Output | `.app` → `.dmg` | `.pkg` (from `-exportArchive`) |
| Bundle ID | `com.valtteriluoma.photo-export` | `com.valtteriluoma.photo-export-appstore` (override) |

The entitlements file (`photo_export.entitlements`) is shared between both channels. Entitlements do not include the bundle ID, so the same file works.

## Build Configuration

### Bundle ID Override

The checked-in `PRODUCT_BUNDLE_IDENTIFIER` in `project.pbxproj` stays as `com.valtteriluoma.photo-export`. The App Store workflow overrides it at build time:

```
PRODUCT_BUNDLE_IDENTIFIER=com.valtteriluoma.photo-export-appstore
```

This is passed to both the `xcodebuild archive` and referenced in the ExportOptions.plist.

### Build Number

`CURRENT_PROJECT_VERSION` is set to `${{ github.run_number }}.${{ github.run_attempt }}` (e.g., `42.1`, `42.2` on rerun). This produces a monotonically increasing value that is unique even when a workflow run is retried — `github.run_number` stays the same on reruns, but `github.run_attempt` increments.

App Store Connect requires that each uploaded build has a higher `CURRENT_PROJECT_VERSION` than the last upload for the same `MARKETING_VERSION`. The `run_number.run_attempt` format satisfies this: fresh runs increment `run_number`; reruns of the same run increment `run_attempt`.

`CFBundleVersion` supports dotted integers (e.g., `42.2`), so App Store Connect accepts this format.

The first manually submitted build used `CURRENT_PROJECT_VERSION=2`. The first CI-produced build number will be `<run_number>.1`, which will be higher than `2` as long as the workflow has had at least 3 runs (including dry runs). If the workflow's first-ever `run_number` happens to be `1` or `2`, the first few CI builds for `MARKETING_VERSION` 1.0.2 would be rejected by App Store Connect. This is only an issue for `1.0.2` — any future `MARKETING_VERSION` starts fresh with no previous build number constraint. Workaround: run `workflow_dispatch` a few times before the first real tag push, or bump to `1.0.3` for the next release.

The `release-direct.yml` workflow also uses `github.run_number`, but each workflow has its own independent counter. There is no requirement for build numbers to match across channels.

The checked-in value in `project.pbxproj` stays at `1`.

### Architecture

Universal build: `ARCHS=arm64 x86_64`. Same as direct distribution.

## Secrets

Store in the `app-store-release` GitHub Environment:

| Secret | Description |
|---|---|
| `APPLE_DISTRIBUTION_CERTIFICATE_P12_BASE64` | Apple Distribution certificate exported as `.p12`, base64-encoded |
| `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password for the `.p12` file |
| `APPLE_TEAM_ID` | Apple Developer Team ID (same value as in `direct-release`) |
| `APP_STORE_PROVISIONING_PROFILE_BASE64` | Mac App Store distribution provisioning profile, base64-encoded |

For future auto-upload, add these to the same environment:

| Secret | Description |
|---|---|
| `APP_STORE_CONNECT_API_KEY_BASE64` | App Store Connect API key (`.p8` file), base64-encoded |
| `APP_STORE_CONNECT_API_KEY_ID` | Key ID from App Store Connect |
| `APP_STORE_CONNECT_API_ISSUER_ID` | Issuer ID from App Store Connect |

## Workflow Steps

### 1. Checkout and Build Context

Identical to `release-direct.yml`: checkout, determine if tag push or dry run, verify `MARKETING_VERSION` matches tag.

### 2. Xcode Selection

Same as direct: `sudo xcode-select -s /Applications/Xcode_16.2.app`.

### 3. Keychain Setup

Create a temporary keychain (same pattern as direct), but import the **Apple Distribution** certificate instead of Developer ID:

```bash
CERT_PATH="${RUNNER_TEMP}/certificate.p12"
echo "${APPLE_DISTRIBUTION_CERTIFICATE_P12_BASE64}" | base64 --decode > "${CERT_PATH}"
security import "${CERT_PATH}" \
  -k "${KEYCHAIN_PATH}" \
  -P "${APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
rm -f "${CERT_PATH}"

# Required: allow codesign to access the private key non-interactively.
# Without this, xcodebuild archive fails with "User interaction is not allowed"
# on headless CI runners. The direct workflow has the same step.
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "${KEYCHAIN_PASSWORD}" \
  "${KEYCHAIN_PATH}"
```

No `notarytool` credentials — App Store builds are not notarized by the developer.

### 4. Provisioning Profile Installation

Decode the provisioning profile from the secret, extract its UUID and name, and install it where Xcode can find it. All values needed by later steps are exported to `GITHUB_ENV` in this step:

```bash
PROFILE_PATH="${RUNNER_TEMP}/appstore.provisioningprofile"
echo "${APP_STORE_PROVISIONING_PROFILE_BASE64}" | base64 --decode > "${PROFILE_PATH}"

# Decode the profile's embedded plist (provisioning profiles are CMS-signed)
PROFILE_PLIST="$(security cms -D -i "${PROFILE_PATH}")"

# Extract the profile UUID — Xcode looks up profiles by UUID filename
PROFILE_UUID=$(/usr/libexec/PlistBuddy -c "Print UUID" /dev/stdin <<< "${PROFILE_PLIST}")

# Extract the profile name — referenced in ExportOptions.plist
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c "Print Name" /dev/stdin <<< "${PROFILE_PLIST}")

PROFILES_DIR="${HOME}/Library/MobileDevice/Provisioning Profiles"
mkdir -p "${PROFILES_DIR}"
cp "${PROFILE_PATH}" "${PROFILES_DIR}/${PROFILE_UUID}.provisioningprofile"
rm -f "${PROFILE_PATH}"

echo "Installed provisioning profile: ${PROFILE_UUID} (${PROFILE_NAME})"

# Export for later steps
echo "PROFILE_UUID=${PROFILE_UUID}" >> "$GITHUB_ENV"
echo "PROFILE_NAME=${PROFILE_NAME}" >> "$GITHUB_ENV"
echo "PROFILES_DIR=${PROFILES_DIR}" >> "$GITHUB_ENV"
```

### 5. Archive

```bash
BUILD_NUMBER="${{ github.run_number }}.${{ github.run_attempt }}"
ARCHIVE_PATH="${RUNNER_TEMP}/photo-export-appstore.xcarchive"

xcodebuild archive \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "${ARCHIVE_PATH}" \
  "ARCHS=arm64 x86_64" \
  CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=Apple Distribution" \
  DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
  "OTHER_CODE_SIGN_FLAGS=--keychain ${KEYCHAIN_PATH}" \
  PRODUCT_BUNDLE_IDENTIFIER=com.valtteriluoma.photo-export-appstore \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  2>&1 | tail -30
```

Key differences from direct:
- `CODE_SIGN_IDENTITY=Apple Distribution` (not Developer ID Application)
- `PRODUCT_BUNDLE_IDENTIFIER=com.valtteriluoma.photo-export-appstore`
- `CURRENT_PROJECT_VERSION` set explicitly

### 6. Export

Generate an ExportOptions.plist for App Store Connect distribution:

```bash
EXPORT_PATH="${RUNNER_TEMP}/export-appstore"
APPSTORE_BUNDLE_ID="com.valtteriluoma.photo-export-appstore"

cat > "${RUNNER_TEMP}/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>teamID</key>
  <string>${APPLE_TEAM_ID}</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>${APPSTORE_BUNDLE_ID}</key>
    <string>${PROFILE_NAME}</string>
  </dict>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist "${RUNNER_TEMP}/ExportOptions.plist" \
  -exportPath "${EXPORT_PATH}"
```

For macOS apps, `method: app-store-connect` produces a `.pkg` file in the export directory. This `.pkg` is what Transporter accepts.

### 7. Verify and Upload Artifact

```bash
PKG_FOUND=$(find "${EXPORT_PATH}" -name "*.pkg" -maxdepth 1)
if [ -z "${PKG_FOUND}" ]; then
  echo "::error::No .pkg found in export output"
  ls -la "${EXPORT_PATH}/"
  exit 1
fi

PKG_NAME="PhotoExport-AppStore-${{ steps.ctx.outputs.version }}-b${BUILD_NUMBER}.pkg"
PKG_PATH="${RUNNER_TEMP}/${PKG_NAME}"
mv "${PKG_FOUND}" "${PKG_PATH}"

echo "PKG_PATH=${PKG_PATH}" >> "$GITHUB_ENV"
echo "PKG_NAME=${PKG_NAME}" >> "$GITHUB_ENV"
```

Then attach as a workflow artifact (separate step):

```yaml
- name: Upload App Store pkg artifact
  uses: actions/upload-artifact@v4
  with:
    name: appstore-pkg
    path: ${{ env.PKG_PATH }}
```

### 8. Cleanup

Delete the temporary keychain and provisioning profile (in `if: always()`):

```bash
if [ -f "${KEYCHAIN_PATH}" ]; then
  security delete-keychain "${KEYCHAIN_PATH}" || true
fi
# Provisioning profile in ~/Library/MobileDevice is cleaned up when the runner is recycled,
# but clean it explicitly for hygiene.
rm -f "${PROFILES_DIR}/${PROFILE_UUID}.provisioningprofile" 2>/dev/null || true
```

## Manual Upload Process

After the workflow completes:

1. Go to **Actions > release-app-store** on GitHub
2. Download the `appstore-pkg` artifact from the workflow run
3. Unzip the downloaded artifact (GitHub wraps artifacts in a zip)
4. Open **Transporter** (free app from Apple, available on the Mac App Store)
5. Sign in with the Apple ID that has App Store Connect access
6. Drag the `.pkg` into Transporter and click **Deliver**
7. Wait for Transporter to validate and upload (typically 1-5 minutes)
8. The build appears in App Store Connect under **TestFlight** within 5-30 minutes after processing

The first submission (v1.0.2, build 2) was done manually. This process applies to all subsequent releases.

## Future: Auto-Upload

When manual upload becomes tedious, add an upload step to the workflow using the App Store Connect API key.

**Note:** `xcrun notarytool` is for notarization only — it cannot upload to App Store Connect. `xcrun altool --upload-package` was the traditional CI upload tool, but Apple deprecated it. Verify whether `altool` is still available in the Xcode version pinned by this workflow before relying on it. If removed, use the App Store Connect REST API directly or the `iTMSTransporter` CLI.

Upload with `altool` (if still available):

```bash
# Place the API key where altool expects it
API_KEY_DIR="${HOME}/.appstoreconnect/private_keys"
mkdir -p "${API_KEY_DIR}"
echo "${APP_STORE_CONNECT_API_KEY_BASE64}" | base64 --decode > "${API_KEY_DIR}/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"

xcrun altool --upload-package "${PKG_PATH}" \
  --type macos \
  --bundle-id "com.valtteriluoma.photo-export-appstore" \
  --bundle-version "${BUILD_NUMBER}" \
  --bundle-short-version-string "${{ steps.ctx.outputs.version }}" \
  --apiKey "${APP_STORE_CONNECT_API_KEY_ID}" \
  --apiIssuer "${APP_STORE_CONNECT_API_ISSUER_ID}"
```

Gate the upload behind a workflow input so manual-download-first runs skip it:

```yaml
workflow_dispatch:
  inputs:
    upload_to_asc:
      description: 'Upload to App Store Connect after building'
      required: true
      default: false
      type: boolean
```

Do not auto-submit to App Review. Upload only — review submission stays manual in App Store Connect.

## Relationship to `release-direct.yml`

Both workflows:
- Fire on the same `v*` tag
- Run in parallel (separate concurrency groups)
- Share the same `MARKETING_VERSION` from the tag
- Use independent `github.run_number` counters for build numbers
- Use the same entitlements file
- Use the same Xcode version and runner image

They differ in:
- GitHub Environment and secrets
- Certificate type
- Provisioning profile (App Store has one, direct doesn't)
- Export method and output format
- Post-build steps (direct: DMG + notarize + GitHub Release; App Store: `.pkg` artifact only)

## Execution Checklist

### Done

- [x] Create Apple Distribution certificate in Apple Developer portal
- [x] Export it as `.p12` with a password
- [x] Create a Mac App Store distribution provisioning profile for `com.valtteriluoma.photo-export-appstore`
- [x] Download the provisioning profile
- [x] First App Store build submitted manually (v1.0.2, build 2, waiting for review)

### Before first CI run (Valtteri)

- [ ] Create `app-store-release` GitHub Environment
- [ ] Add secrets: `APPLE_DISTRIBUTION_CERTIFICATE_P12_BASE64`, `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID`, `APP_STORE_PROVISIONING_PROFILE_BASE64`

### Engineering (AI-delegatable)

- [ ] Implement `release-app-store.yml` per this plan
- [ ] Verify with `workflow_dispatch` dry run from `main`

### First CI-produced App Store build

- [ ] Push a tag (or use `workflow_dispatch` on the tagged commit)
- [ ] Download `appstore-pkg` artifact from the workflow run
- [ ] Upload via Transporter
- [ ] Verify build appears in App Store Connect / TestFlight
