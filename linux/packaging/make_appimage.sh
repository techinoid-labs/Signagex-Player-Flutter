#!/bin/bash
#
# Builds a SELF-CONTAINED AppImage from an already-built Linux release
# bundle.
#
#   make_appimage.sh <version> <output .AppImage> [name suffix]
#
# "Self-contained" is the whole point of this format here, and it is worth
# being precise about what it does and does not mean.
#
# The .deb next to this script integrates with the system: it installs into
# /opt, gets a launcher entry, and lets apt pull in the libraries the
# embedded browser needs. That is correct for the Ubuntu screens in the
# fleet, and wrong for everything else -- it needs root, a matching
# distribution, and a working package manager.
#
# This file needs none of that. Every shared library the player links
# against is copied into the AppImage, so it runs on a machine with nothing
# installed but a desktop session: chmod +x, run.
#
# What is NOT bundled, and cannot be:
#
#   * glibc. A binary links against the glibc of the machine that BUILT it
#     and runs on anything newer, never anything older. That is why the
#     workflow builds on the oldest Ubuntu still in the fleet rather than
#     the newest runner -- bundling removes the package dependencies, not
#     this one.
#
#   * The graphics driver stack (libGL, libEGL, the X11/Wayland client
#     libraries). These must match the host's kernel and driver, so
#     bundling them breaks hardware acceleration rather than helping.
#
# linuxdeploy does the collecting. Doing it by hand -- ldd, copy, patchelf,
# repeat -- gets the plain libraries right and then falls over on the parts
# that are loaded at runtime rather than linked: GTK's theme engines,
# gdk-pixbuf's image loaders, GIO's modules. A Flutter GTK app that is
# missing those starts and then renders nothing, or fails to decode any
# image, which is a far worse failure than not starting at all. The gtk
# plugin exists precisely for that.

set -euo pipefail

VERSION="${1:?usage: make_appimage.sh <version> <output .AppImage> [suffix]}"
OUTPUT="${2:?usage: make_appimage.sh <version> <output .AppImage> [suffix]}"
SUFFIX="${3:-}"

# Target architecture. Defaults to the build host; override with APPIMAGE_ARCH.
# uname -m / linuxdeploy use x86_64 / aarch64, while Flutter writes the bundle
# under x64 / arm64 -- the case below maps between the two.
APPIMAGE_ARCH="${APPIMAGE_ARCH:-$(uname -m)}"
case "$APPIMAGE_ARCH" in
  x86_64)        FLUTTER_ARCH=x64 ;;
  aarch64|arm64) APPIMAGE_ARCH=aarch64; FLUTTER_ARCH=arm64 ;;
  *) echo "error: unsupported architecture '$APPIMAGE_ARCH' (expected x86_64 or aarch64)" >&2; exit 1 ;;
esac

BUNDLE="build/linux/$FLUTTER_ARCH/release/bundle"
BIN="signagex-player"
NAME="SignageX Player${SUFFIX:+ ($SUFFIX)}"

if [ ! -x "$BUNDLE/$BIN" ]; then
  echo "error: $BUNDLE/$BIN not found -- run 'flutter build linux --release' first." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APPDIR="$WORK/SignageX.AppDir"

mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"

# The Flutter bundle goes in whole. data/ holds the compiled assets and the
# ICU data, and lib/ holds the engine plus every plugin's shared library --
# including CEF, which is most of the size.
cp -R "$BUNDLE/." "$APPDIR/usr/bin/"
# Work on the package copy, never the original CI bundle.
python3 linux/packaging/trim_browser.py "$APPDIR/usr/bin"

# xdotool is invoked at runtime, so linuxdeploy must collect it explicitly.
command -v xdotool >/dev/null || { echo "error: install xdotool before packaging" >&2; exit 1; }
cp "$(command -v xdotool)" "$APPDIR/usr/bin/xdotool"
command -v scrot >/dev/null || { echo "error: install scrot before packaging" >&2; exit 1; }
cp "$(command -v scrot)" "$APPDIR/usr/bin/scrot"
cp -R linux/packaging/kiosk "$APPDIR/usr/bin/kiosk"
cp linux/packaging/49-signagex-reboot.rules "$APPDIR/usr/bin/kiosk/"

desktop="$APPDIR/usr/share/applications/ai.signagex.player.desktop"
sed -e "s|^Name=SignageX Player$|Name=$NAME|" \
    linux/packaging/ai.signagex.player.desktop > "$desktop"
cp linux/packaging/icons/signagex-player-256.png \
   "$APPDIR/usr/share/icons/hicolor/256x256/apps/signagex-player.png"

# AppRun rather than a symlink to the binary. The Flutter runner finds its
# data/ and lib/ relative to /proc/self/exe, and both the bundle's own
# libraries and the ones linuxdeploy collects have to be on the search path.
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
export PATH="$HERE/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HERE/usr/bin/lib:$HERE/usr/lib:${LD_LIBRARY_PATH:-}"
export IMLIB2_LOADER_PATH="$HERE/usr/lib/imlib2/loaders"
# Set by linuxdeploy's gtk plugin hook when it is present; harmless if not.
for hook in "$HERE"/apprun-hooks/*.sh; do
  [ -r "$hook" ] && . "$hook"
done
exec "$HERE/usr/bin/signagex-player" "$@"
APPRUN
chmod 755 "$APPDIR/AppRun"

LINUXDEPLOY="${LINUXDEPLOY:-linuxdeploy}"

if ! command -v "$LINUXDEPLOY" >/dev/null 2>&1 && [ ! -x "$LINUXDEPLOY" ]; then
  echo "error: linuxdeploy not found. Set LINUXDEPLOY to it, or put it on PATH." >&2
  echo "       CI fetches it; see .github/workflows/build-linux.yml." >&2
  exit 1
fi

# Every .so in the bundle is passed explicitly. linuxdeploy follows the
# executable's own dependencies on its own, but the plugins' libraries are
# dlopen'd by the engine rather than linked into it, so nothing would walk
# their dependencies otherwise -- and CEF's are the ones that matter most.
lib_args=()
# scrot's writers are also loaded dynamically by Imlib2. Remote view uses JPEG.
mkdir -p "$APPDIR/usr/lib/imlib2/loaders"
for format in png jpeg; do
  loader="$(find /usr/lib -path "*/imlib2/loaders/$format.so" -print -quit)"
  [ -n "$loader" ] || { echo "error: missing Imlib2 $format loader" >&2; exit 1; }
  cp "$loader" "$APPDIR/usr/lib/imlib2/loaders/$format.so"
  lib_args+=(--library "$APPDIR/usr/lib/imlib2/loaders/$format.so")
done
# MDK loads these with dlopen; dependency scanning cannot discover them.
for soname in libva.so.2 libva-drm.so.2 libva-x11.so.2 libvdpau.so.1; do
  library="$(ldconfig -p | awk -v name="$soname" '$1 == name && !found { print $NF; found = 1 }')"
  [ -n "$library" ] || { echo "error: missing runtime library $soname" >&2; exit 1; }
  lib_args+=(--library "$library")
done
while IFS= read -r -d '' so; do
  lib_args+=(--library "$so")
done < <(find "$APPDIR/usr/bin/lib" -name '*.so*' -type f -print0 2>/dev/null)

echo "Collecting dependencies for ${#lib_args[@]} bundled libraries..."

# Keep linuxdeploy from stripping further. trim_browser.py removes debug
# sections only and verifies all allocated sections; runtime symbols stay intact.
export NO_STRIP=1
export OUTPUT="$OUTPUT"
export VERSION="$VERSION"

ARCH="$APPIMAGE_ARCH" "$LINUXDEPLOY" \
  --appdir "$APPDIR" \
  --executable "$APPDIR/usr/bin/$BIN" \
  --executable "$APPDIR/usr/bin/xdotool" \
  --executable "$APPDIR/usr/bin/scrot" \
  --desktop-file "$desktop" \
  --icon-file "$APPDIR/usr/share/icons/hicolor/256x256/apps/signagex-player.png" \
  "${lib_args[@]}" \
  ${LINUXDEPLOY_PLUGINS:+--plugin gtk} \
  --output appimage

chmod +x "$OUTPUT"
echo "Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
echo "Bundled libraries:"
find "$APPDIR/usr/lib" -maxdepth 1 -name '*.so*' -printf '  %f\n' 2>/dev/null | sort | head -40
