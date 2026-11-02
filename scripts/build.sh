#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="${PROJECT_DIR}/build"
APP_DIR="${BUILD_DIR}/Pet Usage Bubble.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

case "$(uname -m)" in
  arm64) TARGET="arm64-apple-macosx13.0" ;;
  x86_64) TARGET="x86_64-apple-macosx13.0" ;;
  *) print -u2 "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${BUILD_DIR}/swift-module-cache"

xcrun swiftc \
  -module-cache-path "${BUILD_DIR}/swift-module-cache" \
  -sdk "${SDK_PATH}" \
  -target "${TARGET}" \
  -O \
  -framework AppKit \
  -framework Foundation \
  "${PROJECT_DIR}/Sources/PetUsageBubble/main.swift" \
  -o "${MACOS_DIR}/PetUsageBubble"

cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
chmod +x "${MACOS_DIR}/PetUsageBubble"

print "Built: ${APP_DIR}"
