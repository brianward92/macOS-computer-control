#!/usr/bin/env bash
# Install Rectangle (window snapping) and set the macctl default shortcuts:
#   ctrl+shift+cmd+left   left half
#   ctrl+shift+cmd+right  right half
#
# Rectangle goes to ~/Applications so no password is needed. Set
# RECTANGLE_APPDIR=/Applications to install system-wide (Homebrew may ask for sudo).
# Rectangle needs Accessibility permission before it can move windows; only a
# person can grant it, in System Settings > Privacy & Security > Accessibility.
set -euo pipefail
APPDIR=${RECTANGLE_APPDIR:-$HOME/Applications}
DOMAIN=com.knollsoft.Rectangle

if ! open -Ra Rectangle 2>/dev/null; then
  command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh" >&2; exit 1; }
  mkdir -p "$APPDIR"
  brew install --cask rectangle --appdir="$APPDIR"
fi

# Shortcuts are stored as {keyCode, modifierFlags}. Key codes: left 123, right 124.
# Modifier flags: shift 1<<17 + ctrl 1<<18 + cmd 1<<20 = 1441792.
MODS=1441792
osascript -e 'quit app "Rectangle"' 2>/dev/null || true
defaults write "$DOMAIN" SUHasLaunchedBefore -bool true
defaults write "$DOMAIN" alternateDefaultShortcuts -bool true
defaults write "$DOMAIN" launchOnLogin -bool true
defaults write "$DOMAIN" leftHalf  -dict keyCode -float 123 modifierFlags -float "$MODS"
defaults write "$DOMAIN" rightHalf -dict keyCode -float 124 modifierFlags -float "$MODS"
open -a Rectangle 2>/dev/null || open "$APPDIR/Rectangle.app"
echo "Rectangle: ctrl+shift+cmd+left/right snap the front window to the left/right half."
echo "Scripted use: open -g 'rectangle://execute-action?name=left-half'"
echo "If the shortcuts do nothing, enable Rectangle in System Settings >"
echo "Privacy & Security > Accessibility (a person has to do this)."
