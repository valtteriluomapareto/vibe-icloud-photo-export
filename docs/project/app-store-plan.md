# App Store Plan

Written against the repository state on 2026-03-30.

## Scope

This plan covers shipping Photo Export on the Mac App Store while keeping GitHub Releases as a parallel distribution channel. It lists every engineering change and human task needed for submission.

## Decisions

These are locked in and not open for discussion:

- **Pricing:** Free on GitHub Releases. Paid on the Mac App Store (support-the-project model). The app is fully open source.
- **Bundle identifiers:** Separate per channel. GitHub Releases keeps `com.valtteriluoma.photo-export`. App Store uses `com.valtteriluoma.photo-export-appstore`. This avoids cross-channel replacement semantics entirely — both builds can coexist on the same Mac. Each has its own sandbox container, UserDefaults, and export history.
- **First submission method:** Manual archive via `xcodebuild` from the terminal (with bundle ID and build number overrides), then upload via Xcode Organizer or Transporter. Automate after the first successful approval.
- **Auto-update:** App Store handles its own updates. No Sparkle in v1. Add Sparkle to the GitHub channel later if needed.
- **Owner:** Valtteri Luoma is the sole maintainer. AI agents handle delegatable engineering work.

## Blocking Validation

### Network entitlement necessity

Remove `com.apple.security.network.client` from `photo_export.entitlements`. Build the app. Test with a Photos library that has iCloud-only assets (optimized storage enabled, at least one asset not downloaded locally). Attempt to export an iCloud-only asset and verify the full-resolution file is retrieved.

- If the export succeeds: the Photos framework handles networking independently. Remove the entitlement permanently.
- If the export fails or hangs: the entitlement is required. Restore it and document the justification in review notes.

Testing on a machine where all photos are downloaded locally is meaningless for this validation.

## Current State

Validated against the repo:

- Direct distribution ships via [`release-direct.yml`](.github/workflows/release-direct.yml) (Developer ID signed, notarized, DMG)
- Release process documented in [`docs/project/release-process.md`](docs/project/release-process.md)
- In-app links for website, privacy, and support exist in [`AboutView.swift`](photo-export/Views/AboutView.swift)
- Website has privacy and support pages
- Sandbox and bookmark persistence bugs are fixed
- `CURRENT_PROJECT_VERSION` is hardcoded to `1` in `project.pbxproj`; `release-direct.yml` overrides it at build time with `github.run_number`
- Deployment target is macOS 15.0 (Sequoia). This limits the addressable market to Sequoia and later. This is a conscious choice — the app uses macOS 15 APIs.
- README and website show both GitHub Releases and "Coming soon" for the Mac App Store
- Support page has real contact email (valtteri.e.luoma@gmail.com)
- App icon (`appstore.png`) needs replacement — current icon uses transparency and is too small when flattened
- `REGISTER_APP_GROUPS` set to `NO`
- Release process docs cover dual-channel flow

## Entitlements Audit

Current entitlements in [`photo_export.entitlements`](photo-export/photo_export.entitlements):

| Entitlement | Value | App Store safe? |
|---|---|---|
| `com.apple.security.app-sandbox` | `true` | Yes, required |
| `com.apple.security.files.bookmarks.app-scope` | `true` | Yes |
| `com.apple.security.files.user-selected.read-write` | `true` | Yes |
| `com.apple.security.personal-information.photos-library` | `true` | Yes |
| `com.apple.security.network.client` | `true` | Yes, but see note |

All entitlements are App Store-compatible in principle. The `network.client` entitlement must be resolved via the blocking validation before submission.

The same entitlements file is used for both channels. The bundle identifier override at build time does not affect entitlements.

Project flag note: `REGISTER_APP_GROUPS` has been set to `NO`. No app groups are used.

## Privacy Manifest Audit

Current [`PrivacyInfo.xcprivacy`](photo-export/PrivacyInfo.xcprivacy):

- `NSPrivacyTracking`: false
- `NSPrivacyTrackingDomains`: empty
- `NSPrivacyCollectedDataTypes`: empty
- `NSPrivacyAccessedAPITypes`:
  - File timestamp access (`3B52.1`) — needed for export folder operations
  - UserDefaults access (`CA92.1`) — needed for app preferences

**This is complete and correct for App Store submission.** No changes needed.

## App Review Risk Assessment

Likely review issues and mitigations:

### 1. Photos permission justification

**Risk:** Rejection for requesting Photos access without clear justification in the UI or review notes.

**Mitigation:** The usage description is already good: *"Photo Export needs access to your Photos library to browse your photos and videos and export them to a folder you choose."* Include this in review notes. The app's core function requires Photos access — this is straightforward.

### 2. Open-source / free alternative available

**Risk:** Apple may question why users would pay on the App Store when the same app is free on GitHub. This is not a formal rejection reason, but reviewers occasionally flag it.

**Mitigation:** This is a legitimate distribution model. If questioned, explain: the App Store version offers convenience (automatic updates, trusted distribution), and the purchase supports ongoing development of an open-source project. Do not hide the GitHub option. Note: the App Store build's About window links to the website, which advertises both channels — App Store users can discover the free GitHub version in a couple of clicks. This is inherent to the open-source model and Apple does not require hiding free alternatives.

### 3. Missing or incomplete privacy manifest

**Risk:** Low. The privacy manifest is already complete. No third-party SDKs are included.

### 4. Network entitlement without visible network use

**Risk:** The app declares `network.client` but has no visible network UI. A reviewer running the app on a machine with all Photos stored locally would see no network activity.

**Mitigation:** Either remove the entitlement if it's not needed, or explain in review notes that network access is used by the Photos framework to download iCloud originals when needed.

### 5. App name rejection

**Risk:** "Photo Export" is generic and describes a system-level function (Photos.app has an export feature). Apple sometimes rejects overly generic names.

**Mitigation:** Have a backup name ready before submission. If rejected, rename in App Store Connect only — the bundle display name and repo can stay as "Photo Export" since the App Store name doesn't have to match `CFBundleDisplayName`.

### 6. Sandbox file access

**Risk:** Low. The app uses user-selected folders with security-scoped bookmarks. This is the standard App Store pattern.

## Distribution Model

Two public channels for the same app:

| | Mac App Store | GitHub Releases |
|---|---|---|
| Price | Paid | Free |
| Signing | Apple Distribution | Developer ID |
| Updates | App Store managed | Manual (Sparkle later) |
| Bundle ID | `com.valtteriluoma.photo-export-appstore` | `com.valtteriluoma.photo-export` |

One product name, one semver, one repo, one changelog. The channels differ in signing, distribution, pricing, and bundle identifier.

### Side-by-side installation

Both builds can coexist on the same Mac. Each has its own sandbox container, so there is no shared app state — no shared export history, no shared bookmarks.

Both builds produce `Photo Export.app` on disk. If both are in `/Applications`, Finder may show the second as `Photo Export 2.app` or similar. macOS distinguishes apps by bundle ID (Spotlight, Launchpad, Dock all work correctly), so this is cosmetic — not broken, just slightly inelegant. Most users will only have one channel installed.

If both builds are pointed at the same export folder, they operate on the same files independently. Without running "Import Existing Backup" in the second build, it has no knowledge of what the first build exported and will create duplicates. This is the expected behavior for any fresh install pointed at an existing export folder — the export folder is shared user data, not app state.

### Channel switching

If a user wants to move from GitHub Releases to the App Store (or vice versa):

1. Install the new channel's build (the old one can stay or be deleted)
2. In the new build, select the same export folder
3. Run "Import Existing Backup" — this scans the destination folder, matches exported files to Photos assets by filename and metadata, and rebuilds export records in the new build's database so future exports skip already-exported assets

Without step 3, the new build treats the destination as fresh and will create suffixed duplicates (e.g., `photo (1).jpg`) via `ExportManager.swift:uniqueFileURL`. This is the same behavior as any fresh install pointing at an existing export folder — it's not specific to channel switching.

Two potential future improvements (both out of scope for the App Store launch):

- Detect when the selected export folder already contains exported files but no matching export history, and prompt the user to run "Import Existing Backup" before exporting
- Derive `destinationId` from something stable (e.g., the folder's filesystem ID) instead of the bookmark blob hash, so re-selecting the same folder finds existing export history

## Versioning

- `MARKETING_VERSION` (`CFBundleShortVersionString`): human-visible semver, e.g. `1.1.0`. The canonical version. Same across both channels. Managed by `scripts/bump-version.sh`.
- `CURRENT_PROJECT_VERSION` (`CFBundleVersion`): rolling integer build number. Set at build time by each channel's CI workflow. **Build numbers are independent per channel and do not need to match.**

Build number strategy per channel:

| | App Store | GitHub Releases |
|---|---|---|
| Source | Query App Store Connect API for latest build number, add 1 | `github.run_number` (auto-incrementing integer managed by GitHub Actions) |
| Set by | `release-app-store.yml` (or manually for first submission) | `release-direct.yml` |
| Constraint | Must be higher than the last upload to App Store Connect | No constraint — `run_number` is always increasing |

The value of `CURRENT_PROJECT_VERSION` in `project.pbxproj` stays at `1` as a checked-in default. `release-direct.yml` already overrides it at build time via `xcodebuild CURRENT_PROJECT_VERSION=${{ github.run_number }}`. The future `release-app-store.yml` will do the same with a build number from App Store Connect. Do not commit build-number changes to `project.pbxproj`.

For the manual first App Store submission, archive from the terminal (not the Xcode GUI — the GUI doesn't support build-time overrides):

```bash
xcodebuild archive \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Release \
  -archivePath ~/Desktop/PhotoExport-AppStore.xcarchive \
  CURRENT_PROJECT_VERSION=2 \
  PRODUCT_BUNDLE_IDENTIFIER=com.valtteriluoma.photo-export-appstore \
  CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=Apple Distribution" \
  DEVELOPMENT_TEAM=<your-team-id>
```

Then open the `.xcarchive` in Xcode Organizer (double-click or Window > Organizer) and use "Distribute App" > "App Store Connect" to upload. Alternatively, export from the command line and upload via Transporter.

This avoids mutating `project.pbxproj` for a one-time operation. The tagged commit stays clean.

## Release Sequence

For each release:

1. Bump `MARKETING_VERSION` (via `scripts/bump-version.sh`)
2. Tag the commit
3. The tag triggers `release-direct.yml` → GitHub Release (automated, build number = `github.run_number`)
4. The tag triggers `release-app-store.yml` → App Store upload (automated, build number = previous App Store build + 1, bundle ID overridden to `com.valtteriluoma.photo-export-appstore`)
5. Submit for App Review (manual)
6. Release manually after approval

Before App Store CI is set up, steps 4-6 are done manually via `xcodebuild` archive with build number and bundle ID overrides, then upload via Organizer/Transporter.

The first App Store submission will use whatever `MARKETING_VERSION` is current at the time. There is no requirement to start at `1.0.0` on the App Store — submitting `1.0.2` or `1.1.0` is fine.

GitHub Releases may go live before the App Store if App Review is slow. The website should reflect actual availability, not assumed availability.

### If App Review rejects after tagging

The tag push triggers `release-direct.yml`, which creates a **draft** GitHub Release (not published). This gives flexibility when App Review rejects:

**If the rejection is metadata/policy only (no code change needed):**

1. Keep the draft GitHub Release and the existing tag
2. Fix the App Store metadata in App Store Connect
3. Resubmit the same build, or upload a new build from the same commit with a higher build number
4. Publish the draft GitHub Release whenever ready (it's independent of App Review)

**If the rejection requires a code change:**

1. Delete the draft GitHub Release and the tag
2. Fix the issue on `main`
3. Re-run `bump-version.sh` with the same semver (the version wasn't published, so it's not burned)
4. Tag the new commit
5. A new draft GitHub Release is created from the new tag
6. Submit the new build to App Store Connect

If the draft was already published before the rejection came back, the semver is burned — bump to a new semver instead and leave the published release as-is.

The release workflow should check for any existing GitHub Release (draft or published) for the tag before starting the build. `gh release create --draft` will fail if a release already exists for that tag — the early check avoids wasting a full build cycle before discovering the collision.

### If a live App Store release has a critical bug

1. Remove the build from sale in App Store Connect immediately (App Store Connect > Pricing and Availability, or remove the version)
2. Fix the bug, bump semver, tag, and submit a new build
3. Request expedited App Review if the bug is severe
4. On the GitHub side: same process, new tag creates a new release automatically

The GitHub Release can be published within minutes. The App Store fix is gated by review latency (typically 24-48h, faster with expedited review).

## Repo Changes Required

### 1. Build number and bundle ID automation — DONE (partial)

`release-direct.yml` now overrides `CURRENT_PROJECT_VERSION` with `github.run_number` at build time. It also checks for existing GitHub Releases before building.

Still TODO: Add `release-app-store.yml` with App Store Connect API build number query and `PRODUCT_BUNDLE_IDENTIFIER` override (post-first-submission).

No changes to `bump-version.sh` — it only manages `MARKETING_VERSION`. No changes to the checked-in `PRODUCT_BUNDLE_IDENTIFIER` in `project.pbxproj` — the App Store bundle ID is a build-time override only.

### 2. Register App Store bundle ID

Register `com.valtteriluoma.photo-export-appstore` in the Apple Developer portal under Certificates, Identifiers & Profiles. This is required before creating the App Store provisioning profile or the app record in App Store Connect.

### 3. Clean up REGISTER_APP_GROUPS — DONE

`REGISTER_APP_GROUPS` set to `NO` in both Debug and Release build configurations.

### 4. Apply network entitlement decision

After completing the blocking validation for `network.client`, either remove the entitlement or keep it with documented justification in review notes.

### 5. Website and README — DONE

All files updated to present both download channels. Mac App Store shown as "Coming soon" with no dead links. Structured data `offers` converted to an array with the free GitHub offer; a TODO comment marks where to add the App Store offer and `downloadUrl` once the listing is live.

Updated files: `README.md`, `Hero.astro`, `index.astro`, `getting-started.md`, `export-icloud-photos.md`, `MarketingLayout.astro`, `support.astro`.

### 6. Support page — DONE

Contact email (valtteri.e.luoma@gmail.com) added to the support page.

### 7. Channel-specific docs — DONE

Added "Updates and distribution channels" section to `getting-started.md` covering update mechanisms, side-by-side installation, and the channel-switching migration path via Import Existing Backup.

### 8. Release process docs — DONE

`docs/project/release-process.md` rewritten to cover dual-channel flow: build numbers, manual App Store submission, App Review rejection handling, and critical bug rollback.

## App Store Connect Setup

All of this is done by Valtteri in App Store Connect:

### App record

- App name: Photo Export
- Bundle ID: `com.valtteriluoma.photo-export-appstore`
- SKU: `photo-export-appstore`
- Primary language: English
- Category: Photography
- Copyright: Copyright © 2026 Valtteri Luoma
- Support URL: the live support page URL
- Marketing URL: the website URL
- Privacy policy URL: the live privacy page URL

### Export compliance

The app imports `CryptoKit` (in `ExportDestinationManager.swift` for destination ID hashing). Apple requires an export compliance declaration for any use of encryption.

CryptoKit hashing (SHA-256 for destination IDs) qualifies for the encryption exemption — it is not used for data encryption, secure communication, or IP protection. In App Store Connect:

- Answer "Yes" to "Does your app use encryption?"
- Answer "Yes" to "Does your app qualify for any of the exemptions provided in Category 5, Part 2 of the U.S. Export Administration Regulations?"
- Select the exemption for apps that use encryption only for authentication, digital signing, or hashing

The exact questionnaire wording may change. Verify against the current App Store Connect UI at submission time.

Do not replace CryptoKit with a non-cryptographic hash to avoid the compliance question — changing the hash algorithm would change all existing `destinationId` values and orphan every user's export history. The exemption is straightforward.

### Age rating

Complete the age-rating questionnaire in App Store Connect. For this app:

- No violence, gambling, horror, profanity, drugs, alcohol, sexual content, or mature themes
- No unrestricted web access
- No user-generated content

Expected rating: 4+ (all ages).

### Pricing

- Paid (choose price tier)
- All territories
- Manual release after approval — this allows verifying both channels are live and the website is updated before the App Store version goes public

### App Privacy questionnaire

Based on the current app behavior:

- The app does not collect any data
- The app does not use analytics or diagnostics
- The app does not track users

Select "Data Not Collected" for all categories.

### App icon — TODO

The current `appstore.png` relies on transparency for its shape and is too small when flattened. A new icon is needed that:

- Fills the entire 1024x1024 square with opaque content (no alpha channel)
- Has design elements large enough to be visible at dock sizes (48px)
- Uses the full bleed area — macOS applies the rounded-rect mask automatically

See [Apple HIG — App Icons](https://developer.apple.com/design/human-interface-guidelines/app-icons) for design guidance.

### Product page

Prepare:

- Description (what the app does, why it exists)
- Keywords
- Release notes for v1.x
- Screenshots in accepted Mac sizes (16:10 ratio)

### Review notes

Include:

- Photos permission is required for core functionality — the app exports photos from the Apple Photos library
- File access is limited to user-selected folders via the standard macOS folder picker
- The app is local-first with no server component
- Network access, if the entitlement is kept, is used by Apple's Photos framework to download iCloud originals
- Support and privacy links are in the About window
- The app is open source and also available free on GitHub — the App Store version is a paid convenience/support option

### Review contact

- Name: Valtteri Luoma
- Email: (fill in)
- Phone: (fill in)

## Testing Checklist

Run on an App Store-signed build (via TestFlight or local archive with Apple Distribution signing, using the `com.valtteriluoma.photo-export-appstore` bundle ID):

- [ ] First launch and Photos permission flow
- [ ] Choose export destination via folder picker
- [ ] Quit and relaunch — destination persists without re-selecting
- [ ] Export a single month
- [ ] Export a full year
- [ ] Import existing backup
- [ ] External drive export
- [ ] iCloud-only asset download during export
- [ ] About window links (website, privacy, support)
- [ ] App does not steer App Store users to GitHub for updates or downloads (About window linking to the project/website is acceptable — see risk assessment item 2)
- [ ] Website correctly shows both channels
- [ ] Both builds can be installed simultaneously — separate sandbox containers, no shared state, Spotlight/Launchpad/Dock distinguish them correctly

## Automation (Post-First-Release)

After the first manual submission succeeds, add `.github/workflows/release-app-store.yml`:

- Trigger: tag push or manual dispatch
- Verify `MARKETING_VERSION` matches tag
- Query App Store Connect API for the latest build number for this app version
- Set `CURRENT_PROJECT_VERSION` to latest + 1 (override at build time via `xcodebuild` flag)
- Set `PRODUCT_BUNDLE_IDENTIFIER=com.valtteriluoma.photo-export-appstore` at build time
- Archive with `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY=Apple Distribution`, and the App Store provisioning profile (different from the Developer ID identity/profile used in `release-direct.yml`)
- Export the archive with method `app-store-connect` (not `developer-id` as in the direct workflow)
- Upload to App Store Connect via the App Store Connect API or Transporter (note: `xcrun altool` is deprecated for uploads; `xcrun notarytool` is its replacement for notarization only, not for App Store uploads)
- Use a GitHub Actions concurrency group to prevent parallel runs from colliding on build numbers
- Do not auto-submit to App Review

Also update `release-direct.yml` to set `CURRENT_PROJECT_VERSION=${{ github.run_number }}` at build time.

Secrets needed in GitHub environment:

- App Store Connect API key (p8 file, base64-encoded)
- API key issuer ID
- API key ID
- Apple team ID
- Apple Distribution certificate and provisioning profile

## Execution Checklist

Ordered by dependency. Items within a group can be done in parallel.

### Blocking validation (Valtteri — do this first)

- [x] Validate `network.client` entitlement necessity with iCloud-only assets — **Result: not needed.** iCloud-only asset export works without the entitlement. Entitlement removed.

### Engineering (AI-delegatable)

- [ ] Replace `appstore.png` with a new icon (full-bleed, no alpha, elements sized for dock visibility)
- [x] Update `release-direct.yml` to set `CURRENT_PROJECT_VERSION` from `github.run_number` and check for existing GitHub Releases (draft or published) before building
- [x] Set `REGISTER_APP_GROUPS = NO`
- [x] Apply `network.client` decision — removed; not needed for iCloud-only asset export
- [x] Update README with dual-channel download options
- [x] Update website (Hero, index, getting-started, export-icloud-photos, MarketingLayout, support) with both channels
- [x] Add real contact info to support page
- [x] Add channel-specific update/migration docs
- [x] Update release process docs for dual-channel flow

### App Store Connect (Valtteri only)

- [ ] Register `com.valtteriluoma.photo-export-appstore` bundle ID in Apple Developer portal
- [ ] Create an App Store provisioning profile for the new bundle ID
- [ ] Verify Apple Developer account is in good standing and agreements are accepted
- [ ] Create app record
- [ ] Complete App Information (including support URL, privacy policy URL, marketing URL)
- [ ] Complete export compliance declaration
- [ ] Complete age rating questionnaire
- [ ] Complete App Privacy questionnaire
- [ ] Set pricing
- [ ] Prepare and upload screenshots
- [ ] Write description and keywords
- [ ] Write review notes and fill review contact

### First Submission (Valtteri only)

- [ ] Archive App Store build via `xcodebuild` from terminal (with `PRODUCT_BUNDLE_IDENTIFIER`, `CURRENT_PROJECT_VERSION`, and signing overrides — see Versioning section for the full command)
- [ ] Upload via Xcode Organizer or Transporter
- [ ] Run through TestFlight (internal testing only — no external testers, no beta review needed)
- [ ] Run the full testing checklist on the TestFlight build
- [ ] Submit for App Review
- [ ] Release manually after approval
- [ ] Update website with live App Store link

## Definition of Done

The app is App Store-ready when:

- [x] Blocking validation passed (`network.client` removed — not needed)
- [x] Entitlements finalized for App Store
- [ ] App icon alpha stripped at submission time (source keeps alpha for dock icon)
- [ ] Privacy manifest is complete (done — see audit above)
- [ ] Export compliance declaration completed in App Store Connect
- [ ] Age rating questionnaire completed
- [ ] `com.valtteriluoma.photo-export-appstore` bundle ID registered and provisioned
- [x] `CURRENT_PROJECT_VERSION` set at build time in `release-direct.yml` (and `release-app-store.yml` when it exists)
- [x] Support page has real contact information
- [x] Website and README show both channels
- [ ] At least one App Store-signed build passes the testing checklist
- [ ] App Store Connect metadata is complete (description, screenshots, privacy, pricing, review notes)
- [ ] First submission has been uploaded and is pending or approved
