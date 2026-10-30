#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
. Scripts/android-env.sh
part="${1:?Usage: $0 \"<part of a game title>\" [seconds]}"
seconds="${2:-40}"
STAMP="$WORK/last-game-start"
android_device
adb shell pm path app.con.check > /dev/null 2>&1 || { echo "The check app is not on the device: run Scripts/run-android-check-app.sh first." >&2; exit 2; }
awake="$(adb shell dumpsys power | tr -d '\r' | sed -n 's/^ *mWakefulness=//p' | head -1)"
locked="$(adb shell dumpsys window policy | tr -d '\r' | grep -cE '^ *showing=true' || true)"
[[ "$awake" == Awake && "$locked" == 0 ]] || { echo "The device screen is off or locked (${awake:-unknown}). Unlock it and run again." >&2; exit 2; }
if [[ -z "${FORCE:-}" && -f "$STAMP" ]]; then
  since=$(( $(date +%s) - $(cat "$STAMP") ))
  (( since >= 60 )) || { echo "A game was started $since s ago: Sony may not have closed that session yet. Not starting (wait $((60 - since)) s)." >&2; exit 2; }
fi

adb shell am force-stop app.con.check
adb logcat -c
adb shell am start -W -n app.con.check/.CheckPlay --es play "$part" --el token "$(date +%s)" > /dev/null
app_log() { adb logcat -d -s ConCheck:I AndroidRuntime:E | tr -d '\r'; }
state=waiting
stamped=""
for _ in $(seq 1 60); do
  log="$(app_log)"
  if [[ -z "$stamped" ]] && grep -q "stream: session asked" <<< "$log"; then stamped=1; mkdir -p "$(dirname "$STAMP")"; date +%s > "$STAMP"; fi
  if grep -qE "FAIL|FATAL EXCEPTION" <<< "$log"; then state=failed; break; fi
  if grep -q "play: no listed game" <<< "$log"; then state=nogame; break; fi
  if grep -q "play: " <<< "$log" && [[ "$state" == waiting ]]; then state=launching; fi
  if grep -q "stream: phase streaming" <<< "$log"; then state=streaming; break; fi
  if [[ "$state" == launching ]]; then
    last_phase="$(grep "stream: phase" <<< "$log" | tail -1 || true)"
    if grep -qE "phase (idle|failed) launching false" <<< "$last_phase" && grep -qE "stream: phase (connecting|idle launching true)" <<< "$log"; then state=ended; break; fi
  fi
  sleep 2
done
if [[ "$state" == streaming ]]; then
  sleep "$seconds"
  log="$(app_log)"
  tail -1 <<< "$(grep "stream: phase" <<< "$log")" | grep -q "phase streaming" || state=dropped
fi
if [[ "$state" != nogame && "$state" != waiting ]] && ! grep -q "stream: left" <<< "$(app_log)"; then
  adb shell input keyevent 4
  for _ in $(seq 1 10); do grep -q "stream: left" <<< "$(app_log)" && break; sleep 1; done
  sleep 3
fi
log="$(app_log)"
echo "On $(android_device_name):"
{ grep -E "play: |stream: phase|stream: session|stream: left|FAIL|FATAL EXCEPTION|Caused by" <<< "$log" || true; } | sed -E 's/^.*(ConCheck|AndroidRuntime): /  /' | awk '!seen[$0]++' | head -40
figures="$(grep "stream: figures" <<< "$log" | sed -E 's/^.*ConCheck: stream: figures //' || true)"
[[ -n "$figures" ]] && { echo "  stream stats (first and last):"; head -1 <<< "$figures" | sed 's/^/    /'; tail -1 <<< "$figures" | sed 's/^/    /'; }
first="$(head -1 <<< "$figures" | sed -nE 's/^drawn ([0-9]+) .*/\1/p')"; last="$(tail -1 <<< "$figures" | sed -nE 's/^drawn ([0-9]+) .*/\1/p')"
sound="$(tail -1 <<< "$figures" | sed -nE 's/^.* sound ([0-9]+) .*/\1/p')"
case "$state" in
  streaming)
    if [[ -n "$last" && -n "$first" && "$last" -gt "$first" && "${sound:-0}" -gt 0 ]]; then echo "PASS: streamed for $seconds s, $last frames drawn, $sound audio frames"; exit 0; fi
    echo "FAILED: the stream started, but no new frames or audio arrived (drawn ${first:-?} → ${last:-?}, sound ${sound:-?})"; exit 1 ;;
  dropped) echo "FAILED: the stream ended on its own within $seconds s"; exit 1 ;;
  ended) echo "FAILED: launch ended without a stream (see the log lines above)"; exit 1 ;;
  nogame) echo "FAILED: no listed game title contains \"$part\""; exit 1 ;;
  failed) echo "FAILED: the app stopped or reported an error"; exit 1 ;;
  *) echo "FAILED: nothing started within two minutes (state $state)"; exit 1 ;;
esac
