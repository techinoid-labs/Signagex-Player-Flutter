#!/bin/bash
# Pin the mdk video SDK that the fvp plugin bundles. Left alone, fvp downloads
# SourceForge's *nightly* SDK on every build, so two builds of the same commit
# can ship different video libraries (v51 shipped a broken RUNPATH that way).
# This places a checksummed GitHub release where fvp looks first; fvp then
# extracts it instead of downloading. Run after `flutter pub get`.
# Usage: linux/packaging/pin_mdk_sdk.sh x64|arm64
set -euo pipefail
MDK_VERSION=v0.39.0
case "${1:?usage: pin_mdk_sdk.sh x64|arm64}" in
  x64)   package=mdk-sdk-linux-x64.tar.xz; sha256=0394c7443060f29bb420aa0ec8b278ec5ef61d3e84d1d3877c41c967c614980a ;;
  arm64) package=mdk-sdk-linux.tar.xz;     sha256=8a66c5ab23a5e357511e01ff9d369a68dce6470076303136a619bbe120518479 ;;
  *) echo "unknown architecture: $1" >&2; exit 1 ;;
esac

# The fvp package fvp's CMake runs from (its linux/ directory in the pub cache).
plugin=$(python3 - <<'EOF'
import json, pathlib, urllib.parse
config = pathlib.Path('.dart_tool/package_config.json')
for package in json.loads(config.read_text())['packages']:
    if package['name'] == 'fvp':
        root = urllib.parse.urlparse(package['rootUri'])
        path = pathlib.Path(urllib.parse.unquote(root.path)) if root.scheme == 'file' else (config.parent / root.path).resolve()
        print(path / 'linux')
        break
EOF
)
[ -d "$plugin" ] || { echo "fvp plugin directory not found (run flutter pub get first)" >&2; exit 1; }

# A cached pub directory may hold an SDK extracted by an earlier build.
rm -rf "$plugin/mdk-sdk" "$plugin"/mdk-sdk-linux*.tar.xz*
curl -fsSL --retry 3 -o "$plugin/$package" "https://github.com/wang-bin/mdk-sdk/releases/download/$MDK_VERSION/$package"
echo "$sha256  $plugin/$package" | sha256sum -c -
echo "Pinned mdk-sdk $MDK_VERSION ($package) for fvp at $plugin"
