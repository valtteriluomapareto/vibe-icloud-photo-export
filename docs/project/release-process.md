# Release Process

How to cut a new release of Photo Export.

## Prerequisites

- Push access to the repository
- Apple Developer ID certificate and notarization secrets configured in the `direct-release` GitHub Environment

## Steps

### 1. Bump the version

```bash
scripts/bump-version.sh 1.2.0
```

This updates `MARKETING_VERSION` in `project.pbxproj` (all 6 build configs), commits, and creates a `v1.2.0` git tag.

To set the version without committing or tagging:

```bash
scripts/bump-version.sh 1.2.0 --no-tag
```

### 2. Push the tag

```bash
git push && git push origin v1.2.0
```

Pushing the `v*` tag triggers the **release-direct** workflow which:

1. Builds a universal binary (Release, arm64 + x86_64)
2. Signs with Developer ID Application certificate
3. Creates a styled DMG with drag-to-Applications installer
4. Notarizes the DMG with Apple and staples the ticket
5. Creates a **draft** GitHub Release with auto-generated notes
6. Attaches the DMG and SHA-256 checksum to the release

### 3. Review and publish

1. Go to **Releases** on GitHub
2. Review the draft release — edit the notes if needed
3. Click **Publish release**

### 4. Verify

Download the DMG on a separate machine (or fresh user account) and confirm:

- Gatekeeper accepts the app without warnings
- The app launches and core flows work
- The version in About matches the release

## Dry run

To test the workflow without creating a release:

1. Go to **Actions > release-direct** on GitHub
2. Click **Run workflow** from `main` with `dry_run: true`
3. Download the DMG artifact from the workflow run

## Rollback

- **Bad draft**: Delete the draft release and the tag, fix the issue, then re-tag
- **Bad published release**: Ship a patch version (preferred) or delete the release
