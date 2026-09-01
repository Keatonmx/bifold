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
# ENet (MIT), for melonDS's LAN local-multiplayer stack.
ENET_REPO="https://github.com/lsalzman/enet.git"
ENET_REF="${ENET_REF:-v1.3.18}"
ENET="$VENDOR/enet"
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

if [[ ! -d "$ENET/.git" ]]; then
  echo "==> Cloning ENet ($ENET_REF)"
  git init -q "$ENET"
  git -C "$ENET" remote add origin "$ENET_REPO"
  git -C "$ENET" fetch --depth 1 origin "$ENET_REF"
  git -C "$ENET" checkout -q FETCH_HEAD
fi

# Compile melonDS's local-wireless stack (src/net) into the core library.
# Appended with a marker so re-runs stay idempotent; simpler and sturdier
# than carrying a context-sensitive patch file.
if ! grep -q BIFOLD_NET_MARKER "$SRC/src/CMakeLists.txt"; then
  cat >> "$SRC/src/CMakeLists.txt" <<'EOF'

# BIFOLD_NET_MARKER: compile the LAN multiplayer stack into the core.
target_sources(core PRIVATE
    net/MPInterface.cpp
    net/LocalMP.cpp
    net/LAN.cpp)
# net/ sources include core headers ("types.h") by bare name; the core's
# own dir is only an INTERFACE include, so add it PRIVATE too.
target_include_directories(core PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
if (BIFOLD_ENET_INCLUDE)
    target_include_directories(core PRIVATE "${BIFOLD_ENET_INCLUDE}")
endif()
EOF
fi

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
  -DBIFOLD_ENET_INCLUDE="$ENET/include"
)

# ENet is fourteen portable C files; compile them per arch by hand rather
# than trusting a decade-old CMakeLists to modern CMake.
build_enet_slice() {   # name sysroot archs(space separated)
  local name="$1" sysroot="$2"; shift 2
  local dir="$BUILD/enet-$name"
  mkdir -p "$dir"
  local minflag="-miphoneos-version-min=$IOS_MIN"
  [[ "$sysroot" == "iphonesimulator" ]] && minflag="-mios-simulator-version-min=$IOS_MIN"
  local thins=()
  for arch in "$@"; do
    local objdir="$dir/$arch"
    mkdir -p "$objdir"
    for c in "$ENET"/*.c; do
      [[ "$(basename "$c")" == "win32.c" ]] && continue
      xcrun clang -c -O2 -arch "$arch" -isysroot "$(xcrun --sdk "$sysroot" --show-sdk-path)" \
        "$minflag" \
        -I"$ENET/include" -DHAS_FCNTL=1 -DHAS_POLL=1 -DHAS_GETADDRINFO=1 -DHAS_GETNAMEINFO=1 \
        -DHAS_INET_PTON=1 -DHAS_INET_NTOP=1 -DHAS_MSGHDR_FLAGS=1 -DHAS_SOCKLEN_T=1 \
        -o "$objdir/$(basename "${c%.c}").o" "$c"
    done
    xcrun libtool -static -o "$dir/libenet-$arch.a" "$objdir"/*.o
    thins+=("$dir/libenet-$arch.a")
  done
  if [[ ${#thins[@]} -gt 1 ]]; then
    xcrun lipo -create "${thins[@]}" -output "$dir/libenet.a"
  else
    cp "${thins[0]}" "$dir/libenet.a"
  fi
}

export PKG_CONFIG_LIBDIR=/nonexistent   # never pick up Homebrew libs for an iOS build

build_slice() {   # name sysroot archs
  local name="$1" sysroot="$2" archs="$3"
  local dir="$BUILD/$name"
  echo "==> Configuring $name ($archs)"
  cmake -S "$SRC" -B "$dir" -G Ninja "${COMMON_FLAGS[@]}" \
        -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES="$archs" 2>&1 | tail -n 5
  echo "==> Building $name"
  if ! cmake --build "$dir" --target core > "$dir/build.log" 2>&1; then
    echo "!! core build failed for $name; errors:"
    grep -E -B 2 -A 8 "error:" "$dir/build.log" | head -n 100
    exit 1
  fi
  tail -n 3 "$dir/build.log"

  # Merge libcore + libteakra (DSi DSP) + libenet (LAN multiplayer) per slice.
  local libs=()
  libs+=("$(find "$dir" -name 'libcore*.a' | head -n 1)")
  while IFS= read -r l; do libs+=("$l"); done < <(find "$dir" -name 'libteakra*.a' || true)
  libs+=("$BUILD/enet-$name/libenet.a")
  echo "    merging: ${libs[*]##*/}"
  xcrun libtool -static -o "$dir/libmelonds-merged.a" "${libs[@]}"
}

build_enet_slice ios-arm64     iphoneos        arm64
build_enet_slice ios-simulator iphonesimulator arm64 x86_64
build_slice ios-arm64          iphoneos        "arm64"
build_slice ios-simulator      iphonesimulator "arm64;x86_64"

# ---------------------------------------------------------------- headers
# The bridge includes core headers by their src/-relative names ("NDS.h",
# "fatfs/ff.h", "frontend/mic_blow.h", …), so mirror the whole header tree —
# minus the Qt frontend, which drags in Qt includes nobody has.
rm -rf "$DIST"; mkdir -p "$DIST/include"
(cd "$SRC/src" && find . \( -name '*.h' -o -name '*.hpp' \) -not -path './frontend/qt_sdl/*' | while IFS= read -r h; do
  mkdir -p "$DIST/include/$(dirname "$h")"
  cp "$h" "$DIST/include/$h"
done)
# Generated version header (configure_file output, lives in the build tree).
cp "$BUILD/ios-arm64/src/version.h" "$DIST/include/version.h"
# ENet headers (LAN.h includes <enet/enet.h>).
cp -R "$ENET/include/enet" "$DIST/include/enet"

# ---------------------------------------------------------------- xcframework
xcodebuild -create-xcframework \
  -library "$BUILD/ios-arm64/libmelonds-merged.a" \
  -library "$BUILD/ios-simulator/libmelonds-merged.a" \
  -output "$DIST/melonds.xcframework"

echo
echo "==> Done: $DIST/melonds.xcframework"
ls -la "$DIST/melonds.xcframework"
