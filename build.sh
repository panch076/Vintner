#!/bin/bash
# Builds Vintner.app (x86_64) into ./dist.
#
#   ./build.sh                  lean app; downloads the Wine runtime (~200 MB) on first launch
#   ./build.sh --embed-runtime  also bundles Wine, DXVK and winetricks for fully offline installs
#   ./build.sh --universal      x86_64 + arm64 slices (the Wine runtime itself is always x86_64)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
BUILD="$(date +%Y%m%d%H%M)"
EMBED=0
ARCHS=(--arch x86_64)
for arg in "$@"; do
  case "$arg" in
    --embed-runtime) EMBED=1 ;;
    --universal) ARCHS=(--arch x86_64 --arch arm64) ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP="dist/Vintner.app"
CONTENTS="$APP/Contents"

echo "==> Compiling (release, ${ARCHS[*]})"
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Vintner"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/bin"
cp "$BIN" "$CONTENTS/MacOS/Vintner"
strip -x "$CONTENTS/MacOS/Vintner"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "==> Rendering icon"
  swift Scripts/make-icon.swift
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

# cabextract (needed by many winetricks verbs). Built from source if the vendored copy is missing.
if [ ! -x Vendor/cabextract ]; then
  echo "==> Building cabextract 1.11"
  TMP="$(mktemp -d)"
  curl -fsSL https://www.cabextract.org.uk/cabextract-1.11.tar.gz -o "$TMP/cab.tgz"
  echo "b5546db1155e4c718ff3d4b278573604f30dd64c3c5bfd4657cd089b823a3ac6  $TMP/cab.tgz" | shasum -a 256 -c -
  tar xzf "$TMP/cab.tgz" -C "$TMP"
  (cd "$TMP/cabextract-1.11" && ./configure --disable-dependency-tracking \
     CFLAGS="-O2 -arch x86_64 -arch arm64 -mmacosx-version-min=10.15" \
     LDFLAGS="-arch x86_64 -arch arm64 -mmacosx-version-min=10.15" >/dev/null && make -j"$(sysctl -n hw.ncpu)" >/dev/null)
  mkdir -p Vendor && cp "$TMP/cabextract-1.11/cabextract" Vendor/cabextract
  rm -rf "$TMP"
fi
cp Vendor/cabextract "$CONTENTS/Resources/bin/cabextract"
# Tiny Direct3D 11 test programs used by `Vintner --selftest` (source: Vendor/d3dprobe/d3dprobe.c)
mkdir -p "$CONTENTS/Resources/probe"
cp Vendor/d3dprobe/probe64.exe Vendor/d3dprobe/probe32.exe "$CONTENTS/Resources/probe/"

if [ "$EMBED" = 1 ]; then
  echo "==> Embedding runtime payload"
  mkdir -p "$CONTENTS/Resources/Payload" build/payload
  fetch() { # url sha256
    local file="build/payload/$(basename "$1")"
    if [ ! -f "$file" ] || ! echo "$2  $file" | shasum -a 256 -c - >/dev/null 2>&1; then
      curl -fL --progress-bar "$1" -o "$file"
      echo "$2  $file" | shasum -a 256 -c -
    fi
    cp "$file" "$CONTENTS/Resources/Payload/"
  }
  fetch https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-staging-11.18-osx64.tar.xz b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127
  fetch https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507/dxvk-macOS-async-v1.10.3-20230507.tar.gz f67d99d0a8eeedd7d406b283a3df9f939b5965acb00efcb33d0c6235c195a516
  fetch https://raw.githubusercontent.com/Winetricks/winetricks/20260125/src/winetricks 431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b
fi

echo "==> Ad-hoc signing"
codesign --force --sign - "$CONTENTS/Resources/bin/cabextract"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> Zipping"
SUFFIX=""
if [ "$EMBED" = 1 ]; then SUFFIX="-offline"; fi
ZIP="dist/Vintner-$VERSION$SUFFIX.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Done: $APP  ($(du -sh "$APP" | cut -f1)),  $ZIP"
