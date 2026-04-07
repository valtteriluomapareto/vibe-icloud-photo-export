#!/bin/bash
set -euo pipefail

# Finds the exported .pkg and renames it for the workflow artifact.
#
# Required environment variables:
#   RUNNER_TEMP
#   EXPORT_PATH
#   VERSION
#   BUILD_NUMBER

echo "=== Prepare App Store Package ==="

for var in RUNNER_TEMP EXPORT_PATH VERSION BUILD_NUMBER; do
  if [ -z "${!var:-}" ]; then
    echo "::error::Required environment variable ${var} is not set"
    exit 1
  fi
done

echo "Looking for .pkg in: ${EXPORT_PATH}"
PKG_FOUND=$(find "${EXPORT_PATH}" -name "*.pkg" -maxdepth 1)

if [ -z "${PKG_FOUND}" ]; then
  echo "::error::No .pkg found in export output"
  echo ""
  echo "Export directory contents:"
  ls -la "${EXPORT_PATH}/"
  exit 1
fi

echo "Found package: ${PKG_FOUND}"
echo "Package size: $(du -sh "${PKG_FOUND}" | cut -f1)"

PKG_NAME="PhotoExport-AppStore-${VERSION}-b${BUILD_NUMBER}.pkg"
PKG_PATH="${RUNNER_TEMP}/${PKG_NAME}"

echo "Renaming to: ${PKG_NAME}"
mv "${PKG_FOUND}" "${PKG_PATH}"

echo ""
echo "Final package:"
echo "  Path: ${PKG_PATH}"
echo "  Name: ${PKG_NAME}"
echo "  Size: $(du -sh "${PKG_PATH}" | cut -f1)"

echo "PKG_PATH=${PKG_PATH}" >> "$GITHUB_ENV"
echo "PKG_NAME=${PKG_NAME}" >> "$GITHUB_ENV"

echo ""
echo "=== Package preparation complete ==="
