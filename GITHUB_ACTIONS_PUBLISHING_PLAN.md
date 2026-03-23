# GitHub Actions Publishing Plan For Photo Export

## Status

This document is a plan only. Nothing described here is implemented.

Written against the repository state on 2026-03-23.

---

## 1. Release Model

- **GitHub Releases** — notarized DMG and ZIP, directly downloadable.
- **Homebrew** — owned tap (`valtteriluomapareto/homebrew-tap`), installs from the GitHub Release DMG.
- **In-app update check** — the app checks GitHub Releases API on launch, prompts the user when a newer version exists.
- **No App Store, TestFlight, or Sparkle** in phase 1. Can be added later without changing this pipeline.

User install paths:

```bash
brew tap valtteriluomapareto/tap
brew install --cask photo-export
# Or:
brew install --cask valtteriluomapareto/tap/photo-export
```

> **Doc deliverable → Homebrew Instructions (README):** Homebrew install/upgrade commands, direct download link, and minimum macOS version.

---

## 2. Decisions Needed Before Implementation

These must be resolved before any workflow code is written.

### 2.0 Apple Developer Program enrollment

Everything — signing, notarization, Developer ID — requires an active Apple Developer Program membership ($99/year, 24-48h approval). This is the absolute first blocker.

### 2.1 Final app identity

Decide all of these together:

| Decision | Current value | Issue |
|----------|---------------|-------|
| App display name | `photo-export` (from `$(TARGET_NAME)`) | No human-friendly name |
| Bundle identifier | `valtteriluoma.photo-export` | Not reverse-DNS; inconsistent with logger subsystem `com.valtteriluoma.photo-export` |
| App bundle filename | `photo-export.app` | May want `Photo Export.app` |
| GitHub Release artifact basename | (none) | Needs deciding |
| Homebrew cask token | (none) | Needs deciding |
| Short description | (none) | For Homebrew and GitHub |

**Recommendation:** Standardize bundle ID to `com.valtteriluoma.photo-export`. Align logger subsystems (already use this), project settings (currently missing `com.` prefix), display name, and cask token.

### 2.2 App icon

The icon catalog has only `Contents.json` — no actual images. **Hard blocker** for public release.

### 2.3 Minimum macOS version

Currently targets `15.4` (released March 2025). Questions:
1. Is 15.4 required by actual APIs used?
2. Would `15.0` (Sequoia) be viable?

**Recommendation:** Lower to `15.0` unless a specific 15.4 API is needed.

### 2.4 Privacy and trust posture

The app handles private photo libraries. Decide and document before launch:
1. Does the app send anything over the network? (Currently: only the update check described in this plan)
2. Analytics, crash reporting, telemetry? (Currently: no)
3. Is exported EXIF/location metadata preserved or modified?

> **Doc deliverable → README / Release Notes:** If the answer is "no telemetry, no account, local-only processing except version check," state that plainly and prominently.

### 2.5 Items that can be deferred

| Item | Notes |
|------|-------|
| Sparkle auto-updates | Unnecessary — in-app update check + Homebrew cover this |
| App Store / TestFlight | Separate workflow, orthogonal to this pipeline |
| Fancy DMG layout | Cosmetic; first release uses plain `hdiutil` |
| Provenance attestation | Add via `actions/attest-build-provenance` later |
| Submit to `homebrew/cask` | Requires established user base; start with personal tap |
| GPG-signed tags | Optional verification enhancement |

---

## 3. Release-Readiness Gaps (Code Changes)

These are code-level fixes needed before the first release, independent of workflow implementation.

1. **Bundle ID inconsistency:** Project uses `valtteriluoma.photo-export`, loggers use `com.valtteriluoma.photo-export`. Align after deciding Section 2.1.
2. **Production `print()` calls:** `PhotoLibraryManager.swift` still uses `print(...)`. Replace with `os.Logger`.
3. **`MARKETING_VERSION` is two-component:** Currently `1.0`. Update to `1.0.0` for semver consistency.
4. **Network entitlement missing:** The update checker (Section 7) requires adding `com.apple.security.network.client` to entitlements.

---

## 4. CI Workflow (`ci.yml` — improved)

Triggers: `pull_request`, `push` to `main`.

### Changes from current CI

| Change | Why |
|--------|-----|
| Remove `\|\| true` from SwiftLint | Make it a real gate |
| Remove `\|\| true` from swift-format | Either fix violations and enforce, or remove the step entirely. A permanently-allowed-to-fail step teaches you to ignore CI. |
| Pin Xcode version path (e.g., `/Applications/Xcode_16.2.app`) | The cascading `if [ -d ... ]` silently picks a different Xcode when the runner image updates |
| Add concurrency control | Cancel outdated runs on the same PR |
| Keep the Release build step (build only, no signing) | Catches optimizer bugs, `#if DEBUG` guards, and stripping issues. Removing it is a regression. |
| Upload `.xcresult` as artifact | Failure diagnosis |
| Cache or pin lint tool binaries | `brew install` adds 1-3 min per run on $0.08/min macOS runners |
| Set `HOMEBREW_NO_AUTO_UPDATE=1` if still using Homebrew | `brew update` removal alone doesn't disable auto-update |

### Design

```yaml
concurrency:
  group: ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
```

Steps:
1. Checkout
2. Select Xcode — hardcode `/Applications/Xcode_16.2.app`
3. Install lint tools (pinned binaries preferred; Homebrew with `HOMEBREW_NO_AUTO_UPDATE=1` acceptable)
4. SwiftLint `--strict` (blocking)
5. swift-format lint (blocking)
6. Build Debug with `CODE_SIGNING_ALLOWED=NO`
7. Run unit tests with coverage, output `.xcresult`
8. Build Release with `CODE_SIGNING_ALLOWED=NO` (build only, no tests)
9. Convert coverage to lcov, upload `.xcresult` and `lcov.info` as artifacts

> **Doc deliverable → Development Guide:** How CI works, how to read `.xcresult` artifacts, how to run the same checks locally.

---

## 5. Release Workflow (`release.yml` — new)

### Triggers

```yaml
on:
  push:
    tags: ['v*']
  workflow_dispatch:
    inputs:
      version:
        description: Semver without leading v (dry-run only)
        required: true
```

`workflow_dispatch` builds/signs/notarizes and uploads workflow artifacts, but does **not** publish a GitHub Release or update the tap. Must be launched from `main`.

### Concurrency

```yaml
concurrency:
  group: release
  cancel-in-progress: false
```

Prevents two tag pushes from racing each other. `cancel-in-progress: false` lets the first one finish.

### Permissions

```yaml
permissions:
  contents: write
```

### Environment

Use a protected GitHub Environment `release` with required reviewers. Store signing/notarization secrets there, not as repository-wide secrets.

### Workflow constants

```yaml
env:
  APP_DISPLAY_NAME: "__SET_BEFORE_FIRST_RELEASE__"
  ARTIFACT_BASENAME: "__SET_BEFORE_FIRST_RELEASE__"
  APP_BUNDLE_ID: "__SET_BEFORE_FIRST_RELEASE__"
  APP_SHORT_DESCRIPTION: "__SET_BEFORE_FIRST_RELEASE__"
  REPO_SLUG: "__SET_BEFORE_FIRST_RELEASE__"
  HOMEBREW_TAP_REPO: "__SET_BEFORE_FIRST_RELEASE__"
  HOMEBREW_CASK_TOKEN: "__SET_BEFORE_FIRST_RELEASE__"
  HOMEBREW_MACOS_FLOOR: "__SET_BEFORE_FIRST_RELEASE__"
  KEYCHAIN_PATH: "${{ runner.temp }}/build.keychain-db"
```

### Step: Pre-flight validation

Checks **every** env-block placeholder, not just the ones used in the build steps. A placeholder leaking into the tap update or release notes is just as bad as one in the archive step.

```yaml
- name: Pre-flight validation
  run: |
    FAILED=0
    for var in APP_DISPLAY_NAME ARTIFACT_BASENAME APP_BUNDLE_ID APP_SHORT_DESCRIPTION \
               REPO_SLUG HOMEBREW_TAP_REPO HOMEBREW_CASK_TOKEN HOMEBREW_MACOS_FLOOR; do
      val="$(eval echo \$$var)"
      if [ "$val" = "__SET_BEFORE_FIRST_RELEASE__" ]; then
        echo "::error::$var has not been configured"
        FAILED=1
      fi
    done
    [ "$FAILED" -eq 0 ] || exit 1
```

### Step: Resolve version

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
      echo "::error::Invalid version: $VERSION" >&2
      exit 1
    fi

    echo "version=$VERSION" >> "$GITHUB_OUTPUT"
```

### Step: Source gate

The tagged commit must be the **current tip** of `main`, not merely reachable from it. `merge-base --is-ancestor` is too weak — it accepts any old commit on `main`, which allows accidental stale releases. If you need to release an older commit, make it the tip of `main` first (cherry-pick or revert forward).

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0

- name: Verify release source is tip of main
  run: |
    MAIN_TIP="$(git rev-parse origin/main)"
    if [ "$GITHUB_SHA" != "$MAIN_TIP" ]; then
      echo "::error::Release commit $GITHUB_SHA is not the tip of main ($MAIN_TIP)"
      exit 1
    fi
```

Full history (`fetch-depth: 0`) is required so `origin/main` resolves correctly.

### Step: Import signing certificate

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

    security list-keychains -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | tr -d '"')

    rm "$RUNNER_TEMP/certificate.p12"
```

The `list-keychains` call is required — without it `codesign` won't find the imported identity because the temp keychain isn't in the search path.

### Step: Store notarization credentials

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

### Step: Archive

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
      ONLY_ACTIVE_ARCH=NO \
      ARCHS="arm64 x86_64" \
      OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN_PATH --timestamp --options runtime"
```

`ARCHS="arm64 x86_64"` produces a universal binary. GitHub's `macos-15` runners are Apple Silicon — without this, the build is arm64-only.

Build number uses `github.run_number`: monotonically increasing per-workflow, stable across re-runs, maps to the Actions UI.

### Step: Export

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

### Step: Discover exported app

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

### Step: Notarize and staple

```yaml
- name: Notarize app
  run: |
    ditto -c -k --sequesterRsrc --keepParent \
      "${{ steps.app.outputs.app_path }}" \
      "$RUNNER_TEMP/photo-export-notarize.zip"

    xcrun notarytool submit "$RUNNER_TEMP/photo-export-notarize.zip" \
      --keychain-profile "ci-notary" \
      --keychain "$KEYCHAIN_PATH" \
      --wait --timeout 30m

    xcrun stapler staple "${{ steps.app.outputs.app_path }}"
```

If notarization fails with a server-side error, re-run the workflow — `github.run_number` stays the same for re-runs.

### Step: Create DMG, notarize DMG

```yaml
- name: Create DMG
  run: |
    STAGING_DIR="$RUNNER_TEMP/dmg-root"
    mkdir -p "$STAGING_DIR"

    cp -R "${{ steps.app.outputs.app_path }}" "$STAGING_DIR/"
    ln -s /Applications "$STAGING_DIR/Applications"

    hdiutil create \
      -volname "$APP_DISPLAY_NAME" \
      -srcfolder "$STAGING_DIR" \
      -ov -format UDZO \
      "${{ steps.artifacts.outputs.dmg_path }}"

    xcrun notarytool submit "${{ steps.artifacts.outputs.dmg_path }}" \
      --keychain-profile "ci-notary" \
      --keychain "$KEYCHAIN_PATH" \
      --wait --timeout 30m

    xcrun stapler staple "${{ steps.artifacts.outputs.dmg_path }}"
```

### Step: Create ZIP

```yaml
- name: Create ZIP
  run: |
    ditto -c -k --sequesterRsrc --keepParent \
      "${{ steps.app.outputs.app_path }}" \
      "${{ steps.artifacts.outputs.zip_path }}"
```

### Step: Checksums and upload

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

- name: Upload release artifacts
  uses: actions/upload-artifact@v4
  with:
    name: release-${{ steps.version.outputs.version }}
    path: |
      ${{ steps.artifacts.outputs.dmg_path }}
      ${{ steps.artifacts.outputs.zip_path }}
```

Workflow artifact upload happens on **every** run (including dry-runs). It's the only safe dry-run output.

### Step: Create GitHub Release (tag push only)

Publishes as **draft**. The release workflow deliberately does **not** update the Homebrew tap. Draft release assets are not publicly downloadable — if the tap were updated here, `brew install` would be broken until manual promotion. The tap update happens in the separate `promote-release.yml` workflow (Section 5B) after verification and promotion.

```yaml
- name: Create GitHub Release (draft)
  if: github.event_name == 'push'
  uses: softprops/action-gh-release@v2
  with:
    tag_name: ${{ github.ref_name }}
    name: ${{ env.APP_DISPLAY_NAME }} ${{ steps.version.outputs.version }}
    draft: true
    prerelease: false
    body: |
      ## Downloads
      - **DMG** (recommended): `${{ steps.artifacts.outputs.dmg_name }}` — SHA256: `${{ steps.checksums.outputs.dmg_sha256 }}`
      - **ZIP**: `${{ steps.artifacts.outputs.zip_name }}` — SHA256: `${{ steps.checksums.outputs.zip_sha256 }}`
    files: |
      ${{ steps.artifacts.outputs.dmg_path }}
      ${{ steps.artifacts.outputs.zip_path }}
```

### Step: Cleanup

```yaml
- name: Cleanup
  if: always()
  run: security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
```

> **Doc deliverable → Release Guide:** How to publish a release, how to dry-run, how to promote a draft release, how to roll back (see Section 6), which secrets are needed, how to generate them, which Apple-side steps happen outside GitHub, how versioning and build numbering work.

---

## 5B. Promote Release Workflow (`promote-release.yml` — new)

This workflow exists because draft release assets are not publicly downloadable. The Homebrew cask URL points at `releases/download/v.../...` which only resolves for public releases. Updating the tap before promotion breaks `brew install`.

The release lifecycle is:

1. `release.yml` builds, signs, notarizes, creates a **draft** GitHub Release.
2. Maintainer verifies on a clean machine (download DMG, Gatekeeper check, `lipo -info`, launch app).
3. Maintainer runs `promote-release.yml` which promotes the draft and updates the tap.

### Trigger

```yaml
on:
  workflow_dispatch:
    inputs:
      tag:
        description: 'Tag to promote (e.g., v1.0.0)'
        required: true
```

### Permissions

```yaml
permissions:
  contents: write
```

### Workflow constants

Same `env:` block as `release.yml` (same placeholder values, same pre-flight validation).

### Steps

```yaml
- name: Pre-flight validation
  run: |
    FAILED=0
    for var in APP_DISPLAY_NAME ARTIFACT_BASENAME APP_BUNDLE_ID APP_SHORT_DESCRIPTION \
               REPO_SLUG HOMEBREW_TAP_REPO HOMEBREW_CASK_TOKEN HOMEBREW_MACOS_FLOOR; do
      val="$(eval echo \$$var)"
      if [ "$val" = "__SET_BEFORE_FIRST_RELEASE__" ]; then
        echo "::error::$var has not been configured"
        FAILED=1
      fi
    done
    [ "$FAILED" -eq 0 ] || exit 1

- name: Validate tag input
  id: version
  run: |
    TAG="${{ inputs.tag }}"
    VERSION="${TAG#v}"
    if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
      echo "::error::Invalid tag: $TAG" && exit 1
    fi
    echo "version=$VERSION" >> "$GITHUB_OUTPUT"
    echo "tag=$TAG" >> "$GITHUB_OUTPUT"

- name: Verify draft release exists with assets
  env:
    GH_TOKEN: ${{ github.token }}
  run: |
    RELEASE_JSON="$(gh release view "${{ inputs.tag }}" --json isDraft,assets)"
    IS_DRAFT="$(echo "$RELEASE_JSON" | jq -r '.isDraft')"
    ASSET_COUNT="$(echo "$RELEASE_JSON" | jq '.assets | length')"

    if [ "$IS_DRAFT" != "true" ]; then
      echo "::error::Release ${{ inputs.tag }} is not a draft — already promoted?"
      exit 1
    fi
    if [ "$ASSET_COUNT" -eq 0 ]; then
      echo "::error::Release ${{ inputs.tag }} has no assets attached"
      exit 1
    fi

- name: Promote draft to public
  env:
    GH_TOKEN: ${{ github.token }}
  run: gh release edit "${{ inputs.tag }}" --draft=false

- name: Compute DMG checksum from public release
  id: checksums
  env:
    GH_TOKEN: ${{ github.token }}
  run: |
    VERSION="${{ steps.version.outputs.version }}"
    DMG_NAME="${ARTIFACT_BASENAME}-${VERSION}.dmg"

    # Download the DMG from the now-public release to verify it's actually downloadable
    gh release download "${{ inputs.tag }}" --pattern "$DMG_NAME" --dir "$RUNNER_TEMP"

    DMG_SHA256="$(shasum -a 256 "$RUNNER_TEMP/$DMG_NAME" | awk '{print $1}')"
    echo "dmg_sha256=$DMG_SHA256" >> "$GITHUB_OUTPUT"
    echo "dmg_name=$DMG_NAME" >> "$GITHUB_OUTPUT"
```

### Step: Update Homebrew tap (with validation)

```yaml
- name: Check Homebrew tap token
  id: tap_check
  env:
    HAS_TAP_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN != '' }}
  run: echo "enabled=$HAS_TAP_TOKEN" >> "$GITHUB_OUTPUT"

- name: Update Homebrew Cask
  if: steps.tap_check.outputs.enabled == 'true'
  env:
    GH_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
  run: |
    VERSION="${{ steps.version.outputs.version }}"
    DMG_NAME="${{ steps.checksums.outputs.dmg_name }}"
    DMG_SHA256="${{ steps.checksums.outputs.dmg_sha256 }}"

    git clone "https://x-access-token:${GH_TOKEN}@github.com/${HOMEBREW_TAP_REPO}.git" \
      "$RUNNER_TEMP/homebrew-tap"

    # Discover app bundle name from release notes or use the configured display name.
    # The release workflow recorded this in the draft — here we use the env constant.
    APP_BUNDLE_NAME="${APP_DISPLAY_NAME}.app"

    cat > "$RUNNER_TEMP/homebrew-tap/Casks/${HOMEBREW_CASK_TOKEN}.rb" <<RUBY
    cask "${HOMEBREW_CASK_TOKEN}" do
      version "${VERSION}"
      sha256 "${DMG_SHA256}"

      url "https://github.com/${REPO_SLUG}/releases/download/v#{version}/${DMG_NAME}"
      name "${APP_DISPLAY_NAME}"
      desc "${APP_SHORT_DESCRIPTION}"
      homepage "https://github.com/${REPO_SLUG}"

      depends_on macos: ">= :${HOMEBREW_MACOS_FLOOR}"

      app "${APP_BUNDLE_NAME}"

      zap trash: [
        "~/Library/Preferences/${APP_BUNDLE_ID}.plist",
        "~/Library/Application Support/${APP_BUNDLE_ID}",
      ]
    end
    RUBY

    # Validate the cask before committing. This catches bad Ruby syntax,
    # invalid floor values, and missing required fields.
    brew tap --force "${HOMEBREW_TAP_REPO}" "$RUNNER_TEMP/homebrew-tap"
    brew audit --cask "${HOMEBREW_CASK_TOKEN}"

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

- name: Append Homebrew instructions to release notes
  if: steps.tap_check.outputs.enabled == 'true'
  env:
    GH_TOKEN: ${{ github.token }}
  run: |
    CURRENT_BODY="$(gh release view "${{ inputs.tag }}" --json body -q '.body')"
    BREW_SECTION="$(cat <<EOF

    ## Install via Homebrew
    \`\`\`bash
    brew install --cask ${HOMEBREW_TAP_REPO%%/*}/tap/${HOMEBREW_CASK_TOKEN}
    \`\`\`
    EOF
    )"
    gh release edit "${{ inputs.tag }}" --notes "${CURRENT_BODY}${BREW_SECTION}"
```

The key ordering guarantee: the DMG is downloaded from the **public** release URL before the cask is written. If the download fails, the cask is never updated. `brew audit --cask` validates the Ruby syntax and metadata before the commit is pushed.

---

## 6. Rollback Procedures

### Bad build discovered before promotion

The release is still a draft. No public-facing state has changed. Simply:
1. Delete the draft release on GitHub.
2. Delete the tag: `git push --delete origin v1.2.3 && git tag -d v1.2.3`
3. Fix, re-tag, re-run `release.yml`.

The Homebrew tap is untouched because `promote-release.yml` hasn't run.

### Bad release discovered after promotion but before tap update

The release is public but Homebrew hasn't moved yet (promotion and tap update are separate steps in `promote-release.yml`, or the maintainer may have promoted manually before running the workflow).

1. Revert the GitHub Release to draft: `gh release edit v1.2.3 --draft`
2. Investigate, fix, tag a new patch version.

### Bad release discovered after promotion and tap update

Both GitHub Release and Homebrew are public.

1. Revert the GitHub Release to draft: `gh release edit v1.2.3 --draft`
2. Revert the tap commit: `cd homebrew-tap && git revert HEAD && git push`
3. Investigate, fix, tag a new patch version.

The notarization ticket is permanent — you can't un-notarize. But reverting the release to draft removes the download link, and reverting the tap makes `brew install` return to the previous version.

### Key principle

The two-workflow model (`release.yml` → verify → `promote-release.yml`) means most rollback scenarios are prevented, not recovered from. Don't promote until you've verified on a clean machine.

> **Doc deliverable → Release Guide:** Rollback procedures for each failure scenario.

---

## 7. In-App Update Checker

The app should check for newer versions via the GitHub Releases API and prompt the user to update. This avoids the complexity of Sparkle while still giving users a clear upgrade path.

### Requirements

1. **Network entitlement** — add `com.apple.security.network.client` to `photo_export.entitlements`.
2. **No third-party dependencies** — use `URLSession` (system framework). Consistent with the project's "system frameworks only" constraint.
3. **Privacy-respecting** — the only network call is to the public GitHub API. No telemetry, no tracking. Document this.

### Architecture

New `UpdateCheckManager` (`@MainActor`, `ObservableObject`):

- On app launch (and optionally on a user-triggered "Check for Updates" action), fetch `https://api.github.com/repos/{REPO_SLUG}/releases/latest`.
- Parse the `tag_name` field (e.g., `v1.2.3`), compare against the app's current `MARKETING_VERSION` from `Bundle.main`.
- If a newer version exists, publish state that drives a UI prompt.
- Respect rate limits (GitHub API allows 60 unauthenticated requests/hour — one check per launch is fine).
- Don't check on every window focus or timer — once per launch is sufficient.
- Cache the dismissal: if the user dismisses a specific version's prompt, don't re-show it until a newer version exists. Use `UserDefaults` for this.

### UI

- Non-intrusive banner or alert: "Version X.Y.Z is available."
- Two actions: "Update" (opens the GitHub Release page or suggests `brew upgrade`), "Later" (dismisses for this version).
- Accessible via menu bar: "Check for Updates..." under the app menu.

### Version comparison

Compare semver components numerically (`1.9.0 < 1.10.0`). Don't use string comparison.

### Build-time configuration

The `REPO_SLUG` (e.g., `valtteriluomapareto/photo-export`) should be injected at build time via an `Info.plist` key or a generated Swift constant, so the update URL isn't hardcoded in source.

### What this does NOT do

- It doesn't download or install the update. The user updates via Homebrew (`brew upgrade`) or by downloading the DMG from the release page.
- It doesn't phone home. The GitHub API request is the only network call, it's to a public endpoint, and it contains no user data.

> **Doc deliverable → README:** Mention that the app checks for updates via the public GitHub Releases API. No other network calls are made.

---

## 8. Prerequisites (Manual, Outside GitHub)

### 8.1 Apple Developer Program

1. Enroll at https://developer.apple.com/programs/ ($99/year, 24-48h approval).
2. Create a **Developer ID Application** certificate in Certificates, Identifiers & Profiles.
3. Export the certificate + private key as `.p12` from Keychain Access (select both cert and key, export, set password).
4. Create an app-specific password at https://appleid.apple.com/account/manage (label: "GitHub Actions Notarization").
5. Find Team ID: `security find-identity -v -p codesigning` — 10-char alphanumeric in parentheses.

### 8.2 GitHub Secrets

Store in Settings > Environments > `release` > Secrets:

| Secret | Value | How to generate |
|--------|-------|-----------------|
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Base64 `.p12` | `base64 -i certificate.p12 \| pbcopy` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | `.p12` export password | Set during Keychain export |
| `APPLE_ID` | Apple ID email | — |
| `APPLE_ID_PASSWORD` | App-specific password | appleid.apple.com (**not** your account password) |
| `APPLE_TEAM_ID` | 10-char Team ID | From `security find-identity` |
| `KEYCHAIN_PASSWORD` | Random string | `openssl rand -base64 24` |
| `HOMEBREW_TAP_TOKEN` | GitHub PAT with `repo` scope for tap repo | Optional; only needed for tap auto-update |

> **Doc deliverable → Release Guide:** Full secret generation instructions, including Apple-side steps. Note that app-specific passwords can expire and need manual renewal.

### 8.3 Homebrew Tap Repository

Create `valtteriluomapareto/homebrew-tap`:

```
homebrew-tap/
  Casks/
    <cask-token>.rb
  README.md
```

> **Doc deliverable → Homebrew Tap README:** What the tap is, how to use it, link back to main repo.

---

## 9. Xcode Project Changes

Apply before first release. The release workflow also injects these via xcodebuild overrides, but applying them in the project keeps local Release builds consistent with CI.

| Change | Setting | Notes |
|--------|---------|-------|
| Hardened Runtime (Release) | `ENABLE_HARDENED_RUNTIME = YES` | Required for notarization |
| App category | `INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.photography"` | Both configs |
| Network entitlement | `com.apple.security.network.client` | Required for update checker |
| Marketing version | `MARKETING_VERSION = 1.0.0` | Three-component semver |
| Signing | Keep `Automatic` | CI overrides to Manual; no project change needed |

**Privacy manifest:** Don't add a stub `PrivacyInfo.xcprivacy`. Apple enforces privacy manifests for App Store, not Developer ID. If added later, populate it accurately (this codebase uses `UserDefaults`, which requires a real `NSPrivacyAccessedAPITypes` entry).

---

## 10. Implementation Order

### Phase 0: Enrollment (blocks everything)

1. Complete Apple Developer Program enrollment.

### Phase 1: Product identity and code cleanup

1. Finalize app name, bundle ID, bundle filename, artifact basename, cask token, short description, minimum macOS floor.
2. Add real app icon assets.
3. Align bundle ID and logger subsystems.
4. Replace `print()` with `os.Logger` in `PhotoLibraryManager.swift`.
5. Update `MARKETING_VERSION` from `1.0` to `1.0.0`.
6. Add hardened runtime and app category to Xcode project.
7. Add network entitlement.

### Phase 2: CI hardening

1. Pin Xcode version path.
2. Make SwiftLint and swift-format blocking.
3. Pin or cache lint tool binaries.
4. Add concurrency control.
5. Upload `.xcresult` as artifact.

### Phase 3: In-app update checker

1. Implement `UpdateCheckManager` using GitHub Releases API.
2. Add update prompt UI (banner/alert + "Check for Updates" menu item).
3. Add version comparison logic.
4. Inject `REPO_SLUG` via build-time configuration.
5. Test with a mock release to verify the flow.

### Phase 4: Release automation

1. Implement `release.yml`: tag-based build, sign, notarize, DMG/ZIP, draft GitHub Release.
2. Implement `promote-release.yml`: promote draft, download DMG to verify URL, `brew audit --cask`, push tap, append Homebrew instructions to release notes.
3. Dry-run `release.yml` from `main` via `workflow_dispatch` — verify artifacts upload, no release published.
4. Test full cycle: push a `v0.0.1-rc.1` tag, verify draft, run `promote-release.yml`, verify `brew install` works end to end.

### Phase 5: Launch

1. Document privacy posture in README.
2. Write verification instructions for end users.
3. Tag `v1.0.0`, run `release.yml`.
4. Verify on clean Mac: download DMG from draft, Gatekeeper check, `lipo -info`, launch app.
5. Run `promote-release.yml` to make release public and update tap.
6. Verify Homebrew: `brew install --cask valtteriluomapareto/tap/photo-export`
7. Write release notes.

---

## 11. First Release Checklist

1. [ ] Complete Apple Developer enrollment
2. [ ] Generate Developer ID Application certificate, export as `.p12`
3. [ ] Create app-specific password for notarization
4. [ ] Create protected GitHub `release` environment with required reviewers
5. [ ] Set all required secrets
6. [ ] Resolve all identity decisions (Section 2.1), update placeholder `env:` values in **both** `release.yml` and `promote-release.yml`
7. [ ] Add real app icon assets
8. [ ] Apply all Xcode project changes (Section 9)
9. [ ] Fix all code-level gaps (Section 3)
10. [ ] Implement update checker (Section 7)
11. [ ] Create `valtteriluomapareto/homebrew-tap` repo
12. [ ] Merge CI improvements, `release.yml`, and `promote-release.yml` to `main`
13. [ ] Run `release.yml` `workflow_dispatch` dry run — verify artifacts upload, no release published
14. [ ] Tag `v1.0.0`, push tag
15. [ ] Monitor `release.yml` Actions run — verify draft release created with DMG and ZIP attached
16. [ ] Download DMG from the draft release on a clean Mac — verify Gatekeeper passes
17. [ ] Verify architecture: `lipo -info` (expect `arm64 x86_64`)
18. [ ] Run `promote-release.yml` with tag `v1.0.0` — verify it promotes draft, downloads DMG, passes `brew audit`, updates tap
19. [ ] Verify release is now public on GitHub with Homebrew instructions appended
20. [ ] Verify Homebrew: `brew install --cask valtteriluomapareto/tap/photo-export`
21. [ ] Verify update checker: launch older build, confirm it detects the new version

---

## 12. Documentation Deliverables

These documents should be created as part of implementation, not after.

| Document | Location | Contents |
|----------|----------|----------|
| **Release Guide** | `docs/RELEASING.md` or wiki | How to publish a release (tag → `release.yml` → verify → `promote-release.yml`), dry-run procedure, rollback procedures for each phase, secret generation, Apple prerequisites, versioning scheme |
| **Development Guide** | `docs/CONTRIBUTING.md` or `CLAUDE.md` update | How CI works, how to read `.xcresult` artifacts, local build/test/lint commands, signing stays Automatic locally |
| **README updates** | `README.md` | Installation (Homebrew + direct download), minimum macOS version, privacy posture ("no telemetry, local-only except version check"), how to verify the binary |
| **Homebrew Tap README** | `homebrew-tap/README.md` | What the tap is, install/upgrade commands, link to main repo |

---

## 13. Files to Create or Modify

| Action | File | Purpose |
|--------|------|---------|
| **Modify** | `.github/workflows/ci.yml` | Concurrency, lint strictness, pinned Xcode, artifact upload |
| **Create** | `.github/workflows/release.yml` | Build, sign, notarize, draft GitHub Release |
| **Create** | `.github/workflows/promote-release.yml` | Promote draft, validate and update Homebrew tap |
| **Modify** | `photo-export.xcodeproj/project.pbxproj` | Hardened runtime, app category, version, bundle ID |
| **Modify** | `photo-export/photo_export.entitlements` | Add network client entitlement |
| **Create** | `photo-export/Managers/UpdateCheckManager.swift` | GitHub Releases API update checker |
| **Modify** | `photo-export/photo_exportApp.swift` | Inject `UpdateCheckManager` |
| **Create** | UI for update prompt | Banner/alert + menu item |
| **Modify** | Logger subsystems (6 files) | Align with final bundle ID |
| **Modify** | `PhotoLibraryManager.swift` | Replace `print()` with `os.Logger` |
| **Create** (separate repo) | `homebrew-tap/Casks/<cask-token>.rb` | Homebrew cask formula |
| **Create** | `docs/RELEASING.md` | Release guide |
