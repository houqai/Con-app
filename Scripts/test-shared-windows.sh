#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
. Scripts/windows-env.sh
WINE=(/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine --bottle "${CON_WINE_BOTTLE:-con-test}")
PLATFORM="$W/swift-sdk/LocalApp/Programs/Swift/Platforms/$SWIFT_VERSION/Windows.platform/Developer/Library"
windows_libraries
[[ -f "$DEPS/pkgconfig/sdl2.pc" ]] || { echo "No libraries for Windows: run Scripts/windows-deps.sh first." >&2; exit 2; }
export PKG_CONFIG_PATH="$DEPS/pkgconfig" PKG_CONFIG_LIBDIR="$DEPS/pkgconfig"
"$TOOLS/swift" build --build-system native --swift-sdks-path "$W/sdks" --swift-sdk x86_64-unknown-windows-msvc --build-tests \
  --scratch-path "$ROOT/work/windows-build" -Xcc -I"$DEPS/include" -Xswiftc -L"$DEPS/lib" > "$W/test-build.log" 2>&1 \
  || { grep -E "error" "$W/test-build.log" | head -20 >&2; echo "Test build failed: $W/test-build.log" >&2; exit 1; }
RUN="$W/tests"
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$ROOT/work/windows-build/x86_64-unknown-windows-msvc/debug/ConPackageTests.xctest" "$RUN/ConPackageTests.exe"
cp "$W/swift-rtl"/*.dll "$PLATFORM/XCTest-$SWIFT_VERSION/usr/bin64"/*.dll "$PLATFORM/Testing-$SWIFT_VERSION/usr/bin64"/*.dll "$RUN/"
cd "$RUN"
export WINEDEBUG=-all
"${WINE[@]}" --wait-children "$RUN/ConPackageTests.exe" ${1:+"$1"} 2>&1 | tr -d '\r' | tee xctest.log | grep -E "error|failed|Executed .* tests" | tail -40
"${WINE[@]}" --wait-children "$RUN/ConPackageTests.exe" --testing-library swift-testing ${1:+--filter "$1"} 2>&1 | tr -d '\r' | tee testing.log | grep -E "failed|passed after|recorded an issue" | tail -40
