#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
. Scripts/android-env.sh
android_abi "${1:-arm64-v8a}"
android_libraries
android_device
android_runtime
LOG="$WORK/android/$ABI/logs/android-check.log"
mkdir -p "$(dirname "$LOG")"
if ! "$SWIFT" build --product ConAndroidCheck --swift-sdk "$TRIPLE" --scratch-path "$SCRATCH" > "$LOG" 2>&1; then
  sed -E 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "error:" | grep -v SwiftCompile | sort -u | head -20 >&2
  echo "ConAndroidCheck does not build for Android $ABI. See $LOG" >&2
  exit 1
fi
DEVICE=/data/local/tmp/con-check
adb shell "rm -rf $DEVICE && mkdir -p $DEVICE/home $DEVICE/tmp" > /dev/null
adb push "$RUNTIME"/*.so "$LIBCXX" "$SCRATCH/out/Products/Debug-android-$ARCH/ConAndroidCheck" "$DEVICE/" > /dev/null 2>&1
echo "On $(android_device_name):"
status=0
adb shell "cd $DEVICE && chmod 755 ConAndroidCheck && HOME=$DEVICE/home TMPDIR=$DEVICE/tmp LD_LIBRARY_PATH=$DEVICE ./ConAndroidCheck" 2>&1 | tr -d '\r' | sed 's/^/  /' || status=$?
adb shell "rm -rf $DEVICE" > /dev/null
exit $status
