#!/bin/zsh
# Smoke test pomocnika Now Playing na prawdziwym MediaRemote (sekcja 11.3 specu).
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
PID=""
cleanup() {
  exec 3>&- || true
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "Kompilacja pomocnika…"
xcrun clang -O2 -fobjc-arc -fblocks -dynamiclib -framework Foundation \
  Helper/NowPlayingHelper.m -o "$WORK/NowPlayingHelper.dylib"

mkfifo "$WORK/in"
/usr/bin/perl Helper/nowplaying-helper.pl "$WORK/NowPlayingHelper.dylib" < "$WORK/in" > "$WORK/out" 2> "$WORK/err" &
PID=$!
exec 3> "$WORK/in"

sleep 5
print -r -- '{"cmd":"togglePlayPause","bundle":"nie.ma.takiego"}' >&3
sleep 1

/usr/bin/python3 - "$WORK/out" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
messages = []
for number, line in enumerate(lines, 1):
    try:
        messages.append(json.loads(line))
    except ValueError:
        sys.exit(f"FAIL: linia {number} to nie JSON: {line[:80]}")
if not messages or messages[0].get("type") != "hello":
    sys.exit("FAIL: pierwsza linia to nie hello")
states = [m for m in messages if m.get("type") == "state"]
if len(states) < 3:
    sys.exit(f"FAIL: tylko {len(states)} linii state w 5 s")
acks = [m for m in messages if m.get("type") == "ack" and m.get("bundle") == "nie.ma.takiego"]
if not acks or acks[0].get("ok") is not False:
    sys.exit("FAIL: brak ack z ok:false dla nieistniejącego odtwarzacza")
players = states[-1].get("players", [])
print(f"OK: hello, {len(states)} x state, ack ok:false; odtwarzacze teraz: {[p.get('bundle') for p in players]}")
PY

exec 3>&-
for i in {1..20}; do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$PID" 2>/dev/null; then
  echo "FAIL: pomocnik nie zakończył się w 2 s po zamknięciu wejścia"
  exit 1
fi
CODE=0
wait "$PID" || CODE=$?
PID=""
if [ "$CODE" != "0" ]; then
  echo "FAIL: kod wyjścia $CODE zamiast 0"
  cat "$WORK/err"
  exit 1
fi
echo "OK: zamknięcie wejścia kończy pomocnika kodem 0"
