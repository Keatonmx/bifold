#!/usr/bin/env bash
# Builds the melonDS core (https://github.com/melonDS-emu/melonDS) as a static
# xcframework for iOS devices + simulator and lays out headers for the Bifold
# Xcode project.
#
#   Scripts/build-melonds.sh            # build everything
#   Scripts/build-melonds.sh --clean    # wipe Vendor/build + Vendor/melonds-dist first
#
# Output:
#   Vendor/melonds-dist/melonds.xcframework   (libcore + libteakra merged per slice)
#   Vendor/melonds-dist/include/**            (all core headers, mirroring src/,
#                                              plus the generated version.h)
#
# The library is built with JIT, OpenGL and the GDB stub OFF. Those switches
# add PUBLIC compile definitions (JIT_ENABLED, OGLRENDERER_ENABLED,
# GDBSTUB_ENABLED) that change struct layouts, so the consumer (the ObjC++
# bridge) must compile with none of them defined — which is the default.
#
# Requirements: macOS, Xcode 15+, CMake >= 3.20, Ninja (brew install cmake ninja).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
SRC="$VENDOR/melonds"
BUILD="$VENDOR/build"
DIST="$VENDOR/melonds-dist"
MELONDS_REPO="https://github.com/melonDS-emu/melonDS.git"
# Tag 1.1 (commit b86390e). The bridge was written against this revision.
# Override with MELONDS_REF=<branch|tag|sha> to build something else.
MELONDS_REF="${MELONDS_REF:-1.1}"
IOS_MIN="${IOS_MIN:-16.0}"

if [[ "${1:-}" == "--clean" ]]; then
  rm -rf "$BUILD" "$DIST"
fi

command -v cmake >/dev/null || { echo "cmake not found (brew install cmake)"; exit 1; }
command -v ninja >/dev/null || { echo "ninja not found (brew install ninja)"; exit 1; }
command -v xcrun >/dev/null || { echo "xcrun not found (install Xcode)"; exit 1; }

# ---------------------------------------------------------------- sources
if [[ ! -d "$SRC/.git" ]]; then
  echo "==> Cloning melonDS ($MELONDS_REF)"
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$MELONDS_REPO"
  git -C "$SRC" fetch --depth 1 origin "$MELONDS_REF"
  git -C "$SRC" checkout -q FETCH_HEAD
fi
echo "==> melonDS revision: $(git -C "$SRC" rev-parse --short HEAD)"

# ---------------------------------------------------------------- cmake
# Core library only: no Qt/SDL frontend, no JIT (iOS forbids executable
# memory for sideloaded apps), no OpenGL renderer, no GDB stub.
COMMON_FLAGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
  -DBUILD_QT_SDL=OFF
  -DENABLE_JIT=OFF
  -DENABLE_OGLRENDERER=OFF
  -DENABLE_GDBSTUB=OFF
  -DENABLE_LTO_RELEASE=OFF        # LTO ties the .a to one exact clang; keep archives portable
  -DMELONDS_EMBED_BUILD_INFO=OFF
)

export PKG_CONFIG_LIBDIR=/nonexistent   # never pick up Homebrew libs for an iOS build

build_slice() {   # name sysroot archs
  local name="$1" sysroot="$2" archs="$3"
  local dir="$BUILD/$name"
  echo "==> Configuring $name ($archs)"
  cmake -S "$SRC" -B "$dir" -G Ninja "${COMMON_FLAGS[@]}" \
        -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES="$archs" 2>&1 | tail -n 5
  echo "==> Building $name"
  cmake --build "$dir" --target core 2>&1 | tail -n 3

  # Merge libcore + libteakra (DSi DSP, linked PRIVATE by core) per slice.
  local libs=()
  libs+=("$(find "$dir" -name 'libcore*.a' | head -n 1)")
  while IFS= read -r l; do libs+=("$l"); done < <(find "$dir" -name 'libteakra*.a' || true)
  echo "    merging: ${libs[*]##*/}"
  xcrun libtool -static -o "$dir/libmelonds-merged.a" "${libs[@]}"
}

build_slice ios-arm64          iphoneos        "arm64"
build_slice ios-simulator      iphonesimulator "arm64;x86_64"

# ---------------------------------------------------------------- headers
# The bridge includes core headers by their src/-relative names ("NDS.h",
# "fatfs/ff.h", "frontend/mic_blow.h", …), so mirror the whole header tree —
# minus the Qt frontend, which drags in Qt includes nobody has.
rm -rf "$DIST"; mkdir -p "$DIST/include"
(cd "$SRC/src" && find . -name '*.h' -not -path './frontend/qt_sdl/*' | while IFS= read -r h; do
  mkdir -p "$DIST/include/$(dirname "$h")"
  cp "$h" "$DIST/include/$h"
done)
# Generated version header (configure_file output, lives in the build tree).
cp "$BUILD/ios-arm64/src/version.h" "$DIST/include/version.h"

# ---------------------------------------------------------------- xcframework
xcodebuild -create-xcframework \
  -library "$BUILD/ios-arm64/libmelonds-merged.a" \
  -library "$BUILD/ios-simulator/libmelonds-merged.a" \
  -output "$DIST/melonds.xcframework"

echo
echo "==> Done: $DIST/melonds.xcframework"
ls -la "$DIST/melonds.xcframework"
