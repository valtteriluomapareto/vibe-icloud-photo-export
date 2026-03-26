#!/bin/bash
# Bump MARKETING_VERSION in project.pbxproj and create a git tag.
#
# Usage:
#   scripts/bump-version.sh 1.2.0        # set version, auto-tag v1.2.0
#   scripts/bump-version.sh 1.2.0 --no-tag  # set version only

set -euo pipefail

PROJECT_FILE="photo-export.xcodeproj/project.pbxproj"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version> [--no-tag]"
  echo "Example: $0 1.2.0"
  exit 1
fi

NEW_VERSION="$1"
NO_TAG="${2:-}"

# Validate semver format
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Version must be in semver format (e.g. 1.2.0)"
  exit 1
fi

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Error: $PROJECT_FILE not found. Run from the repo root."
  exit 1
fi

# Read current version
CURRENT_VERSION=$(grep -m1 'MARKETING_VERSION' "$PROJECT_FILE" | sed 's/.*= *\(.*\);/\1/')
echo "Current version: $CURRENT_VERSION"
echo "New version:     $NEW_VERSION"

if [[ "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
  echo "Version is already $NEW_VERSION — nothing to do."
  exit 0
fi

# Replace all occurrences of MARKETING_VERSION
sed -i '' "s/MARKETING_VERSION = $CURRENT_VERSION;/MARKETING_VERSION = $NEW_VERSION;/g" "$PROJECT_FILE"

UPDATED=$(grep -c "MARKETING_VERSION = $NEW_VERSION;" "$PROJECT_FILE")
echo "Updated $UPDATED MARKETING_VERSION entries to $NEW_VERSION"

if [[ "$NO_TAG" == "--no-tag" ]]; then
  echo "Skipping tag (--no-tag)."
  echo ""
  echo "Next steps:"
  echo "  git add $PROJECT_FILE"
  echo "  git commit -m \"Bump version to $NEW_VERSION\""
  exit 0
fi

# Commit and tag
git add "$PROJECT_FILE"
git commit -m "Bump version to $NEW_VERSION"
git tag "v$NEW_VERSION"

echo ""
echo "Committed and tagged v$NEW_VERSION."
echo "Push with: git push && git push origin v$NEW_VERSION"
