#!/bin/bash
set -euo pipefail

# Packages the archived .app into a signed .pkg for App Store Connect.
# Uses productbuild directly (instead of xcodebuild -exportArchive)
# so we can pass --keychain explicitly — xcodebuild -exportArchive
# spawns productbuild without --keychain, which hangs in headless CI.
#
# Required environment variables:
#   RUNNER_TEMP
#   ARCHIVE_PATH
#   KEYCHAIN_PATH
#   KEYCHAIN_PASSWORD
#   INSTALLER_SIGNING_CERTIFICATE
#   APP_NAME

echo "=== App Store Export ==="

for var in RUNNER_TEMP ARCHIVE_PATH KEYCHAIN_PATH KEYCHAIN_PASSWORD INSTALLER_SIGNING_CERTIFICATE APP_NAME; do
  if [ -z "${!var:-}" ]; then
    echo "::error::Required environment variable ${var} is not set"
    exit 1
  fi
done

EXPORT_PATH="${RUNNER_TEMP}/export-appstore"
mkdir -p "${EXPORT_PATH}"

APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"

if [ ! -d "${APP_PATH}" ]; then
  echo "::error::App not found at: ${APP_PATH}"
  echo ""
  echo "Archive contents:"
  find "${ARCHIVE_PATH}/Products" -maxdepth 3 -print
  exit 1
fi

echo "Export configuration:"
echo "  Archive:     ${ARCHIVE_PATH}"
echo "  App:         ${APP_PATH}"
echo "  Export path: ${EXPORT_PATH}"
echo "  Installer:   ${INSTALLER_SIGNING_CERTIFICATE}"
echo "  Keychain:    ${KEYCHAIN_PATH}"
echo ""

# Verify the app is signed
echo "Verifying app code signature..."
codesign --verify --deep --strict "${APP_PATH}" 2>&1
echo "App signature OK."

echo ""
echo "Unlocking keychain..."
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"

echo ""
echo "Building signed .pkg with productbuild..."
productbuild \
  --component "${APP_PATH}" /Applications \
  --sign "${INSTALLER_SIGNING_CERTIFICATE}" \
  --keychain "${KEYCHAIN_PATH}" \
  "${EXPORT_PATH}/${APP_NAME}.pkg"

echo ""
echo "Export contents:"
ls -la "${EXPORT_PATH}/"

PKG_PATH="${EXPORT_PATH}/${APP_NAME}.pkg"
echo ""
echo "Package details:"
echo "  Path: ${PKG_PATH}"
echo "  Size: $(du -sh "${PKG_PATH}" | cut -f1)"

# Verify the pkg signature
echo ""
echo "Verifying .pkg signature..."
pkgutil --check-signature "${PKG_PATH}"

echo "EXPORT_PATH=${EXPORT_PATH}" >> "$GITHUB_ENV"

echo ""
echo "=== Export complete ==="
