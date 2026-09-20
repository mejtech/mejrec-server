#!/usr/bin/env bash
# Start just the local TLS front door (proxy.mjs). Called by start-server.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LOG="$HERE/proxy.log"
PIDFILE="$HERE/proxy.pid"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
	echo "proxy already running (pid $(cat "$PIDFILE"))"
	exit 0
fi

nohup node "$HERE/proxy.mjs" >"$LOG" 2>&1 &
echo $! >"$PIDFILE"
sleep 1
if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
	echo "proxy started (pid $(cat "$PIDFILE"))"
	echo "log: $LOG"
else
	echo "proxy failed to start; see $LOG" >&2
	exit 1
fi
