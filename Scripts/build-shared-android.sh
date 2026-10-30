#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
. Scripts/android-env.sh
android_abi "${1:-arm64-v8a}"
OUT="$WORK/android/$ABI"
[[ -x "$SWIFT" ]] || { echo "No swift.org compiler. See docs/BUILD.md." >&2; exit 2; }
android_libraries
PRODUCTS=Release-android-$ARCH
LOG="$OUT/logs/shared.log"
mkdir -p "$OUT/logs"
rm -f "$SCRATCH/out/Products/$PRODUCTS/libConShared.so"
if ! "$SWIFT" build --swift-sdk "$TRIPLE" --product ConShared -c release --scratch-path "$SCRATCH" -Xswiftc -file-prefix-map -Xswiftc "$HOME=~" -Xcc -ffile-prefix-map="$HOME=~" > "$LOG" 2>&1; then
  grep -E "error:|undefined" "$LOG" | sort -u | head -30 >&2
  echo "The shared code does not build for Android $ABI. See $LOG" >&2
  exit 1
fi
BUILT="$SCRATCH/out/Products/$PRODUCTS/libConShared.so"
[[ -f "$BUILT" ]] || { echo "No library at $BUILT" >&2; exit 1; }
cp "$BUILT" "$OUT/libConShared.so"
STRIP=$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-strip | head -1)
"$STRIP" --strip-debug "$OUT/libConShared.so"
python3 Scripts/check-android-library.py "$OUT/libConShared.so" "$ANDROID_NDK_HOME" "$ABI"
echo "Shared code and engine for Android $ABI: $OUT/libConShared.so"
