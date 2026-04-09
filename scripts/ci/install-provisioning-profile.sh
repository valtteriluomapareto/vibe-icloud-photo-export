#!/bin/bash
set -euo pipefail

# Installs the App Store provisioning profile where Xcode can find it.
#
# Required environment variables:
#   RUNNER_TEMP
#   APP_STORE_PROVISIONING_PROFILE_BASE64
#
# Exports via GITHUB_ENV:
#   PROFILE_UUID
#   PROFILE_NAME
#   PROFILES_DIR

echo "=== Provisioning Profile Installation ==="

for var in RUNNER_TEMP APP_STORE_PROVISIONING_PROFILE_BASE64; do
  if [ -z "${!var:-}" ]; then
    echo "::error::Required environment variable ${var} is not set"
    exit 1
  fi
done

echo "Decoding provisioning profile..."
PROFILE_PATH="${RUNNER_TEMP}/appstore.provisioningprofile"
echo "${APP_STORE_PROVISIONING_PROFILE_BASE64}" | base64 --decode > "${PROFILE_PATH}"
echo "Profile decoded to: ${PROFILE_PATH}"
echo "Profile size: $(wc -c < "${PROFILE_PATH}") bytes"

echo ""
echo "Extracting profile metadata..."
PROFILE_PLIST="$(security cms -D -i "${PROFILE_PATH}")"

PROFILE_UUID=$(/usr/libexec/PlistBuddy -c "Print UUID" /dev/stdin <<< "${PROFILE_PLIST}")
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c "Print Name" /dev/stdin <<< "${PROFILE_PLIST}")
PROFILE_TEAM=$(/usr/libexec/PlistBuddy -c "Print TeamIdentifier:0" /dev/stdin <<< "${PROFILE_PLIST}" 2>/dev/null || echo "unknown")
PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c "Print Entitlements:application-identifier" /dev/stdin <<< "${PROFILE_PLIST}" 2>/dev/null || echo "unknown")
PROFILE_EXPIRY=$(/usr/libexec/PlistBuddy -c "Print ExpirationDate" /dev/stdin <<< "${PROFILE_PLIST}" 2>/dev/null || echo "unknown")

echo ""
echo "Profile details:"
echo "  UUID:       ${PROFILE_UUID}"
echo "  Name:       ${PROFILE_NAME}"
echo "  Team:       ${PROFILE_TEAM}"
echo "  App ID:     ${PROFILE_APP_ID}"
echo "  Expires:    ${PROFILE_EXPIRY}"

if [ -n "${APPSTORE_BUNDLE_ID:-}" ]; then
  EXPECTED_SUFFIX=".${APPSTORE_BUNDLE_ID}"
  if [[ "${PROFILE_APP_ID}" != *"${EXPECTED_SUFFIX}" ]]; then
    echo "::error::Provisioning profile App ID does not match expected bundle ID."
    echo "::error::Expected suffix: ${EXPECTED_SUFFIX}"
    echo "::error::Actual App ID:  ${PROFILE_APP_ID}"
    exit 1
  fi
  echo "  Bundle ID verified for ${APPSTORE_BUNDLE_ID}."
fi

PROFILES_DIR="${HOME}/Library/MobileDevice/Provisioning Profiles"
mkdir -p "${PROFILES_DIR}"

echo ""
echo "Installing profile to: ${PROFILES_DIR}/${PROFILE_UUID}.provisioningprofile"
cp "${PROFILE_PATH}" "${PROFILES_DIR}/${PROFILE_UUID}.provisioningprofile"
rm -f "${PROFILE_PATH}"

echo ""
echo "Installed profiles:"
ls -la "${PROFILES_DIR}/"

# Export for later steps
echo "PROFILE_UUID=${PROFILE_UUID}" >> "$GITHUB_ENV"
echo "PROFILE_NAME=${PROFILE_NAME}" >> "$GITHUB_ENV"
echo "PROFILES_DIR=${PROFILES_DIR}" >> "$GITHUB_ENV"

echo ""
echo "=== Provisioning profile installation complete ==="
