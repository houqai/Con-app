#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mkdir -p work && cd work && pwd)"
ARCH="$(uname -m)"
CONFIG="${1:-release}"
export CON_SYSTEM=linux
export CON_ENGINE_LIB="${CON_ENGINE_LIB:-$WORK/engine-rust/$ARCH-unknown-linux-gnu}"
[[ -f "$CON_ENGINE_LIB/libcon_engine.a" ]] || { echo "No engine for Linux $ARCH: run Engine/build.sh $ARCH-unknown-linux-gnu first." >&2; exit 2; }
export CON_PLATFORM_LIB="${CON_PLATFORM_LIB:-$WORK/platform-rust/$ARCH-unknown-linux-gnu}"
[[ -f "$CON_PLATFORM_LIB/libcon_platform.a" && -f "$WORK/platform-rust/include/con_platform.h" ]] || { echo "No platform code for Linux $ARCH: run Platform/build.sh $ARCH-unknown-linux-gnu first." >&2; exit 2; }
[[ -f "$CON_PLATFORM_LIB/libcon_desktop.a" && -x "$CON_PLATFORM_LIB/con-login" && -f "$WORK/platform-rust/include/con_desktop.h" ]] || { echo "No desktop parts for Linux $ARCH: run Platform/build.sh $ARCH-unknown-linux-gnu on this machine." >&2; exit 2; }
rm -f "$WORK/linux-build/$CONFIG/con"
LOG="$WORK/linux-build.log"
if ! swift build --scratch-path "$WORK/linux-build" -c "$CONFIG" --product con > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sed -E "s|$PWD/||" | sort -u | head -30 >&2
  echo "Con for Linux does not build. See $LOG" >&2
  exit 1
fi
OUT="$WORK/linux/$ARCH/con"
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$WORK/linux-build/$CONFIG/con" "$CON_PLATFORM_LIB/con-login" "$OUT/"
cp Resources/Con.png THIRD-PARTY-NOTICES.md Linux/install-apparmor.sh "$OUT/"
echo "Con for Linux $ARCH: $OUT"
