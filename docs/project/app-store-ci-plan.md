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

This plan covers one thing: a GitHub Actions workflow (`release-app-store.yml`) that builds an App Store-signed `.pkg` and uploads it to App Store Connect. No manual Transporter step — CI handles everything up to (but not including) App Review submission.

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
  workflow_dispatch:
    inputs:
      skip_upload:
        description: 'Build only — do not upload to App Store Connect'
        required: true
        default: false
        type: boolean
```

Both `release-direct.yml` and `release-app-store.yml` fire on the same `v*` tag. They run in parallel with independent concurrency groups. This is intentional — one tag produces both distribution artifacts.

`workflow_dispatch` enables manual test runs from any branch without creating a tag. The `skip_upload` input allows building without uploading (useful for testing signing and export).

Tag pushes always upload. `workflow_dispatch` uploads by default but can be skipped.

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

On tag pushes: uploads the `.pkg` to App Store Connect automatically. The build appears in TestFlight/App Store Connect within minutes. No GitHub Release — that's `release-direct.yml`'s job.

On `workflow_dispatch` with `skip_upload: true`: builds and attaches the artifact only, no upload.

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
| `APP_STORE_CONNECT_API_KEY_BASE64` | App Store Connect API key (`.p8` file), base64-encoded |
| `APP_STORE_CONNECT_API_KEY_ID` | Key ID from App Store Connect |
| `APP_STORE_CONNECT_API_ISSUER_ID` | Issuer ID from App Store Connect |

The API key is created in App Store Connect under Users and Access > Integrations > App Store Connect API. It needs the "App Manager" role (or higher) to upload builds.

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

### 8. Upload to App Store Connect

Conditional on: tag push, or `workflow_dispatch` with `skip_upload` not set.

```yaml
- name: Upload to App Store Connect
  if: steps.ctx.outputs.is_tag == 'true' || github.event.inputs.skip_upload != 'true'
  env:
    APP_STORE_CONNECT_API_KEY_BASE64: ${{ secrets.APP_STORE_CONNECT_API_KEY_BASE64 }}
    APP_STORE_CONNECT_API_KEY_ID: ${{ secrets.APP_STORE_CONNECT_API_KEY_ID }}
    APP_STORE_CONNECT_API_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_API_ISSUER_ID }}
```

```bash
echo "::group::Upload to App Store Connect"

# Place the API key where altool expects it
API_KEY_DIR="${HOME}/.appstoreconnect/private_keys"
mkdir -p "${API_KEY_DIR}"
API_KEY_PATH="${API_KEY_DIR}/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
echo "${APP_STORE_CONNECT_API_KEY_BASE64}" | base64 --decode > "${API_KEY_PATH}"

echo "Uploading ${PKG_NAME} to App Store Connect..."
echo "  Bundle ID: com.valtteriluoma.photo-export-appstore"
echo "  Version: ${{ steps.ctx.outputs.version }}"
echo "  Build: ${BUILD_NUMBER}"

xcrun altool --upload-package "${PKG_PATH}" \
  --type macos \
  --bundle-id "com.valtteriluoma.photo-export-appstore" \
  --bundle-version "${BUILD_NUMBER}" \
  --bundle-short-version-string "${{ steps.ctx.outputs.version }}" \
  --apiKey "${APP_STORE_CONNECT_API_KEY_ID}" \
  --apiIssuer "${APP_STORE_CONNECT_API_ISSUER_ID}" \
  --p8-file-path "${API_KEY_PATH}"

echo "Upload complete. Build will appear in App Store Connect / TestFlight within 5-30 minutes."
echo "::endgroup::"
```

`altool` validates the package before uploading. If validation fails, the step fails and the error is visible in the workflow log.

**Note:** `xcrun altool` is deprecated for notarization (replaced by `notarytool`) but `--upload-package` still works as of Xcode 16.2. If Apple removes it in a future Xcode, replace with the `iTMSTransporter` CLI or the App Store Connect REST API.

Do not auto-submit to App Review. The upload puts the build in "Processing" → "Ready to Submit" in App Store Connect. Review submission stays manual.

### 9. Cleanup

Delete the temporary keychain, provisioning profile, and API key (in `if: always()`):

```bash
if [ -f "${KEYCHAIN_PATH}" ]; then
  security delete-keychain "${KEYCHAIN_PATH}" || true
fi
rm -f "${PROFILES_DIR}/${PROFILE_UUID}.provisioningprofile" 2>/dev/null || true
rm -f "${HOME}/.appstoreconnect/private_keys/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8" 2>/dev/null || true
```

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
- Post-build steps (direct: DMG + notarize + GitHub Release; App Store: `.pkg` + upload to App Store Connect)

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
- [ ] Create App Store Connect API key (Users and Access > Integrations > App Store Connect API, "App Manager" role)
- [ ] Add secrets: `APP_STORE_CONNECT_API_KEY_BASE64`, `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`

### Engineering (AI-delegatable)

- [ ] Implement `release-app-store.yml` per this plan
- [ ] Verify with `workflow_dispatch` (`skip_upload: true`) dry run from `main`

### First CI-produced App Store build

- [ ] Run `workflow_dispatch` (with upload) or push a tag
- [ ] Verify build appears in App Store Connect / TestFlight automatically
