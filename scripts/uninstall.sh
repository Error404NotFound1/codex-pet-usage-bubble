#!/bin/zsh
set -euo pipefail

LABEL="io.github.error404notfound1.pet-usage-bubble"
DOMAIN="gui/$(id -u)"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
INSTALL_PATH="${HOME}/Applications/Pet Usage Bubble.app"

launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true

if [[ -e "${PLIST_PATH}" ]]; then
  mv "${PLIST_PATH}" "${HOME}/.Trash/${LABEL}.plist"
fi

if [[ -e "${INSTALL_PATH}" ]]; then
  mv "${INSTALL_PATH}" "${HOME}/.Trash/Pet Usage Bubble.app"
fi

print "Uninstalled. The app and LaunchAgent were moved to Trash."
