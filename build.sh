#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
BUILD_DIR="${NATIVENOTES_BUILD_DIR:-$PWD/.build}"
APP="${NATIVENOTES_APP_PATH:-$PWD/dist/NativeNotes.app}"
mkdir -p "$BUILD_DIR/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/ModuleCache"
swift build --disable-sandbox --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/cache" -c release
BINARY_DIR=$(swift build --disable-sandbox --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/cache" -c release --show-bin-path)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Replace atomically so a running app never observes a partially overwritten binary.
cp "$BINARY_DIR/NativeNotes" "$APP/Contents/MacOS/NativeNotes.next"
mv -f "$APP/Contents/MacOS/NativeNotes.next" "$APP/Contents/MacOS/NativeNotes"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/NativeNotes.icns "$APP/Contents/Resources/NativeNotes.icns"
codesign --force --options runtime --entitlements Resources/NativeNotes.entitlements --sign - "$APP"
codesign --verify --deep --strict "$APP"
touch "$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then "$LSREGISTER" -f "${APP:A}"; fi
printf 'Built: %s\n' "${APP:A}"
