#!/bin/bash
#
# Wraps the built .app in a drag-to-install disk image.
#
#   make_dmg.sh <app name> <output .dmg> [volume suffix]
#
# e.g.  make_dmg.sh "SignageX Player" dist/SignageX-Player.dmg
#       make_dmg.sh "SignageX Player" dist/SignageX-Player-Staging.dmg Staging
#
# Deliberately plain hdiutil rather than create-dmg or a packaged installer:
#
#   * hdiutil ships with macOS, so this works on any runner and on any
#     developer's machine with nothing to install first. create-dmg would add
#     a Homebrew dependency to the release path for a prettier window.
#
#   * A .pkg installer would need an Installer-signing certificate to be
#     anything other than a scarier version of the same Gatekeeper prompt,
#     and there is no Apple Developer account on this project yet.
#
# The Applications symlink is what makes the window a drag-to-install: the
# user drags the app onto the alias and macOS copies it in.

set -euo pipefail

APP_NAME="${1:?usage: make_dmg.sh <app name> <output .dmg> [volume suffix]}"
OUTPUT="${2:?usage: make_dmg.sh <app name> <output .dmg> [volume suffix]}"
SUFFIX="${3:-}"

APP_PATH="build/macos/Build/Products/Release/${APP_NAME}.app"
VOLNAME="${APP_NAME}${SUFFIX:+ $SUFFIX}"

if [ ! -d "$APP_PATH" ]; then
  echo "error: ${APP_PATH} not found -- run 'flutter build macos --release' first." >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# A README in the image, because an unsigned app's first launch is not
# obvious and the Gatekeeper message ("can't be opened because Apple cannot
# check it for malicious software") does not tell the user what to do. Until
# there is a Developer ID certificate to sign and notarise with, the
# right-click route is the whole answer and it belongs where the user is.
cat > "$STAGE/Read me first.txt" <<'README'
Installing SignageX Player
==========================

1. Drag "SignageX Player" onto the Applications folder in this window.

2. The FIRST time you open it, do NOT double-click. macOS blocks apps that
   are not signed with an Apple Developer ID, and double-clicking only shows
   an error with no way past it.

   Instead: open Applications, right-click (or Control-click) "SignageX
   Player", choose Open, then click Open in the dialog.

   You only have to do this once. Afterwards it opens normally, including
   from a Login Item.

   The equivalent from Terminal, if you prefer:

       xattr -dr com.apple.quarantine "/Applications/SignageX Player.app"

3. To have a screen start the player automatically, add it in
   System Settings -> General -> Login Items.

Diagnostics
-----------

The player writes a log to:

    ~/Library/Containers/ai.signagex.player/Data/Library/Application Support/signagex_debug.log

Send that file if a screen misbehaves -- it records pairing, restriction
decisions, campaign rotation and connection retries.
README

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"

hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$OUTPUT"

echo "Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
