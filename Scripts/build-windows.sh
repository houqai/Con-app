#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
. Scripts/windows-env.sh
CONFIGURATION=release
[[ "${1:-}" == debug ]] && CONFIGURATION=debug
windows_libraries
[[ -f "$CON_PLATFORM_LIB/con_desktop.lib" && -f "$CON_PLATFORM_LIB/con-login.exe" && -f "$ROOT/work/platform-rust/include/con_desktop.h" ]] || { echo "No desktop parts for Windows: run Platform/build.sh x86_64-pc-windows-msvc (after Scripts/windows-deps.sh)." >&2; exit 2; }
[[ -f "$DEPS/lib/SDL2.lib" && -f "$DEPS/pkgconfig/sdl2.pc" ]] || { echo "No libraries for Windows: run Scripts/windows-deps.sh first." >&2; exit 2; }

export PKG_CONFIG_PATH="$DEPS/pkgconfig" PKG_CONFIG_LIBDIR="$DEPS/pkgconfig"
RES="$W/resources"
Scripts/windows-icon.sh > /dev/null
rm -f "$ROOT/work/windows-build/x86_64-unknown-windows-msvc/$CONFIGURATION/con-app.exe"
LOG="$W/build-$CONFIGURATION.log"
"$TOOLS/swift" build -c "$CONFIGURATION" --build-system native --swift-sdks-path "$W/sdks" --swift-sdk x86_64-unknown-windows-msvc \
  --scratch-path "$ROOT/work/windows-build" --product con-app -Xswiftc -L"$DEPS/lib" -Xswiftc -file-prefix-map -Xswiftc "$HOME=~" -Xcc -ffile-prefix-map="$HOME=~" -Xlinker "$RES/con.res" \
  -Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup > "$LOG" 2>&1 \
  || { grep -E "error" "$LOG" | sort -u | head -30 >&2; echo "Build failed: $LOG" >&2; exit 1; }

BIN="$ROOT/work/windows-build/x86_64-unknown-windows-msvc/$CONFIGURATION"
OUT="$W/Con-windows-x64"
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$BIN/con-app.exe" "$CON_PLATFORM_LIB/con-login.exe" "$OUT/"
cp "$W/swift-rtl"/*.dll "$DEPS/bin"/*.dll "$OUT/"
cp Resources/Con.png "$OUT/con-logo.png"
cp THIRD-PARTY-NOTICES.md "$OUT/"
mkdir -p "$OUT/licenses" "$OUT/fonts" && cp -R "$DEPS/licenses/." "$OUT/licenses/" && cp Resources/Licenses/Swift.txt Resources/Licenses/Swift-Foundation.txt Resources/Licenses/ICU.txt "$OUT/licenses/" && cp "$DEPS/fonts"/*.ttf "$OUT/fonts/"
cat > "$OUT/fonts/fonts.conf" <<'XML'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir prefix="relative">.</dir>
  <dir>WINDOWSFONTDIR</dir>
  <cachedir>LOCAL_APPDATA_FONTCONFIG_CACHE</cachedir>
</fontconfig>
XML
echo "Con for Windows ($CONFIGURATION): $OUT ($(du -sh "$OUT" | cut -f1))"
if [[ "${2:-${1:-}}" == zip ]]; then
  (cd "$W" && rm -f Con-windows-x64.zip && zip -qr Con-windows-x64.zip Con-windows-x64)
  echo "Zip: $W/Con-windows-x64.zip"
fi
