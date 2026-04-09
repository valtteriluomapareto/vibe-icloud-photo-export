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
#   INSTALLER_SIGNING_CERTIFICATE

echo "=== App Store Export ==="

for var in RUNNER_TEMP ARCHIVE_PATH APPLE_TEAM_ID PROFILE_NAME APPSTORE_BUNDLE_ID INSTALLER_SIGNING_CERTIFICATE; do
  if [ -z "${!var:-}" ]; then
    echo "::error::Required environment variable ${var} is not set"
    exit 1
  fi
done

EXPORT_PATH="${RUNNER_TEMP}/export-appstore"
EXPORT_XCODEBUILD_LOG="${RUNNER_TEMP}/export-appstore-xcodebuild.log"
EXPORT_DISTRIBUTION_LOGS_DIR="${RUNNER_TEMP}/xcdistributionlogs"
EXPORT_XCODEBUILD_TMPDIR="${RUNNER_TEMP}/export-tmp"
HEARTBEAT_PID=""

rm -f "${EXPORT_XCODEBUILD_LOG}"
rm -rf "${EXPORT_DISTRIBUTION_LOGS_DIR}"
rm -rf "${EXPORT_XCODEBUILD_TMPDIR}"
mkdir -p "${EXPORT_XCODEBUILD_TMPDIR}"

collect_distribution_logs() {
  local bundle_path=""

  if [ -f "${EXPORT_XCODEBUILD_LOG}" ]; then
    bundle_path="$(grep -oE '/[^"]+\.xcdistributionlogs' "${EXPORT_XCODEBUILD_LOG}" | tail -1 || true)"
  fi

  if [ -z "${bundle_path}" ] && [ -n "${TMPDIR:-}" ]; then
    bundle_path="$(find "${TMPDIR}" -maxdepth 1 -type d -name '*.xcdistributionlogs' -print 2>/dev/null | tail -1 || true)"
  fi

  if [ -z "${bundle_path}" ]; then
    bundle_path="$(find "${EXPORT_XCODEBUILD_TMPDIR}" -maxdepth 1 -type d -name '*.xcdistributionlogs' -print 2>/dev/null | tail -1 || true)"
  fi

  if [ -n "${bundle_path}" ] && [ -d "${bundle_path}" ]; then
    mkdir -p "${EXPORT_DISTRIBUTION_LOGS_DIR}"
    cp -R "${bundle_path}" "${EXPORT_DISTRIBUTION_LOGS_DIR}/"
    echo ""
    echo "Saved Xcode distribution logs from: ${bundle_path}"
    find "${EXPORT_DISTRIBUTION_LOGS_DIR}" -maxdepth 2 -mindepth 1 -print
  else
    echo ""
    echo "No Xcode distribution logs bundle found to save."
  fi
}

echo "XCODEBUILD_EXPORT_LOG_PATH=${EXPORT_XCODEBUILD_LOG}" >> "$GITHUB_ENV"
echo "XCDISTRIBUTION_LOGS_DIR=${EXPORT_DISTRIBUTION_LOGS_DIR}" >> "$GITHUB_ENV"
echo "XCODEBUILD_TMPDIR=${EXPORT_XCODEBUILD_TMPDIR}" >> "$GITHUB_ENV"

cleanup_export() {
  if [ -n "${HEARTBEAT_PID:-}" ]; then
    kill "${HEARTBEAT_PID}" 2>/dev/null || true
    wait "${HEARTBEAT_PID}" 2>/dev/null || true
    HEARTBEAT_PID=""
  fi

  collect_distribution_logs || true
}

trap 'cleanup_export' EXIT
trap 'exit 130' INT TERM

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
  <key>installerSigningCertificate</key>
  <string>${INSTALLER_SIGNING_CERTIFICATE}</string>
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
echo "  Installer:   ${INSTALLER_SIGNING_CERTIFICATE}"
echo "  Profile:     ${PROFILE_NAME}"
echo "  Bundle ID:   ${APPSTORE_BUNDLE_ID}"
echo "  Xcode log:   ${EXPORT_XCODEBUILD_LOG}"
echo "  Xcode tmp:   ${EXPORT_XCODEBUILD_TMPDIR}"
echo ""

echo "Verifying keychain is unlocked and accessible..."
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security show-keychain-info "${KEYCHAIN_PATH}" 2>&1 || true

echo ""
echo "Exporting archive to .pkg..."
EXPORT_TIMEOUT=600  # 10 minutes — export should not take this long
(
  ELAPSED=0
  while true; do
    sleep 60
    ELAPSED=$((ELAPSED + 60))
    echo "Export still running at $(date -u +"%Y-%m-%dT%H:%M:%SZ") (${ELAPSED}s elapsed)..."
    if [ "${ELAPSED}" -ge "${EXPORT_TIMEOUT}" ]; then
      echo "::error::Export timed out after ${EXPORT_TIMEOUT}s — likely a keychain access hang"
      # Kill the xcodebuild process group
      kill 0 2>/dev/null || true
      exit 1
    fi
  done
) &
HEARTBEAT_PID=$!

set +e
TMPDIR="${EXPORT_XCODEBUILD_TMPDIR}" xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist "${RUNNER_TEMP}/ExportOptions.plist" \
  -exportPath "${EXPORT_PATH}" \
  -verbose 2>&1 | tee "${EXPORT_XCODEBUILD_LOG}"
EXPORT_STATUS=${PIPESTATUS[0]}
set -e

if [ "${EXPORT_STATUS}" -ne 0 ]; then
  echo "::error::xcodebuild -exportArchive failed with exit code ${EXPORT_STATUS}"
  exit "${EXPORT_STATUS}"
fi

echo ""
echo "Export contents:"
ls -la "${EXPORT_PATH}/"

echo "EXPORT_PATH=${EXPORT_PATH}" >> "$GITHUB_ENV"

echo ""
echo "=== Export complete ==="
