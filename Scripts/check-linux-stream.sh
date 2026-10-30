#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mkdir -p work && cd work && pwd)"
part="${1:?Usage: $0 \"<part of a game title>\" [seconds]}"
seconds="${2:-40}"
APP="$WORK/linux/$(uname -m)/con/con"
LOG="$WORK/linux-stream.log"
STAMP="$WORK/last-game-start"
[[ -x "$APP" ]] || { echo "No Con for Linux: run Scripts/build-linux.sh first." >&2; exit 2; }
if [[ -f "$STAMP" ]]; then since=$(( $(date +%s) - $(cat "$STAMP") )); (( since >= 60 )) || { echo "The last session was requested $since s ago: wait $((60 - since)) s." >&2; exit 2; }; fi
pgrep -f "Xvfb :99" > /dev/null || { Xvfb :99 -screen 0 1280x800x24 -nolisten tcp > /dev/null 2>&1 & sleep 1; }
export DISPLAY=:99 SDL_VIDEODRIVER=x11 XDG_RUNTIME_DIR="/run/user/$(id -u)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
asked="" connected=""
stamp() {
  if [[ -z "$connected" ]] && grep -q "stream: phase connecting" "$LOG"; then asked=1 connected=1; date +%s > "$STAMP"
  elif [[ -z "$asked" ]] && grep -q "launching true" "$LOG"; then asked=1; date +%s > "$STAMP"; fi
}
stop() {
  [[ -n "$pid" ]] || return 0
  kill -TERM "$pid" 2> /dev/null || true
  for _ in $(seq 1 10); do kill -0 "$pid" 2> /dev/null || break; sleep 1; done
  kill -KILL "$pid" 2> /dev/null || true
  pid=""
}
"$APP" --play "$part" > "$LOG" 2>&1 &
pid=$!
trap 'stamp; stop' EXIT
trap 'exit 130' INT TERM HUP
state=waiting
for _ in $(seq 1 120); do
  sleep 1
  stamp
  kill -0 "$pid" 2> /dev/null || { state=stopped; break; }
  grep -q "play: no game" "$LOG" && { state=nogame; break; }
  grep -q "stream: phase streaming" "$LOG" && { state=streaming; break; }
  grep -qE "stream: phase idle launching false note .+" "$LOG" && grep -q "stream: phase connecting\|launching true" "$LOG" && { state=ended; break; }
done
stamp
if [[ "$state" == streaming ]]; then
  sleep $(( seconds / 2 )); import -window root "$WORK/linux-stream.png" || true; sleep $(( seconds - seconds / 2 ))
fi
stop
grep -E "^play:|^stream:" "$LOG" | grep -v "figures" | awk '!seen[$0]++' | head -30 || true
grep "stream: figures" "$LOG" | sed -n '1p;$p' || true
echo "result: $state"
