#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_NAME="Pet Usage Bubble.app"
INSTALL_DIR="${HOME}/Applications"
INSTALL_PATH="${INSTALL_DIR}/${APP_NAME}"
LABEL="io.github.error404notfound1.pet-usage-bubble"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"

"${PROJECT_DIR}/scripts/build.sh"

launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
mkdir -p "${INSTALL_DIR}" "${HOME}/Library/LaunchAgents"
/usr/bin/ditto "${PROJECT_DIR}/build/${APP_NAME}" "${INSTALL_PATH}"

plutil -create xml1 "${PLIST_PATH}"
plutil -insert Label -string "${LABEL}" "${PLIST_PATH}"
plutil -insert ProgramArguments -json "[\"${INSTALL_PATH}/Contents/MacOS/PetUsageBubble\"]" "${PLIST_PATH}"
plutil -insert RunAtLoad -bool true "${PLIST_PATH}"
plutil -insert KeepAlive -bool true "${PLIST_PATH}"
plutil -insert ProcessType -string Interactive "${PLIST_PATH}"
plutil -insert StandardOutPath -string "/tmp/${LABEL}.out.log" "${PLIST_PATH}"
plutil -insert StandardErrorPath -string "/tmp/${LABEL}.err.log" "${PLIST_PATH}"

launchctl bootstrap "${DOMAIN}" "${PLIST_PATH}"
print "Installed and started: ${INSTALL_PATH}"
print "Show your pet in ChatGPT; the usage bubble will appear above it."
