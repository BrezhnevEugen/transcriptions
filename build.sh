#!/usr/bin/env bash
set -euo pipefail

APP_NAME="VoiceTray"
BUNDLE_ID="com.brezhneveugen.voicetray"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR=".build/apple/Products"
APP_DIR="dist/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf dist
swift build -c "${CONFIGURATION}" --arch arm64

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp ".build/${CONFIGURATION}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
cp "VoiceTray/Info.plist" "${CONTENTS_DIR}/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "${CONTENTS_DIR}/Info.plist"
chmod +x "${MACOS_DIR}/${APP_NAME}"

echo "Built ${APP_DIR}"
