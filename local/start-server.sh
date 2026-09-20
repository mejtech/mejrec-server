#!/usr/bin/env bash
# RecFlare local server: the Workers + the TLS front door + Luxon (self-hosted Photon).
#
# `just dev` runs `turbo dev`, but turbo marks its dev tasks "interactive" (needs a TTY)
# and its TUI segfaults under this many persistent tasks, so each worker's own `dev`
# script is started directly. Ports still come from run-wrangler-dev, so proxy.mjs's map
# is right. Everything lives under local/; the repo is this folder's parent.
#
#   local/start-server.sh start     start workers + proxy + luxon
#   local/start-server.sh stop      stop all three
#   local/start-server.sh restart
#   local/start-server.sh status
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="${RECFLARE_REPO:-$(cd "$HERE/.." && pwd)}"
LUXON_DIR="$HERE/luxon"
LOGDIR="$HERE/logs"
PIDDIR="$HERE/pids"

export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate bash 2>/dev/null)" || true

apps() {
	# Same order run-wrangler-dev numbers ports in: sorted by package.json name.
	for dir in "$REPO"/apps/*/; do
		[ -f "${dir}wrangler.jsonc" ] || continue
		[ -f "${dir}package.json" ] || continue
		printf '%s\t%s\n' "$(jq -r '.name' "${dir}package.json")" "${dir%/}"
	done | sort
}

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

# Kill a pid's whole process group (started with setsid, so pgid == pid).
kill_tree() {
	local pid="$1"
	kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
}

warn_if_443_locked() {
	# proxy.mjs binds 443 so the 2023 client's port-less nameserver fetch lands somewhere.
	local start
	start=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)
	if [ "$start" -gt 443 ] 2>/dev/null; then
		echo "note: 443 is a privileged port here (ip_unprivileged_port_start=$start)." >&2
		echo "      The proxy will still serve :8443; to enable the 2023 client's first" >&2
		echo "      fetch, run:  sudo sysctl -w net.ipv4.ip_unprivileged_port_start=443" >&2
	fi
}

start_workers() {
	mkdir -p "$LOGDIR" "$PIDDIR"
	while IFS=$'\t' read -r name dir; do
		if alive "$PIDDIR/$name.pid"; then
			echo "already running: $name"
			continue
		fi
		(
			cd "$dir"
			# setsid makes the worker a session/group leader (so stop can kill the whole
			# pnpm+wrangler+workerd tree with `kill -- -pid`), but it forks when the job is
			# already a group leader — so `$!` is setsid, not the worker. Let the child write
			# its own pid (which becomes pnpm's via exec) instead.
			setsid bash -c 'echo $$ >"$1"; exec pnpm dev' _ "$PIDDIR/$name.pid" \
				>"$LOGDIR/$name.log" 2>&1 < /dev/null &
		)
		echo "started: $name"
	done < <(apps)
}

start_luxon() {
	if alive "$LUXON_DIR/luxon.pid"; then
		echo "already running: luxon"
		return
	fi
	if [ ! -x "$LUXON_DIR/luxon_server" ]; then
		echo "luxon_server not found in $LUXON_DIR — run local/setup.sh first" >&2
		return
	fi
	(
		cd "$LUXON_DIR"
		setsid bash -c 'echo $$ >luxon.pid; exec ./luxon_server' >luxon.log 2>&1 < /dev/null &
	)
	echo "started: luxon"
}

start() {
	warn_if_443_locked
	start_workers
	start_luxon
	# Proxy last, once the workers have had a moment to bind.
	sleep 3
	"$HERE/start.sh"
}

stop() {
	if [ -d "$PIDDIR" ]; then
		for pidfile in "$PIDDIR"/*.pid; do
			[ -e "$pidfile" ] || continue
			alive "$pidfile" && kill_tree "$(cat "$pidfile")"
			rm -f "$pidfile"
		done
	fi
	alive "$HERE/proxy.pid" && kill "$(cat "$HERE/proxy.pid")" 2>/dev/null || true
	rm -f "$HERE/proxy.pid"
	alive "$LUXON_DIR/luxon.pid" && kill "$(cat "$LUXON_DIR/luxon.pid")" 2>/dev/null || true
	rm -f "$LUXON_DIR/luxon.pid"
	echo "stopped"
}

status() {
	local up=0 total=0
	while IFS=$'\t' read -r name dir; do
		total=$((total + 1))
		alive "$PIDDIR/$name.pid" && up=$((up + 1)) || echo "down: $name"
	done < <(apps)
	echo "$up/$total workers running"
	alive "$HERE/proxy.pid" && echo "proxy running" || echo "proxy down"
	alive "$LUXON_DIR/luxon.pid" && echo "luxon running" || echo "luxon down"
}

case "${1:-start}" in
start) start ;;
stop) stop ;;
restart) stop; sleep 2; start ;;
status) status ;;
*) echo "usage: $0 {start|stop|restart|status}" >&2; exit 2 ;;
esac
