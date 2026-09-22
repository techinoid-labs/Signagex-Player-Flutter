#!/bin/bash
#
# Builds an AppImage from an already-built Linux release bundle.
#
#   make_appimage.sh <version> <output .AppImage> [name suffix]
#
# Why both this and a .deb:
#
#   The .deb is the right thing on the Ubuntu machines the fleet actually
#   runs -- it installs, gets a launcher entry and an icon, and apt resolves
#   its dependencies.
#
#   The AppImage is the one that works when none of that is true: a single
#   executable file, no root, no package manager, no dependency resolution,
#   on whatever distribution a customer turns out to be running. Chmod +x and
#   run it. For a screen in the field that somebody has to get working over a
#   phone call, that matters more than tidy integration.
#
# Needs appimagetool on PATH or in the working directory. CI fetches it; see
# build-linux.yml.

set -euo pipefail

VERSION="${1:?usage: make_appimage.sh <version> <output .AppImage> [suffix]}"
OUTPUT="${2:?usage: make_appimage.sh <version> <output .AppImage> [suffix]}"
SUFFIX="${3:-}"

BUNDLE="build/linux/x64/release/bundle"
BIN="signagex-player"
NAME="SignageX Player${SUFFIX:+ ($SUFFIX)}"

if [ ! -x "$BUNDLE/$BIN" ]; then
  echo "error: $BUNDLE/$BIN not found -- run 'flutter build linux --release' first." >&2
  exit 1
fi

APPDIR="$(mktemp -d)/SignageX.AppDir"
trap 'rm -rf "$(dirname "$APPDIR")"' EXIT

mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications"
cp -R "$BUNDLE/." "$APPDIR/usr/bin/"

# AppImage looks for these three at the AppDir root.
desktop="$APPDIR/ai.signagex.player.desktop"
sed -e "s|^Name=SignageX Player$|Name=$NAME|" \
    linux/packaging/ai.signagex.player.desktop > "$desktop"
cp "$desktop" "$APPDIR/usr/share/applications/"

cp linux/packaging/icons/signagex-player-256.png "$APPDIR/signagex-player.png"
mkdir -p "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp linux/packaging/icons/signagex-player-256.png \
   "$APPDIR/usr/share/icons/hicolor/256x256/apps/signagex-player.png"

# AppRun rather than a symlink to the binary: the Flutter runner finds its
# lib/ and data/ relative to /proc/self/exe, and it must also be told where
# the bundled shared libraries are, since there is no system package here to
# have installed them.
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/bin/lib:${LD_LIBRARY_PATH:-}"
exec "$HERE/usr/bin/signagex-player" "$@"
APPRUN
chmod 755 "$APPDIR/AppRun"

mkdir -p "$(dirname "$OUTPUT")"

# --appimage-extract-and-run because CI runners have no FUSE, which
# appimagetool otherwise requires to mount itself.
APPIMAGETOOL="${APPIMAGETOOL:-appimagetool}"
ARCH=x86_64 "$APPIMAGETOOL" --appimage-extract-and-run "$APPDIR" "$OUTPUT"

chmod +x "$OUTPUT"
echo "Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
