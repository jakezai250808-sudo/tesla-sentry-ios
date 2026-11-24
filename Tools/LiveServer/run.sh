#!/bin/bash
# Runs the upstream server (the read-only checkout in .airbuild/worktree/upstream) on this Mac with
# synthetic events, to check the app against the real protocol from the simulator.
#   Tools/LiveServer/run.sh start     build the archive, start the server in the background, wait until it answers
#   Tools/LiveServer/run.sh serve     the same, but in the foreground (for a service manager)
#   Tools/LiveServer/run.sh status    the server process and a login + /api/events round trip
#   Tools/LiveServer/run.sh stop
# Address http://127.0.0.1:18080 · user admin · password in Tools/LiveServer/password.txt (a fixed
# throwaway value for this local server, not a secret). Everything the server writes goes to
# $WP_LIVE (default /tmp/wp-live). The clips are the app's own demo footage, copied under Tesla's
# file names: colour blocks only, no real car, face or plate.
# ffmpeg and ffprobe are looked for in $WP_LIVE/ffmpeg first: burning the watermark needs a build
# with libass, which this Mac's Homebrew ffmpeg does not have. The watermark font is the one the
# server installs for itself (POST /api/font/dl after a login), kept in $WP_LIVE/fonts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UP="$ROOT/.airbuild/worktree/upstream/sentry-viewer.py"
LIVE="${WP_LIVE:-/tmp/wp-live}"
PORT="${WP_PORT:-18080}"
PASS="$(tr -d '\n' < "$ROOT/Tools/LiveServer/password.txt")"
A="$LIVE/archive"
BASE="http://127.0.0.1:$PORT"

pid() { [ -f "$LIVE/server.pid" ] && kill -0 "$(cat "$LIVE/server.pid")" 2>/dev/null && cat "$LIVE/server.pid" || true; }

# event <Cat> <YYYY-MM-DD_HH-MM-SS> <reason> <camera> <ISO time> <city> <street> <cam>…
event() {
  local cat="$1" stamp="$2" reason="$3" camera="$4" ts="$5" city="$6" street="$7"; shift 7
  mkdir -p "$A/$cat/$stamp"
  local cam
  for cam in "$@"; do cp "$ROOT/WatchpostApp/DemoAssets/demo-$cam.mp4" "$A/$cat/$stamp/$stamp-$cam.mp4"; done
  printf '{"reason": "%s", "camera": "%s", "timestamp": "%s", "city": "%s", "street": "%s"}\n' \
    "$reason" "$camera" "$ts" "$city" "$street" > "$A/$cat/$stamp/event.json"
}

prepare() {
  [ -f "$UP" ] || { echo "upstream checkout missing: $UP" >&2; exit 2; }
  # The system Python 3.9 stops on one 125 KB line of the server with a false "Non-UTF-8 code"
  # error, so a newer one is preferred when it is installed.
  PY="${WP_PYTHON:-}"
  [ -n "$PY" ] || for candidate in /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3; do
    if [ -x "$candidate" ]; then PY="$candidate"; break; fi
  done
  [ -n "$PY" ] || PY=python3
  # The archive and the transcodes are rebuilt; the font and the ffmpeg downloaded stay.
  rm -rf -- "$A" "$LIVE/cache"
  mkdir -p "$A/SentryClips" "$A/SavedClips" "$A/RecentClips" "$LIVE/cache" "$LIVE/fonts"
  SIX="front back left_pillar right_pillar left_repeater right_repeater"
  FOUR="front back left_repeater right_repeater"
  event SentryClips "$(date -v-6M +%Y-%m-%d_%H-%M-%S)" sentry_aware_object_detection 0 "$(date -v-6M +%Y-%m-%dT%H:%M:%S)" "示例市" "演示路12号" $SIX
  event SentryClips "$(date -v-3H +%Y-%m-%d_%H-%M-%S)" sentry_aware_handle 6 "$(date -v-3H +%Y-%m-%dT%H:%M:%S)" "示例市" "样例巷3号地下车库" $FOUR
  event SentryClips "$(date -v-26H +%Y-%m-%d_%H-%M-%S)" sentry_aware_proximity 7 "$(date -v-26H +%Y-%m-%dT%H:%M:%S)" "" "" $FOUR
  event SavedClips  "$(date -v-1d +%Y-%m-%d_%H-%M-%S)" user_interaction_honk "" "$(date -v-1d +%Y-%m-%dT%H:%M:%S)" "示例市" "虚构停车场A区" $FOUR
  event RecentClips "$(date -v-21M +%Y-%m-%d_%H-%M-%S)" "" "" "" "" "" $FOUR
  event RecentClips "$(date -v-20M +%Y-%m-%d_%H-%M-%S)" "" "" "" "" "" $FOUR
  : > "$LIVE/settings.json"
  # /bin/bash here is 3.2: no associative arrays, so the environment is a list of KEY=VALUE.
  SRV_ENV=("TSF_PORT=$PORT" "TSF_ARCHIVE=$A" "TSF_CACHE=$LIVE/cache" "TSF_FONTS=$LIVE/fonts"
           "TSF_USB_LOCK=$LIVE/usb.lock" "TSF_AUTH_PASS=$PASS" "TSF_AUTH_FILE=$LIVE/none.conf"
           "TSF_SETTINGS=$LIVE/settings.json" "TSF_OTA_STATE=$LIVE/ota-state.json"
           "TSF_OTA_SOURCES=http://127.0.0.1:9/disabled-for-local-test" "TSF_PREWARM=0")
  FFMPEG_NOTE="found by the server"
  [ -x "$LIVE/ffmpeg/ffmpeg" ] && { SRV_ENV+=("TSF_FFMPEG=$LIVE/ffmpeg/ffmpeg"); FFMPEG_NOTE="$LIVE/ffmpeg/ffmpeg"; }
  [ -x "$LIVE/ffmpeg/ffprobe" ] && SRV_ENV+=("TSF_FFPROBE=$LIVE/ffmpeg/ffprobe")
  PY_VERSION="$("$PY" --version 2>&1)"
  echo "ffmpeg: $FFMPEG_NOTE  fonts: $(ls "$LIVE/fonts" | tr "\n" " ")  python: $PY ($PY_VERSION)"
}

case "${1:-start}" in
start|serve)
  if [ -n "$(pid)" ]; then echo "already running, pid $(pid), $BASE"; exit 0; fi
  prepare
  if [ "$1" = serve ]; then exec env "${SRV_ENV[@]}" "$PY" "$UP"; fi
  nohup env "${SRV_ENV[@]}" "$PY" "$UP" > "$LIVE/server.log" 2>&1 &
  echo $! > "$LIVE/server.pid"
  for _ in $(seq 1 100); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/ver" || true)"
    case "$code" in 200|401) break;; esac
    kill -0 "$(cat "$LIVE/server.pid")" 2>/dev/null || { echo "server exited:" >&2; cat "$LIVE/server.log" >&2; exit 1; }
    sleep 0.2
  done
  echo "running pid $(pid), $BASE, /api/ver -> $code"
  ;;
status)
  if [ -z "$(pid)" ] && ! pgrep -f "$UP" >/dev/null 2>&1; then echo "not running"; exit 1; fi
  echo "running, $BASE"
  curl -s -o /dev/null -w 'login -> %{http_code}\n' -c "$LIVE/cookies.txt" \
    --data-urlencode "u=admin" --data-urlencode "p=$PASS" --data-urlencode "next=/" "$BASE/login"
  curl -s -b "$LIVE/cookies.txt" "$BASE/api/events" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for cat, events in d.items():
    for e in events:
        print(cat, e["name"], len(e["videos"]), "cams", repr(e.get("meta", {}).get("reason", "")), e.get("meta", {}).get("camera"))'
  curl -s -b "$LIVE/cookies.txt" "$BASE/api/font"; echo
  ;;
stop)
  if [ -n "$(pid)" ]; then kill "$(pid)" && rm -f "$LIVE/server.pid" && echo "stopped"; else echo "not running"; fi
  ;;
*)
  echo "usage: $0 start|serve|status|stop" >&2; exit 2;;
esac
