#!/bin/bash
# Uruchamia testy z samym Command Line Tools (ładuje makra z Xcode.app, jeśli są).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
X=/Applications/Xcode.app/Contents/Developer
FLAGS=()
for p in "$X/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" \
         "$X/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"; do
  [ -f "$p" ] && FLAGS+=(-Xswiftc -load-plugin-library -Xswiftc "$p")
done
swift test "${FLAGS[@]}" "$@" 2>&1 | grep -vE "^\s*$" | cut -c1-300 | tail -60
