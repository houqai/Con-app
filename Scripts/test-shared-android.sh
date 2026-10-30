#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
. Scripts/android-env.sh
android_abi "${1:-arm64-v8a}"
android_libraries
android_device
android_runtime
LOG="$WORK/android/$ABI/logs/shared-tests.log"
mkdir -p "$(dirname "$LOG")"
if ! "$SWIFT" build --build-tests --swift-sdk "$TRIPLE" --scratch-path "$SCRATCH" > "$LOG" 2>&1; then
  sed -E 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "error:" | grep -v SwiftCompile | sort -u | head -30 >&2
  echo "The tests do not build for Android $ABI. See $LOG" >&2
  exit 1
fi
PRODUCTS="$SCRATCH/out/Products/Debug-android-$ARCH"
DEVICE=/data/local/tmp/con-swift-tests
RESULTS="$WORK/android/$ABI/test-results"
rm -rf "$RESULTS"; mkdir -p "$RESULTS"
adb shell "rm -rf $DEVICE && mkdir -p $DEVICE/home $DEVICE/tmp" > /dev/null
adb push "$RUNTIME"/*.so "$LIBCXX" "$DEVICE/" > /dev/null 2>&1
echo "On $(android_device_name) ($(adb shell getprop ro.product.cpu.abi | tr -d '\r')):"
failed=0
for tests in SoleCoreTests SoleCloudTests SoleEngineTests SoleLogicTests; do
  adb push "$PRODUCTS/$tests.so" "$PRODUCTS/$tests-test-runner" "$DEVICE/" > /dev/null 2>&1
  for library in xctest swift-testing; do
    option=""; [[ "$library" == swift-testing ]] && option="--testing-library swift-testing"
    output="$RESULTS/$tests-$library.txt"
    if adb shell "cd $DEVICE && chmod 755 $tests-test-runner && HOME=$DEVICE/home TMPDIR=$DEVICE/tmp LD_LIBRARY_PATH=$DEVICE ./$tests-test-runner $option" > "$output" 2>&1; then verdict=""; else verdict=" FAILED"; fi
    if [[ "$library" == xctest ]]; then summary="$(tr -d '\r' < "$output" | grep -E "Executed [0-9]+ tests?" | tail -1 | sed -E 's/^[[:space:]]*//; s/ in [0-9.]+ \([0-9.]+\) seconds//')"
    else summary="$(tr -d '\r' < "$output" | grep -E "Test run with" | tail -1 | sed -E 's/^[^T]*//; s/ after .*//')"; fi
    [[ "$summary" == "Test run with 0 tests"* || "$summary" == "Executed 0 tests"* ]] && continue
    echo "  $tests, $library: ${summary:-no summary}$verdict"
    if [[ -n "$verdict" ]]; then failed=$((failed + 1)); tr -d '\r' < "$output" | grep -E "error:|recorded an issue|^Test Case .* failed" | sed -E 's#.*/Tests/##' | cut -c1-240 | head -12 || true; fi
  done
done
adb shell "rm -rf $DEVICE" > /dev/null
[[ "$failed" -eq 0 ]] || { echo "Tests of the shared code fail on Android ($failed runs). Outputs: $RESULTS" >&2; exit 1; }
echo "The tests of the shared code pass on Android."
