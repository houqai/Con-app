#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
. Scripts/android-env.sh
OUT="$WORK/android/arm64-v8a"
APK="$OUT/con-check.apk"
[[ -f "$APK" ]] || { echo "No app: run Scripts/build-android-check-app.sh first." >&2; exit 2; }
android_device
adb install -r "$APK" > /dev/null
adb shell cmd locale set-app-locales app.con.check --locales "${1:-}" > /dev/null 2>&1 || true
adb shell am force-stop app.con.check
adb logcat -c
adb shell am start -W -n app.con.check/.MainActivity > /dev/null
result=""
for _ in $(seq 1 45); do
  log="$(adb logcat -d -s ConCheck:I AndroidRuntime:E | tr -d '\r')"
  if grep -qE "FAIL|FATAL EXCEPTION|UnsatisfiedLinkError" <<< "$log"; then result="$(grep -E "FAIL|FATAL EXCEPTION|UnsatisfiedLinkError|Caused by" <<< "$log" | head -3 | sed -E 's/^.*(ConCheck|AndroidRuntime): //' | tr '\n' ' ')"; break; fi
  if grep -qE "state: .* catalogue [1-9]" <<< "$log"; then result="PASS $(grep -E "start: " <<< "$log" | tail -1 | sed -E 's/^.*ConCheck: //'); $(grep -E "state: " <<< "$log" | tail -1 | sed -E 's/^.*ConCheck: //')"; break; fi
  sleep 2
done
if [[ -n "${SHOT:-}" ]]; then sleep 2; adb exec-out screencap -p > "$OUT/con-check${1:+-$1}.png"; fi
echo "On $(android_device_name): ${result:-no result from the app within 90 s}"
[[ -n "${SHOT:-}" ]] && echo "Screen: $OUT/con-check${1:+-$1}.png"
[[ "$result" == *PASS* ]]
