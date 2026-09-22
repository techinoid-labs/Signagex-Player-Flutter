#!/bin/bash
#
# Builds a .deb from an already-built Linux release bundle.
#
#   make_deb.sh <version> <output .deb> [package name suffix]
#
# e.g.  make_deb.sh v137 dist/signagex-player_v137_amd64.deb
#       make_deb.sh v137 dist/signagex-player-staging_v137_amd64.deb staging
#
# Layout, which is the conventional one for a self-contained app that ships
# its own runtime libraries:
#
#   /opt/signagex-player/            the Flutter bundle, verbatim
#   /usr/bin/signagex-player         symlink to the binary above
#   /usr/share/applications/...      the launcher entry
#   /usr/share/icons/hicolor/...     the icon, at every size the themes use
#
# The symlink is safe: the Flutter runner locates its lib/ and data/ through
# /proc/self/exe, which resolves the symlink to the real path in /opt, so the
# bundle is found either way.

set -euo pipefail

VERSION="${1:?usage: make_deb.sh <version> <output .deb> [suffix]}"
OUTPUT="${2:?usage: make_deb.sh <version> <output .deb> [suffix]}"
SUFFIX="${3:-}"

BUNDLE="build/linux/x64/release/bundle"
BIN="signagex-player"
PKG="signagex-player${SUFFIX:+-$SUFFIX}"
INSTALL_DIR="/opt/$PKG"

if [ ! -x "$BUNDLE/$BIN" ]; then
  echo "error: $BUNDLE/$BIN not found -- run 'flutter build linux --release' first." >&2
  exit 1
fi

# Debian versions must start with a digit, and the build id is "v137".
DEB_VERSION="${VERSION#v}"
case "$DEB_VERSION" in
  [0-9]*) ;;
  *) DEB_VERSION="0.$DEB_VERSION" ;;
esac

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT$INSTALL_DIR" "$ROOT/usr/bin" "$ROOT/usr/share/applications" "$ROOT/DEBIAN"
cp -R "$BUNDLE/." "$ROOT$INSTALL_DIR/"
ln -s "$INSTALL_DIR/$BIN" "$ROOT/usr/bin/$PKG"

# --- launcher entry ------------------------------------------------------
desktop="$ROOT/usr/share/applications/ai.signagex.player${SUFFIX:+.$SUFFIX}.desktop"
sed -e "s|^Exec=signagex-player$|Exec=$PKG|" \
    linux/packaging/ai.signagex.player.desktop > "$desktop"
if [ -n "$SUFFIX" ]; then
  # A staging build must be distinguishable in the launcher, or someone will
  # test the wrong one and report against the wrong build.
  #
  # Icon= has to follow the package name too: the icon files are installed
  # per package, so leaving this pointing at the production name gives the
  # staging entry no icon at all unless the production package also happens
  # to be installed.
  #
  # StartupWMClass is deliberately NOT rewritten. It has to match the
  # window's actual class, which comes from APPLICATION_ID compiled into the
  # binary and is the same in both flavours; changing it here would only
  # stop the shell matching the window to this entry.
  sed -i \
    -e "s|^Name=SignageX Player$|Name=SignageX Player (Staging)|" \
    -e "s|^Icon=signagex-player$|Icon=$PKG|" \
    "$desktop"
fi

# --- icons ---------------------------------------------------------------
for png in linux/packaging/icons/signagex-player-*.png; do
  size="${png##*-}"; size="${size%.png}"
  dir="$ROOT/usr/share/icons/hicolor/${size}x${size}/apps"
  mkdir -p "$dir"
  cp "$png" "$dir/$PKG.png"
done

# --- control -------------------------------------------------------------
# Dependencies are the ones the embedded browser (webview_cef ships Chromium)
# needs beyond a bare desktop install. Alternatives are spelled out for both
# sides of Ubuntu's 64-bit time_t transition, so the same .deb installs on
# 22.04 and 24.04 rather than failing dependency resolution on one of them.
INSTALLED_KB="$(du -sk "$ROOT$INSTALL_DIR" | cut -f1)"
cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $DEB_VERSION
Section: video
Priority: optional
Architecture: amd64
Maintainer: SignageX <support@signagex.ai>
Installed-Size: $INSTALLED_KB
Depends: libgtk-3-0, libglib2.0-0, libstdc++6, libnss3, libnspr4,
 libxkbcommon0, libgbm1, libdrm2, libxcomposite1, libxdamage1, libxrandr2,
 libatk1.0-0, libatk-bridge2.0-0, libpango-1.0-0, libcairo2,
 libasound2t64 | libasound2, libcups2t64 | libcups2
Description: SignageX digital signage player
 Plays the campaigns and playlists scheduled for this screen in the SignageX
 CMS, and reports the screen's status back to it.
 .
 Diagnostics are written to
 ~/.local/share/signagex-player/signagex_debug.log, which records pairing,
 restriction decisions, campaign rotation and connection retries.
CONTROL

cat > "$ROOT/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
# Refresh the caches the shell reads, so the icon and launcher entry appear
# without a logout.
if [ -x "$(command -v gtk-update-icon-cache)" ]; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
fi
if [ -x "$(command -v update-desktop-database)" ]; then
  update-desktop-database -q /usr/share/applications 2>/dev/null || true
fi
POSTINST
chmod 755 "$ROOT/DEBIAN/postinst"

cat > "$ROOT/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ -x "$(command -v gtk-update-icon-cache)" ]; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
fi
POSTRM
chmod 755 "$ROOT/DEBIAN/postrm"

mkdir -p "$(dirname "$OUTPUT")"
# xz rather than the default: the bundle carries a full Chromium, and the
# difference is worth having on a package that gets downloaded per screen.
dpkg-deb --build -Zxz --root-owner-group "$ROOT" "$OUTPUT"

echo "Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
