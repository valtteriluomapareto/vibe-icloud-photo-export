# Photo Export

[![CI](https://github.com/valtteriluomapareto/photo-export/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/valtteriluomapareto/photo-export/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Photo Export is a native macOS app for exporting your Apple Photos library to local or external storage in a predictable `YYYY/MM/` folder layout.

**[Download on the Mac App Store](https://apps.apple.com/app/photo-export-local-backup/id6761410742)** · [Download from GitHub (free)](https://github.com/valtteriluomapareto/photo-export/releases) · [Documentation](https://valtteriluomapareto.github.io/photo-export/)

The project is intentionally small: SwiftUI on top, system frameworks only, and a straightforward export pipeline that favors reliability over feature sprawl.

## Current Capabilities

- Browse your library by year and month
- Preview thumbnails and selected assets
- Export a month, a year, or the full queue without overwriting existing files
- Track exported assets per destination so interrupted exports can resume safely
- Pause, resume, cancel, and clear queued work
- Import an existing backup folder to rebuild local export state on a fresh install

## Requirements

- macOS 15.0+
- Xcode 16.2+ tested in CI
- No third-party runtime dependencies

Optional local tools:

- `swiftlint`
- `swift-format`
- `xcpretty`

## Build and Test

Open the project in Xcode:

```bash
open photo-export.xcodeproj
```

Or build from the command line:

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run unit tests:

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Generate coverage:

```bash
rm -rf TestResults.xcresult
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  -enableCodeCoverage YES \
  -resultBundlePath TestResults.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  test

./scripts/xccov2lcov.sh TestResults.xcresult lcov.info
```

## Documentation

- Project website: [valtteriluomapareto.github.io/photo-export](https://valtteriluomapareto.github.io/photo-export/)
- User docs: [`website/src/content/docs/`](website/src/content/docs/)
- Contributor guide: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Maintainer notes and plans: [`docs/README.md`](docs/README.md)
- Persistence store reference: [`docs/reference/persistence-store.md`](docs/reference/persistence-store.md)

## Repository Layout

- `photo-export/` app source
- `photo-exportTests/` unit tests
- `photo-exportUITests/` UI tests
- `website/` documentation website
- `docs/` maintainer-facing notes, plans, and reference material
- `scripts/` small development utilities

## Contributing

Contributions are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md) for local setup, testing expectations, and documentation ownership.

If you are changing user-visible behavior, update the relevant docs in both places:

- the root README for repo-level guidance
- `website/src/content/docs/` for user-facing documentation

## License

Photo Export is released under the MIT License. See [`LICENSE`](LICENSE).
