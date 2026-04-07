#!/bin/bash
set -euo pipefail

# Exports the archive as a .pkg for App Store Connect distribution.
# Generates an ExportOptions.plist and runs xcodebuild -exportArchive.
#
# Required environment variables:
#   RUNNER_TEMP
#   ARCHIVE_PATH
#   APPLE_TEAM_ID
#   PROFILE_NAME
#   APPSTORE_BUNDLE_ID

echo "=== App Store Export ==="

for var in RUNNER_TEMP ARCHIVE_PATH APPLE_TEAM_ID PROFILE_NAME APPSTORE_BUNDLE_ID; do
  if [ -z "${!var:-}" ]; then
    echo "::error::Required environment variable ${var} is not set"
    exit 1
  fi
done

EXPORT_PATH="${RUNNER_TEMP}/export-appstore"

echo "Generating ExportOptions.plist..."
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

echo ""
echo "ExportOptions.plist contents:"
cat "${RUNNER_TEMP}/ExportOptions.plist"

echo ""
echo "Export configuration:"
echo "  Archive:     ${ARCHIVE_PATH}"
echo "  Export path: ${EXPORT_PATH}"
echo "  Method:      app-store-connect"
echo "  Team ID:     ${APPLE_TEAM_ID}"
echo "  Profile:     ${PROFILE_NAME}"
echo "  Bundle ID:   ${APPSTORE_BUNDLE_ID}"
echo ""

echo "Exporting archive to .pkg..."
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist "${RUNNER_TEMP}/ExportOptions.plist" \
  -exportPath "${EXPORT_PATH}"

echo ""
echo "Export contents:"
ls -la "${EXPORT_PATH}/"

echo "EXPORT_PATH=${EXPORT_PATH}" >> "$GITHUB_ENV"

echo ""
echo "=== Export complete ==="
