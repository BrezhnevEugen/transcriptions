#!/usr/bin/env bash
set -euo pipefail

APP_NAME="VoiceTray"
APP_PATH="dist/${APP_NAME}.app"
ZIP_PATH="dist/${APP_NAME}.zip"
ENTITLEMENTS="VoiceTray/VoiceTray.entitlements"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Missing ${APP_PATH}. Run ./build.sh first." >&2
  exit 1
fi

if [[ -z "${IDENTITY}" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'\"' '/Developer ID Application/ {print $2; exit}')"
fi

if [[ -z "${IDENTITY}" ]]; then
  echo "No Developer ID Application identity found. Set DEVELOPER_ID_APPLICATION." >&2
  exit 2
fi

codesign --force --options runtime --timestamp --entitlements "${ENTITLEMENTS}" --sign "${IDENTITY}" "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
spctl --assess --type execute --verbose=4 "${APP_PATH}" || true

ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

if [[ -z "${NOTARY_PROFILE}" ]]; then
  NOTARY_PROFILE="$(xcrun notarytool history 2>&1 | awk '/Using keychain profile:/ {print $NF; exit}')"
fi

if [[ -z "${NOTARY_PROFILE}" ]]; then
  echo "Set NOTARY_PROFILE to a saved notarytool keychain profile." >&2
  exit 3
fi

xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${APP_PATH}"
spctl --assess --type execute --verbose=4 "${APP_PATH}"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "Signed and notarized: ${APP_PATH}"
echo "Archive: ${ZIP_PATH}"
