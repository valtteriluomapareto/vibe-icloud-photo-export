# GitHub Actions Publishing Plan For Photo Export

## Status

This document is a plan only.

Nothing described here is implemented by this document.

The intent is to define, in detail, how this repository should be prepared for public distribution via:

1. Direct download from GitHub Releases
2. Homebrew via an owned tap

The plan uses GitHub Actions as the only CI/CD system.

The plan is written against the repository state on 2026-03-23.

---

## 1. Executive Summary

The app is already close to the shape needed for public release:

- It is a native macOS SwiftUI app with a shared Xcode scheme.
- It already has unit tests and a GitHub Actions CI workflow.
- It already uses App Sandbox and Photos entitlements.
- It already has a direct-distribution deployment note.

The app is not yet publish-ready because release automation, signing automation, and several product-level decisions are still missing.

The release model is:

1. Keep GitHub Actions as the single automation platform.
2. Keep one ordinary CI workflow for pull requests and `main`.
3. Add one release workflow that can be dry-run manually and publishes only from `v*` tag pushes whose commit is already reachable from `main`.
4. Treat Homebrew as an owned tap first, not `homebrew/cask` core, until the app, metadata, naming, and release cadence are stable.
5. Do not add Sparkle in the first release phase. Homebrew handles updates for technical users. Sparkle can be reconsidered later if direct-download becomes a first-class distribution path.

---

## 2. Current Repository State

### 2.1 What already exists

- The app is a macOS app with target `photo-export`, tests, and a shared scheme in [README.md](README.md).
- Local command-line build and test instructions already exist in [README.md](README.md).
- There is already a GitHub Actions CI workflow in [.github/workflows/ci.yml](.github/workflows/ci.yml).
- The app already has App Sandbox, user-selected file access, and Photos access entitlements in [photo-export/photo_export.entitlements](photo-export/photo_export.entitlements).
- There is already a direct-distribution planning document in [PUBLIC_DEPLOYMENT_PLAN.md](PUBLIC_DEPLOYMENT_PLAN.md).

### 2.2 What the existing CI does today

The current workflow in [.github/workflows/ci.yml](.github/workflows/ci.yml):

- Runs on `macos-15`
- Builds Debug
- Runs unit tests with coverage
- Builds Release unsigned
- Installs lint tools on the runner
- Uploads coverage to Codecov

Current limitations:

1. Lint and format checks are non-blocking because they use `|| true`.
2. It has no artifact retention for `.xcresult` or signed release output.
3. It has no signing, notarization, or Homebrew cask update steps.

### 2.3 App configuration observations that matter for distribution

1. The app uses generated Info.plist values from Xcode build settings in [photo-export.xcodeproj/project.pbxproj](photo-export.xcodeproj/project.pbxproj).
2. `MARKETING_VERSION` is currently `1.0` and `CURRENT_PROJECT_VERSION` is currently `1`.
3. The bundle identifier is currently `valtteriluoma.photo-export`.
4. The app product name is effectively `$(TARGET_NAME)`, which means the built app bundle is `photo-export.app`, not `Photo Export.app`.
5. The minimum deployment target is currently macOS `15.4`.
6. The Photos permission usage string already exists.
7. The entitlements do not include network client access, which is correct for the current app and another reason not to add Sparkle now.

### 2.4 Current release-readiness gaps

#### Missing real app icon assets

The app icon catalog contains only the metadata file and no actual icon images:

- [photo-export/Assets.xcassets/AppIcon.appiconset/Contents.json](photo-export/Assets.xcassets/AppIcon.appiconset/Contents.json)

This is a hard blocker for public release.

#### Bundle ID inconsistency in code vs project settings

The Xcode project uses `valtteriluoma.photo-export`, but logger subsystems use `com.valtteriluoma.photo-export`.

This is visible in:

- [photo-export.xcodeproj/project.pbxproj](photo-export.xcodeproj/project.pbxproj)
- [photo-export/Managers/PhotoLibraryManager.swift](photo-export/Managers/PhotoLibraryManager.swift)
- [photo-export/Managers/ExportRecordStore.swift](photo-export/Managers/ExportRecordStore.swift)
- [photo-export/Managers/ExportManager.swift](photo-export/Managers/ExportManager.swift)
- [photo-export/Managers/ExportDestinationManager.swift](photo-export/Managers/ExportDestinationManager.swift)
- [photo-export/Managers/FileIOService.swift](photo-export/Managers/FileIOService.swift)
- [photo-export/Views/AssetDetailView.swift](photo-export/Views/AssetDetailView.swift)

This should be resolved before the first public release.

#### Release hardening settings not formalized

Hardened Runtime and app category metadata are not present in the current target build settings. The release workflow will inject these at build time via xcodebuild overrides, keeping the project usable for local development with Automatic signing.

#### Production logging still has `print(...)`

[photo-export/Managers/PhotoLibraryManager.swift](photo-export/Managers/PhotoLibraryManager.swift) still contains `print(...)` calls even though [README.md](README.md) says production code should use `os.Logger`. Should be cleaned up before public distribution.

#### Very narrow OS support

The app currently targets macOS `15.4`. This limits the potential audience. See Section 10.3 for the decision needed.

---

## 3. Release Channel Strategy

### 3.1 Channels

The public distribution channels are:

1. **GitHub Releases** — notarized DMG and ZIP, directly downloadable
2. **Homebrew** — via an owned tap, installing from the GitHub Release DMG

No App Store, TestFlight, or Sparkle in phase 1. These can be added later as separate workflow additions.

### 3.2 Why Homebrew + direct download

#### GitHub Releases gives:

- a trusted, familiar download origin for all users
- artifact hosting with no additional infrastructure
- SHA-256 checksums and release notes in one place
- a path to optional provenance attestation later, if it is explicitly added to the workflow

#### Homebrew gives:

- a standard install/upgrade path for technical users
- no custom in-app updater to design or maintain
- a natural fit for GitHub Releases as the artifact source

### 3.3 Why not Sparkle or App Store first

Sparkle adds: another entitlement, another signing story, another update UX, another support path. If Homebrew is the intended non-App-Store channel, Sparkle is unnecessary for the first release.

App Store adds: review process, store metadata, screenshots, privacy disclosures, provisioning profiles. It can be added as a separate workflow later without changing the Homebrew pipeline.

### 3.4 Homebrew strategy

Use an owned tap first.

Recommended structure:

- app repository: `valtteriluomapareto/photo-export`
- tap repository: `valtteriluomapareto/homebrew-tap`

Why own tap first:

1. Fully automatable from GitHub Actions.
2. Avoids depending on `homebrew/cask` review timing.
3. Avoids solving naming and product maturity during the first launch.
4. Can graduate to `homebrew/cask` later after the app stabilizes and has an established user base.

User install path:

```bash
brew tap valtteriluomapareto/tap
brew install --cask photo-export
# Or in one command:
brew install valtteriluomapareto/tap/photo-export
```

---

## 4. What Should Be Delivered

### 4.1 GitHub Actions workflows

#### Workflow 1: `ci.yml` (improved)

Purpose: ordinary CI for pull requests and `main`.

Responsibilities:

1. Check out the repo
2. Select Xcode
3. Install or verify lint tooling
4. Run blocking lint and format checks
5. Build Debug unsigned
6. Run unit tests with coverage
7. Upload `.xcresult` and coverage as GitHub artifacts

Changes from current CI:

1. Remove `|| true` from SwiftLint (make it a blocking gate)
2. Keep `|| true` on swift-format for now (separate, allow-failure)
3. Add concurrency control to cancel outdated runs on the same PR
4. Remove the redundant Release build step (the release workflow handles signed Release builds)
5. Upload `.xcresult` artifact for failure diagnosis

#### Workflow 2: `release.yml` (new)

Purpose: produce the public signed, notarized build.

Triggers:

1. `push` on `v*` tags for real releases
2. `workflow_dispatch` with an explicit version input for dry runs that build/sign/notarize and upload workflow artifacts, but do not publish a GitHub Release or update the Homebrew tap

Responsibilities:

1. Resolve version from the tag or manual input
2. Check out the repo with full history and verify that real release tags point to a commit reachable from `main`
3. Import the Developer ID certificate into a temporary keychain
4. Store notarization credentials in that temporary keychain
5. Archive the app in Release mode with signing overrides
6. Export using `developer-id` export options
7. Discover the exported `.app` path rather than hardcoding it
8. Notarize and staple the app
9. Create a basic DMG containing the app and `/Applications` shortcut
10. Notarize and staple the DMG
11. Create ZIP, compute SHA-256 checksums, and upload all artifacts to the workflow run
12. Create or update the GitHub Release with explicit release notes and attached artifacts (`push` tags only)
13. Update the Homebrew tap only if `HOMEBREW_TAP_TOKEN` is present (`push` tags only)
14. Clean up the temporary keychain (`if: always()`)

### 4.2 Supporting repository assets

1. Homebrew cask template in the tap repository
2. Release documentation in this repository

### 4.3 Documentation deliverables

Written instructions for:

1. How to run each workflow
2. How to dry-run the release workflow without publishing
3. Which secrets are required and how to generate them
4. Which Apple-side steps happen outside GitHub
5. How versioning and build numbering work
6. Which product assets and metadata are still missing
7. How end users can verify the binary and why they should trust it

---

## 5. Detailed Workflow Design

### 5.1 CI workflow design

#### Trigger

- `pull_request`
- `push` to `main`

#### Permissions

- `contents: read`

#### Concurrency

```yaml
concurrency:
  group: ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
```

#### Steps

1. Check out the repository.
2. Select the active Xcode installation.
3. Verify `xcodebuild -version`.
4. Install `swiftlint` and `swift-format`.
5. Run `swiftlint --strict` as a blocking step.
6. Run `swift-format lint --recursive photo-export` (allow-failure for now).
7. Build Debug unsigned with `CODE_SIGNING_ALLOWED=NO`.
8. Run unit tests with coverage and a `.xcresult` bundle.
9. Convert coverage to `lcov.info`.
10. Upload `.xcresult` and `lcov.info` as GitHub artifacts.

### 5.2 Release workflow design

#### Trigger

```yaml
on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:
    inputs:
      version:
        description: Semver without leading v, used only for dry-run artifact naming
        required: true
```

Manual runs are for build/sign/notarize validation only. They should upload artifacts to the workflow run, but they should not create a GitHub Release or update the tap.

#### Permissions

```yaml
permissions:
  contents: write
```

If build provenance attestation is added later, then also grant `attestations: write` and `id-token: write`. Do not grant those permissions before the attestation step exists.

#### Release environment

The release job should target a protected GitHub Environment such as `release`, with required reviewers. Keep signing/notarization secrets there rather than as repository-wide secrets.

#### Workflow constants

Centralize mutable product identity values in one `env:` block instead of hardcoding them across steps:

```yaml
env:
  APP_DISPLAY_NAME: "Photo Export"
  ARTIFACT_BASENAME: "PhotoExport"
  HOMEBREW_CASK_TOKEN: "photo-export"
  KEYCHAIN_PATH: "${{ runner.temp }}/build.keychain-db"
```

If the app identity changes, update this block and the cask template together.

#### Version source

For tag pushes, the git tag is the input. `v1.2.3` becomes marketing version `1.2.3`.

For `workflow_dispatch`, require an explicit `version` input such as `1.2.3`.

```yaml
- name: Resolve version
  id: version
  run: |
    if [ "${GITHUB_EVENT_NAME}" = "workflow_dispatch" ]; then
      VERSION="${{ inputs.version }}"
    else
      VERSION="${GITHUB_REF_NAME#v}"
    fi

    if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
      echo "Invalid version: $VERSION" >&2
      exit 1
    fi

    echo "version=$VERSION" >> "$GITHUB_OUTPUT"
```

#### Build number source

Use `github.run_number` from the release workflow.

Why this rule:

1. Always monotonically increasing (GitHub guarantees this per-workflow)
2. Simple, no computation needed
3. Deterministic: you can look up run 47 in the Actions UI
4. Git commit count is fragile (rebases change it); epoch-based is less readable

If you re-run a failed release, the run number stays the same (same run). If you push a new tag, it gets the next run number.

Both values are passed as xcodebuild overrides; no project file edits per release:

```bash
MARKETING_VERSION="${{ steps.version.outputs.version }}"
CURRENT_PROJECT_VERSION="${{ github.run_number }}"
```

#### Publish gate

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0

- name: Verify tagged commit is on main
  if: github.event_name == 'push'
  run: |
    git fetch origin main --depth=1
    git merge-base --is-ancestor "$GITHUB_SHA" "origin/main"
```

This blocks publishing from arbitrary detached tags or stale commits that are not actually on `main`.

#### Step: Import signing certificate

```yaml
- name: Import signing certificate
  env:
    P12_BASE64: ${{ secrets.DEVELOPER_ID_CERTIFICATE_P12_BASE64 }}
    P12_PASSWORD: ${{ secrets.DEVELOPER_ID_CERTIFICATE_PASSWORD }}
    KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
  run: |
    echo "$P12_BASE64" | base64 --decode > "$RUNNER_TEMP/certificate.p12"

    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

    security import "$RUNNER_TEMP/certificate.p12" \
      -k "$KEYCHAIN_PATH" \
      -P "$P12_PASSWORD" \
      -T /usr/bin/codesign \
      -T /usr/bin/security

    security set-key-partition-list -S apple-tool:,apple:,codesign: \
      -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

    rm "$RUNNER_TEMP/certificate.p12"
```

This keeps the signing identity in an isolated temporary keychain for the duration of the job.

#### Step: Store notarization credentials

```yaml
- name: Store notarization credentials
  env:
    APPLE_ID: ${{ secrets.APPLE_ID }}
    APPLE_ID_PASSWORD: ${{ secrets.APPLE_ID_PASSWORD }}
    APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
  run: |
    xcrun notarytool store-credentials "ci-notary" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_ID_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --keychain "$KEYCHAIN_PATH"
```

The current repository already documents `notarytool store-credentials`. Reuse that pattern in CI instead of claiming direct inline credentials are required.

#### Step: Archive

```yaml
- name: Build and archive
  run: |
    set -o pipefail
    xcodebuild archive \
      -project photo-export.xcodeproj \
      -scheme "photo-export" \
      -configuration Release \
      -destination 'platform=macOS' \
      -archivePath "$RUNNER_TEMP/photo-export.xcarchive" \
      MARKETING_VERSION="${{ steps.version.outputs.version }}" \
      CURRENT_PROJECT_VERSION="${{ github.run_number }}" \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="Developer ID Application" \
      DEVELOPMENT_TEAM="${{ secrets.APPLE_TEAM_ID }}" \
      ENABLE_HARDENED_RUNTIME=YES \
      OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN_PATH --timestamp --options runtime"
```

Using `xcodebuild archive` followed by `xcodebuild -exportArchive` is the correct flow for distribution builds. A raw `build` is not a release artifact.

#### Step: Export

```yaml
- name: Export archive
  run: |
    cat > "$RUNNER_TEMP/ExportOptions.plist" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>method</key>
        <string>developer-id</string>
        <key>teamID</key>
        <string>${{ secrets.APPLE_TEAM_ID }}</string>
        <key>signingStyle</key>
        <string>manual</string>
        <key>signingCertificate</key>
        <string>Developer ID Application</string>
    </dict>
    </plist>
    PLIST

    xcodebuild -exportArchive \
      -archivePath "$RUNNER_TEMP/photo-export.xcarchive" \
      -exportPath "$RUNNER_TEMP/export" \
      -exportOptionsPlist "$RUNNER_TEMP/ExportOptions.plist"
```

The `ExportOptions.plist` with `method = developer-id` tells Xcode to sign for direct distribution.

#### Step: Discover exported app and artifact paths

```yaml
- name: Discover exported app
  id: app
  run: |
    APP_PATH="$(find "$RUNNER_TEMP/export" -maxdepth 1 -type d -name '*.app' -print -quit)"
    test -n "$APP_PATH"

    {
      echo "app_path=$APP_PATH"
      echo "app_bundle_name=$(basename "$APP_PATH")"
    } >> "$GITHUB_OUTPUT"

- name: Define artifact paths
  id: artifacts
  run: |
    VERSION="${{ steps.version.outputs.version }}"
    DMG_PATH="$RUNNER_TEMP/${ARTIFACT_BASENAME}-${VERSION}.dmg"
    ZIP_PATH="$RUNNER_TEMP/${ARTIFACT_BASENAME}-${VERSION}.zip"

    {
      echo "dmg_path=$DMG_PATH"
      echo "dmg_name=$(basename "$DMG_PATH")"
      echo "zip_path=$ZIP_PATH"
      echo "zip_name=$(basename "$ZIP_PATH")"
    } >> "$GITHUB_OUTPUT"
```

Do not hardcode `photo-export.app` in the workflow. The bundle filename is one of the unresolved identity decisions in Section 10.

#### Step: Notarize

```yaml
- name: Notarize app
  run: |
    # Create ZIP for notarization submission
    ditto -c -k --sequesterRsrc --keepParent \
      "${{ steps.app.outputs.app_path }}" \
      "$RUNNER_TEMP/photo-export-notarize.zip"

    # Submit for notarization and wait
    xcrun notarytool submit "$RUNNER_TEMP/photo-export-notarize.zip" \
      --keychain-profile "ci-notary" \
      --keychain "$KEYCHAIN_PATH" \
      --wait --timeout 30m

    # Staple the notarization ticket to the app
    xcrun stapler staple "${{ steps.app.outputs.app_path }}"
```

This uses the credentials stored in the temporary keychain. If the team later switches to App Store Connect API key auth, replace the `store-credentials` step and `submit` flags together.

#### Step: Create DMG

```yaml
- name: Create DMG
  run: |
    STAGING_DIR="$RUNNER_TEMP/dmg-root"
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"

    cp -R "${{ steps.app.outputs.app_path }}" "$STAGING_DIR/"
    ln -s /Applications "$STAGING_DIR/Applications"

    hdiutil create \
      -volname "$APP_DISPLAY_NAME" \
      -srcfolder "$STAGING_DIR" \
      -ov -format UDZO \
      "${{ steps.artifacts.outputs.dmg_path }}"

    # Notarize the DMG itself
    xcrun notarytool submit "${{ steps.artifacts.outputs.dmg_path }}" \
      --keychain-profile "ci-notary" \
      --keychain "$KEYCHAIN_PATH" \
      --wait --timeout 30m

    xcrun stapler staple "${{ steps.artifacts.outputs.dmg_path }}"
```

The first implementation should prefer a simple `hdiutil` DMG that is deterministic and fails loudly. Fancy Finder window layout is a separate polish task, not a release blocker.

#### Step: Create ZIP

```yaml
- name: Create ZIP
  run: |
    ditto -c -k --sequesterRsrc --keepParent \
      "${{ steps.app.outputs.app_path }}" \
      "${{ steps.artifacts.outputs.zip_path }}"
```

#### Step: Compute checksums and upload workflow artifacts

```yaml
- name: Compute checksums
  id: checksums
  run: |
    DMG_SHA256="$(shasum -a 256 "${{ steps.artifacts.outputs.dmg_path }}" | awk '{print $1}')"
    ZIP_SHA256="$(shasum -a 256 "${{ steps.artifacts.outputs.zip_path }}" | awk '{print $1}')"

    {
      echo "dmg_sha256=$DMG_SHA256"
      echo "zip_sha256=$ZIP_SHA256"
    } >> "$GITHUB_OUTPUT"

- name: Upload release artifacts to the workflow run
  uses: actions/upload-artifact@v4
  with:
    name: release-${{ steps.version.outputs.version }}
    path: |
      ${{ steps.artifacts.outputs.dmg_path }}
      ${{ steps.artifacts.outputs.zip_path }}
```

Workflow artifact upload is not optional. It is the only safe dry-run output and the first place to inspect a failed release build.

#### Step: Create GitHub Release

```yaml
- name: Build release notes body
  if: github.event_name == 'push'
  id: release_notes
  run: |
    BODY_PATH="$RUNNER_TEMP/release-notes.md"
    cat > "$BODY_PATH" <<EOF
    ## $APP_DISPLAY_NAME ${{ steps.version.outputs.version }}

    ### Downloads
    - DMG (recommended): `${{ steps.artifacts.outputs.dmg_name }}` — SHA256: `${{ steps.checksums.outputs.dmg_sha256 }}`
    - ZIP: `${{ steps.artifacts.outputs.zip_name }}` — SHA256: `${{ steps.checksums.outputs.zip_sha256 }}`
    EOF

    if [ -n "${{ secrets.HOMEBREW_TAP_TOKEN }}" ]; then
      cat >> "$BODY_PATH" <<EOF

    ### Install via Homebrew
    ```bash
    brew install valtteriluomapareto/tap/$HOMEBREW_CASK_TOKEN
    ```
    EOF
    fi

    echo "body_path=$BODY_PATH" >> "$GITHUB_OUTPUT"

- name: Create GitHub Release
  if: github.event_name == 'push'
  uses: softprops/action-gh-release@v2
  with:
    tag_name: ${{ github.ref_name }}
    name: ${{ env.APP_DISPLAY_NAME }} ${{ steps.version.outputs.version }}
    draft: false
    prerelease: false
    body_path: ${{ steps.release_notes.outputs.body_path }}
    files: |
      ${{ steps.artifacts.outputs.dmg_path }}
      ${{ steps.artifacts.outputs.zip_path }}
```

Do not mix `generate_release_notes: true` with a separately constructed checksum body unless you have explicitly tested the merged output. First release should prefer deterministic notes.

#### Step: Update Homebrew tap

```yaml
- name: Update Homebrew Cask
  if: github.event_name == 'push' && secrets.HOMEBREW_TAP_TOKEN != ''
  env:
    GH_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
  run: |
    VERSION="${{ steps.version.outputs.version }}"
    DMG_NAME="${{ steps.artifacts.outputs.dmg_name }}"
    DMG_SHA256="${{ steps.checksums.outputs.dmg_sha256 }}"
    APP_BUNDLE_NAME="${{ steps.app.outputs.app_bundle_name }}"

    # Clone the tap repo
    git clone "https://x-access-token:${GH_TOKEN}@github.com/valtteriluomapareto/homebrew-tap.git" \
      "$RUNNER_TEMP/homebrew-tap"

    # Update the cask formula
    cat > "$RUNNER_TEMP/homebrew-tap/Casks/${HOMEBREW_CASK_TOKEN}.rb" <<RUBY
    cask "${HOMEBREW_CASK_TOKEN}" do
      version "${VERSION}"
      sha256 "${DMG_SHA256}"

      url "https://github.com/valtteriluomapareto/photo-export/releases/download/v#{version}/${DMG_NAME}"
      name "${APP_DISPLAY_NAME}"
      desc "Export Apple Photos library to organized folder hierarchy"
      homepage "https://github.com/valtteriluomapareto/photo-export"

      # Keep this aligned with the real minimum supported macOS version.
      depends_on macos: ">= :sequoia"

      app "${APP_BUNDLE_NAME}"

      # Keep these paths aligned with the final PRODUCT_BUNDLE_IDENTIFIER.
      zap trash: [
        "~/Library/Preferences/com.valtteriluoma.photo-export.plist",
        "~/Library/Application Support/com.valtteriluoma.photo-export",
      ]
    end
    RUBY

    cd "$RUNNER_TEMP/homebrew-tap"
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add "Casks/${HOMEBREW_CASK_TOKEN}.rb"
    if git diff --cached --quiet; then
      echo "Tap already up to date"
      exit 0
    fi
    git commit -m "Update ${HOMEBREW_CASK_TOKEN} to ${VERSION}"
    git push
```

The tap update is genuinely optional only if the workflow has an `if:` guard. Without that guard, missing tap credentials turn a successful release into a failed workflow after the artifacts are already published.

#### Step: Cleanup

```yaml
- name: Cleanup
  if: always()
  run: |
    security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
```

The `if: always()` ensures the keychain is removed even on failure.

#### Artifact format rationale

Both DMG and ZIP are produced:

- **DMG** (primary): mounted install experience with Applications shortcut, used by Homebrew cask
- **ZIP** (secondary): simpler alternative for users who prefer it

---

## 6. Prerequisites (Manual, Outside GitHub)

### 6.1 Apple Developer Program

1. Enroll at https://developer.apple.com/programs/ ($99/year, 24-48h approval).
2. After enrollment, create a **Developer ID Application** certificate in Certificates, Identifiers & Profiles.
3. Export the certificate + private key from Keychain Access as `.p12`:
   - Open Keychain Access, find "Developer ID Application: Your Name"
   - Expand to reveal the private key
   - Select both the certificate AND the private key
   - Right-click, "Export 2 items...", choose `.p12` format
   - Set a strong password
4. Create an app-specific password at https://appleid.apple.com/account/manage (label: "GitHub Actions Notarization").
5. Find your Team ID: `security find-identity -v -p codesigning` — the Team ID is the 10-character alphanumeric string in parentheses.

### 6.2 GitHub Secrets

Prefer GitHub Environment secrets in a protected `release` environment rather than repository-wide secrets.

Navigate to Settings > Environments > `release` > Secrets and variables, and add:

| Secret | Value | How to generate |
|--------|-------|-----------------|
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Base64-encoded `.p12` file | `base64 -i certificate.p12 \| pbcopy` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password from .p12 export | Set during Keychain export |
| `APPLE_ID` | Your Apple ID email | — |
| `APPLE_ID_PASSWORD` | App-specific password | Generated at appleid.apple.com (NOT your account password) |
| `APPLE_TEAM_ID` | 10-character Team ID | From `security find-identity` output |
| `KEYCHAIN_PASSWORD` | Random string for temp CI keychain | `openssl rand -base64 24` |
| `HOMEBREW_TAP_TOKEN` | GitHub PAT with `repo` scope for tap repo | Settings > Developer settings > Personal access tokens. Optional; only needed once tap auto-update is enabled |

`notarytool` can also authenticate with an App Store Connect API key instead of Apple ID + app-specific password. If the team later switches to that model, replace the Apple ID secrets and update both the `store-credentials` step and `submit` flags together.

### 6.3 Homebrew Tap Repository

Create `valtteriluomapareto/homebrew-tap` on GitHub with this structure:

```
homebrew-tap/
  Casks/
    photo-export.rb
  README.md
```

The `HOMEBREW_TAP_TOKEN` must be a PAT (classic with `repo` scope, or fine-grained with Contents write access) that can push to this repository.

---

## 7. Xcode Project Changes

These changes should be applied before the first release but are not strictly required in the project file — the release workflow injects them via xcodebuild overrides. Applying them in the project is cleaner and makes local Release builds match CI.

### 7.1 Enable Hardened Runtime (Release config)

Required for notarization. Add to Release build settings in `project.pbxproj`:

```
ENABLE_HARDENED_RUNTIME = YES;
```

### 7.2 Add app category

Add to both Debug and Release build settings:

```
INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.photography";
```

### 7.3 Add Privacy Manifest

Create `photo-export/PrivacyInfo.xcprivacy`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array/>
</dict>
</plist>
```

Add this file to the Xcode project target.

### 7.4 Signing stays Automatic

Signing stays `Automatic` in the project for local development. The CI release workflow overrides to `Manual` + `Developer ID Application` via xcodebuild flags. No project file change needed for signing.

---

## 8. Build Numbering Plan

### 8.1 Two version fields

| Field | Xcode setting | Purpose |
|-------|---------------|---------|
| Marketing version | `MARKETING_VERSION` / `CFBundleShortVersionString` | User-visible version (e.g. `1.2.3`) |
| Build number | `CURRENT_PROJECT_VERSION` / `CFBundleVersion` | Machine-generated, monotonically increasing |

### 8.2 Marketing version policy

Use semantic versioning: `MAJOR.MINOR.PATCH` (e.g., `1.0.0`, `1.0.1`, `1.1.0`).

Source of truth: the git tag. `v1.2.3` becomes `1.2.3`.

### 8.3 Build number policy

Use `github.run_number` — the auto-incrementing integer GitHub assigns to each run of this release workflow.

Why this rule:

1. Always monotonically increasing (GitHub guarantees this per-workflow)
2. Simple — no computation needed
3. Deterministic — run 47 always maps to the same run in the Actions UI
4. Re-running a failed release keeps the same run number (same run)
5. Pushing a new tag gets the next run number

Alternatives considered:

- **Git commit count**: fragile (rebases change it)
- **UTC timestamp** (`YYYYMMDDHHMMSS`): less readable, higher entropy than needed
- **Manual counter**: requires committing bumps, creates merge noise

### 8.4 Implementation principle

Do not commit build number bumps into the Xcode project for each release. Instead:

1. Keep a stable baseline in the project (`CURRENT_PROJECT_VERSION = 1`)
2. Override both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the release workflow

This avoids release-only git churn and keeps CI authoritative for versioning.

---

## 9. How to Use the Workflows

### 9.1 How to use CI

1. Open a pull request.
2. Wait for `ci.yml`.
3. Inspect the uploaded `.xcresult` artifact on failure.

### 9.2 How to publish a release

1. Ensure all changes are merged to `main` and CI is green.
2. Optionally run `release.yml` via `workflow_dispatch` with an explicit version such as `1.0.0` to validate signing, notarization, DMG/ZIP creation, and artifact upload without publishing.
3. Create and push a tag from the already-merged `main` commit:

```bash
git tag v1.0.0
git push origin v1.0.0
```

4. The `release.yml` workflow will automatically:
   - Build and sign with Developer ID
   - Notarize with Apple
   - Create DMG and ZIP
   - Upload DMG and ZIP as workflow artifacts
   - Create a GitHub Release with artifacts and checksums
   - Update the Homebrew tap cask if `HOMEBREW_TAP_TOKEN` is configured

5. Monitor the Actions run for success.

6. Validate:
   - Download the DMG on a clean Mac, verify Gatekeeper passes
   - Verify binary architecture with `lipo -info`
   - `brew install valtteriluomapareto/tap/photo-export` succeeds

### 9.3 What to verify after every release

1. Notarization success in the workflow logs
2. GitHub Release has both DMG and ZIP attached
3. SHA-256 checksums are present in release notes
4. Homebrew cask was updated with correct version and SHA, or was intentionally skipped because the token is unset
5. `lipo -info` on the shipped app binary matches the architecture policy you intended
6. App launches without Gatekeeper warnings on a clean Mac

---

## 10. Decisions Needed Before Moving Forward

These gaps should be explicitly decided before implementing release automation.

### 10.1 Final app identity

Decide all of the following together:

1. Final app name
2. Final bundle identifier
3. Final app bundle filename (e.g., `photo-export.app` vs `Photo Export.app`)
4. GitHub Release artifact naming convention
5. Homebrew cask token
6. Short description for Homebrew and GitHub

Currently there is visible inconsistency between the human app name, bundle name, bundle identifier, and logger subsystem names. These should all align before the first public release.

**Recommendation**: Standardize bundle ID to `com.valtteriluoma.photo-export` (reverse-DNS convention).

The release workflow should reference these values via one `env:` block, not via repeated hardcoded strings spread across steps.

### 10.2 Iconography

Public release should not proceed without final app icon assets. The icon set is currently structurally present but not populated with actual image files.

This is a hard blocker.

### 10.3 OS support policy

The app currently targets macOS `15.4`. This is very recent (released March 2025).

Questions to answer:

1. Is 15.4 required by actual APIs used in the app?
2. Would 15.0 be viable?
3. Is the target audience likely to be on older macOS versions?

This affects Homebrew audience size, the `depends_on macos` constraint in the cask formula, and whether the release can honestly claim Sequoia-wide support.

**Recommendation**: Lower to `15.0` (Sequoia) unless a specific 15.4 API is needed. If 15.4 really is required, document that exact minimum clearly in the README, release notes, and cask instead of implying all of Sequoia is supported.

### 10.4 GitHub repository URL

The cask formula and release workflow reference the GitHub org/repo path. Confirm the correct value (e.g., `valtteriluomapareto/photo-export`).

### 10.5 Privacy and trust posture

The app handles private personal data (photo libraries). Decide and document before launch:

1. Whether the app sends anything over the network (currently: no)
2. Whether analytics exist (currently: no)
3. Whether crash reporting exists (currently: no)
4. Whether exported metadata (EXIF, location) is preserved or modified
5. How this is communicated to users

If the answer is "no telemetry, no account, local-only processing", say that plainly and prominently in the README and release notes.

### 10.6 Support model

Decide:

1. Where users report bugs (GitHub Issues is the natural choice)
2. Where release notes live (GitHub Releases)
3. Whether there is an issue template

### 10.7 Items that can be deferred

| Item | Notes |
|------|-------|
| Sparkle auto-updates | Orthogonal, add later if direct-download needs its own update path |
| App Store / TestFlight | Separate workflow, can be added later without changing the Homebrew pipeline |
| Changelog auto-generation | Nice to have, not blocking |
| Fancy DMG window layout | Cosmetic only; the first release can use a simple `hdiutil` DMG with the app and an `/Applications` symlink |
| Provenance attestation | Optional enhancement via `actions/attest-build-provenance`, but only after the workflow actually emits an attestation |
| Submit to official homebrew-cask | Requires established user base; start with personal tap |
| Signed git tags (GPG) | Optional enhancement for advanced verification |

Binary architecture is not a defer-by-default item. Prefer a universal binary unless you intentionally choose Apple Silicon only, and verify the shipped artifact with `lipo -info` before release.

---

## 11. End-User Trust Plan

Trust should not rely on a single mechanism. It should be layered.

### 11.1 Apple trust chain

1. **Developer ID signing**: Gatekeeper trusts the app, no "unidentified developer" warning.
2. **Apple notarization**: Apple scans for malware; the stapled ticket works offline.

### 11.2 Download integrity

1. **Homebrew SHA-256**: The cask verifies the DMG checksum on install.
2. **GitHub Release checksums**: SHA-256 published in release notes for manual verification.

### 11.3 Open-source transparency

1. **Public source code**: Users can audit every line.
2. **Public CI logs**: anyone can see how the binary was produced and where it came from.
3. **Tagged releases**: Each release maps to a specific commit.
4. **Public workflow definitions**: The release pipeline itself is auditable.

### 11.4 Optional trust enhancements (can be added later)

1. **GitHub build provenance attestation** via `actions/attest-build-provenance`: cryptographic proof that artifacts were built by the CI pipeline.
2. **GPG-signed git tags**: prove release authenticity beyond GitHub's web UI.
3. **Verification instructions for advanced users**: document commands like `codesign --verify`, `spctl --assess`, and `shasum -a 256` in the README.

### 11.5 Brand consistency

Trust is also affected by polish. Before launch, make sure these all match:

1. App icon
2. App name in all contexts
3. Bundle name
4. GitHub Release naming
5. Homebrew cask name

Inconsistency makes even a technically sound release feel suspicious.

---

## 12. First Release Checklist

When all decisions are made and prerequisites are in place:

1. [ ] Complete Apple Developer enrollment
2. [ ] Generate Developer ID Application certificate
3. [ ] Export as `.p12`, base64-encode it
4. [ ] Create app-specific password for notarization
5. [ ] Create a protected GitHub `release` environment with required reviewers
6. [ ] Set the required release secrets there, plus optional `HOMEBREW_TAP_TOKEN` if tap auto-update is enabled
7. [ ] Resolve bundle ID inconsistency
8. [ ] Add real app icon assets
9. [ ] Apply Xcode project changes (hardened runtime, privacy manifest, category)
10. [ ] Create `valtteriluomapareto/homebrew-tap` repo with initial cask
11. [ ] Merge release workflow + CI improvements to `main`
12. [ ] Run a `workflow_dispatch` dry run with an explicit version and verify it uploads artifacts but does not publish a GitHub Release or update the tap
13. [ ] Tag and push: `git tag v1.0.0 && git push origin v1.0.0`
14. [ ] Monitor Actions run
15. [ ] Verify on clean Mac: download DMG, Gatekeeper check, launch app
16. [ ] Verify binary architecture with `lipo -info`
17. [ ] Verify Homebrew: `brew install valtteriluomapareto/tap/photo-export`
18. [ ] Write release notes

---

## 13. Files to Create or Modify

| Action | File | Purpose |
|--------|------|---------|
| **Create** | `.github/workflows/release.yml` | Release pipeline |
| **Create** | `photo-export/PrivacyInfo.xcprivacy` | Privacy manifest |
| **Modify** | `photo-export.xcodeproj/project.pbxproj` | Hardened runtime, app category |
| **Modify** | `.github/workflows/ci.yml` | Concurrency, lint strictness, artifact upload |
| **Create** (separate repo) | `homebrew-tap/Casks/photo-export.rb` | Homebrew cask formula |
| **Create** (separate repo) | `homebrew-tap/README.md` | Tap documentation |

---

## 14. Recommended Implementation Order

### Phase 1: Product identity and release prerequisites

1. Finalize app name, bundle ID, bundle filename, and cask token
2. Add real app icon assets
3. Decide minimum supported macOS version
4. Clean up logger subsystem/bundle ID consistency
5. Remove production `print(...)`
6. Add hardened runtime and privacy manifest to Xcode project

### Phase 2: CI hardening

1. Make SwiftLint blocking
2. Upload `.xcresult` as artifact
3. Add concurrency control
4. Remove redundant Release build

### Phase 3: Release automation

1. Implement tag-based Developer ID release workflow
2. Implement notarization
3. Implement DMG + ZIP creation
4. Implement GitHub Release creation with checksums
5. Implement Homebrew tap auto-update

### Phase 4: Trust and launch polish

1. Document privacy posture
2. Add verification instructions
3. Create release notes/changelog process
4. Perform clean-machine install tests

---

## 15. Official References

### GitHub

- [Encrypted secrets](https://docs.github.com/en/actions/configuring-and-managing-workflows/creating-and-storing-encrypted-secrets)
- [Build provenance attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations-to-establish-provenance-for-builds)

### Apple

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Distributing outside the Mac App Store](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)

### Homebrew

- [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
- [How to create and maintain a tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)

---

## 16. Repository Evidence References

These repository files were the main inputs for this plan:

- [README.md](README.md)
- [.github/workflows/ci.yml](.github/workflows/ci.yml)
- [photo-export.xcodeproj/project.pbxproj](photo-export.xcodeproj/project.pbxproj)
- [photo-export/photo_export.entitlements](photo-export/photo_export.entitlements)
- [photo-export/Assets.xcassets/AppIcon.appiconset/Contents.json](photo-export/Assets.xcassets/AppIcon.appiconset/Contents.json)
- [PUBLIC_DEPLOYMENT_PLAN.md](PUBLIC_DEPLOYMENT_PLAN.md)
