# Contributing to Photo Export

Photo Export is a small macOS project. Prefer focused pull requests, clear reasoning, and documentation that stays accurate after the change lands.

## Before You Start

- Search existing issues and pull requests before starting similar work.
- Open an issue or draft pull request before making a large feature or architecture change.
- Keep each pull request scoped to one concern when possible.

## Local Setup

Requirements:

- macOS 15.0+
- Xcode 16.2+

Open the project:

```bash
open photo-export.xcodeproj
```

Build from the command line:

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run tests:

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Optional tools:

- `brew install swiftlint`
- `brew install swift-format`

Docs website setup:

```bash
cd website
npm install
npm run dev
```

## Development Expectations

- Keep SwiftUI views thin. Move side effects and business logic into managers or view models.
- Avoid adding runtime dependencies unless there is a clear project-level reason.
- Add or update tests for bug fixes and behavior changes where practical.
- Use `os.Logger` for production logging.
- Preserve the no-overwrite export behavior and the `PHAsset.localIdentifier` tracking model.

Reference material:

- Architecture and style notes: [`docs/reference/swift-swiftui-best-practices.md`](docs/reference/swift-swiftui-best-practices.md)
- Persistence details: [`docs/reference/persistence-store.md`](docs/reference/persistence-store.md)

## Documentation Ownership

Where each kind of doc lives, and which page to update for which kind of change, is documented in [`docs/README.md`](docs/README.md). Read that before opening a PR that changes user-visible behavior — there is a "what to update when behavior changes" table.

If a change affects setup, behavior, limitations, or project structure, update the relevant docs in the same pull request.

## Pull Requests

Include the following in your pull request description:

- what changed
- why it changed
- how you tested it
- whether documentation was updated

For UI changes, include a screenshot or short recording when practical.

## Release and Project Notes

Longer-lived project notes live under [`docs/`](docs/README.md). Keep the repo root reserved for the files people expect in an open source project.
