#!/usr/bin/env bash
# Cross-build dependencies for a Windows (x86_64, mingw-w64) ellipse build.
#
# Needs: x86_64-w64-mingw32-gcc, the mingw64-SDL3 package (Fedora:
# `dnf install mingw64-gcc mingw64-SDL3`), cmake, ninja, git.
# Produces build/win64/prefix with SDL3_ttf (vendored FreeType; HarfBuzz and
# plutosvg off, they need a mingw C++ compiler) and stages every DLL the
# executables need in build/win64/dll.

set -euo pipefail

TTF_TAG="release-3.2.2"
MINGW_ROOT="${MINGW_ROOT:-/usr/x86_64-w64-mingw32/sys-root/mingw}"

cd "$(dirname "$0")/.."
ROOT="$PWD/build/win64"
mkdir -p "$ROOT/src" "$ROOT/prefix" "$ROOT/dll"

if [ ! -d "$ROOT/src/SDL_ttf" ]; then
    git clone --depth 1 --branch "$TTF_TAG" \
        https://github.com/libsdl-org/SDL_ttf "$ROOT/src/SDL_ttf"
    (cd "$ROOT/src/SDL_ttf" && ./external/download.sh)
fi

cmake -S "$ROOT/src/SDL_ttf" -B "$ROOT/build-ttf" -G Ninja \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc \
    -DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres \
    -DCMAKE_FIND_ROOT_PATH="$MINGW_ROOT" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$ROOT/prefix" \
    -DSDL3_DIR="$MINGW_ROOT/lib/cmake/SDL3" \
    -DSDLTTF_VENDORED=ON \
    -DSDLTTF_HARFBUZZ=OFF \
    -DSDLTTF_PLUTOSVG=OFF \
    -DSDLTTF_SAMPLES=OFF
cmake --build "$ROOT/build-ttf"
cmake --install "$ROOT/build-ttf"

cp "$MINGW_ROOT/bin/SDL3.dll" "$ROOT/dll/"
cp "$ROOT/prefix/bin/SDL3_ttf.dll" "$ROOT/dll/"
# the mingw runtime the executables link dynamically
for dll in libgcc_s_seh-1.dll libwinpthread-1.dll libssp-0.dll; do
    if [ -f "$MINGW_ROOT/bin/$dll" ]; then cp "$MINGW_ROOT/bin/$dll" "$ROOT/dll/"; fi
done
echo "Windows dependencies ready in $ROOT"
