#!/bin/bash
# No set -e: cleanup must not fail the workflow.
set -uo pipefail

# Cleans up temporary keychain, provisioning profile, and API key.
# Runs as an always() step — all operations are best-effort.
#
# Environment variables (all optional — missing ones are skipped):
#   KEYCHAIN_PATH
#   PROFILES_DIR
#   PROFILE_UUID
#   APP_STORE_CONNECT_API_KEY_ID

echo "=== App Store CI Cleanup ==="

if [ -n "${KEYCHAIN_PATH:-}" ] && [ -f "${KEYCHAIN_PATH}" ]; then
  echo "Deleting temporary keychain at ${KEYCHAIN_PATH}..."
  security delete-keychain "${KEYCHAIN_PATH}" || true
  echo "Keychain deleted."
else
  echo "No temporary keychain found to clean up."
fi

if [ -n "${PROFILES_DIR:-}" ] && [ -n "${PROFILE_UUID:-}" ]; then
  PROFILE_FILE="${PROFILES_DIR}/${PROFILE_UUID}.provisioningprofile"
  if [ -f "${PROFILE_FILE}" ]; then
    echo "Removing provisioning profile: ${PROFILE_FILE}"
    rm -f "${PROFILE_FILE}" || true
    echo "Profile removed."
  else
    echo "No provisioning profile found at ${PROFILE_FILE}"
  fi
else
  echo "No provisioning profile path to clean up."
fi

if [ -n "${APP_STORE_CONNECT_API_KEY_ID:-}" ]; then
  API_KEY_FILE="${HOME}/.appstoreconnect/private_keys/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
  if [ -f "${API_KEY_FILE}" ]; then
    echo "Removing API key: ${API_KEY_FILE}"
    rm -f "${API_KEY_FILE}" || true
    echo "API key removed."
  else
    echo "No API key found at ${API_KEY_FILE}"
  fi
else
  echo "No API key to clean up."
fi

echo ""
echo "=== Cleanup complete ==="
