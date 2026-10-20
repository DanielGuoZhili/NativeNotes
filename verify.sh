#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
BUILD_DIR="${NATIVENOTES_BUILD_DIR:-$PWD/.build}"
mkdir -p "$BUILD_DIR/ModuleCache"
swiftc -parse-as-library -D SELF_TEST -module-cache-path "$BUILD_DIR/ModuleCache" -o "$BUILD_DIR/NativeNotesVerify" Sources/NativeNotes/*.swift
"$BUILD_DIR/NativeNotesVerify"
