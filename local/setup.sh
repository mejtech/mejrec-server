#!/usr/bin/env bash
# One-shot local setup. Interactive, safe to re-run.
#
#   - picks a realtime backend (Luxon self-hosted, or Photon Cloud)
#   - generates the TLS cert and, for Luxon, fetches the binary + config
#   - writes/updates .env
#   - installs dependencies, applies the D1 schema, seeds the shared JWT key
#   - offers to allow the proxy to bind 443
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="${RECFLARE_REPO:-$(cd "$HERE/.." && pwd)}"
LUXON_DIR="$HERE/luxon"
LUXON_VERSION="v1.4.2"
ENV_FILE="$REPO/.env"
MIGRATE_WORKERS="api auth chat clubs econ img leaderboard lists match roomcomments rooms"

export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate bash 2>/dev/null)" || true

say() { printf '%s\n' "$*"; }
say_err() { printf '%s\n' "$*" >&2; }

# Read a line with a default. Non-interactive stdin just takes the default.
ask() {
	local prompt="$1" default="${2:-}" reply=""
	if [ -t 0 ]; then read -r -p "$prompt [$default]: " reply || true; fi
	printf '%s' "${reply:-$default}"
}

# Set/replace an uncommented KEY=VALUE line in .env (append if absent).
set_env() {
	local key="$1" val="$2"
	if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
		awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k {print k"="v; next} {print}' \
			"$ENV_FILE" >"$ENV_FILE.tmp"
		mv "$ENV_FILE.tmp" "$ENV_FILE"
	else
		printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
	fi
}

# Set KEY=VALUE only if not already present (for defaults we must not clobber).
set_env_default() {
	local key="$1" val="$2"
	grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null || printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
}

choose_backend() {
	local reply=""
	say_err ""
	say_err "Realtime backend:"
	say_err "  1) Luxon (recommended)  fully local, no Photon account. Voice chat is NOT available."
	say_err "  2) Photon Cloud         realtime + voice via Photon Cloud (needs your own app ids)."
	say_err ""
	say_err "  Note: a 'Luxon realtime + Photon voice' split isn't possible — the client uses one"
	say_err "  Photon endpoint for both, so voice follows whichever backend you pick."
	say_err ""
	if [ -t 0 ]; then read -r -p "Choose [1]: " reply || true; fi
	case "${reply:-1}" in
	2) printf 'photon' ;;
	*) printf 'luxon' ;;
	esac
}

say "== RecFlare local setup =="
say "repo: $REPO"

# 1. .env
if [ ! -f "$ENV_FILE" ]; then
	cp "$REPO/.env.example" "$ENV_FILE"
	say "created .env from .env.example"
fi
set_env RECFLARE_DOMAIN "rec.localhost:8443"
set_env RECFLARE_SUBDOMAINS '{"moderation":"api"}'
set_env RECFLARE_PHOTON_REGION "us"

# 2. Backend choice (persisted for server.sh).
BACKEND="$(choose_backend)"
printf '%s\n' "$BACKEND" >"$HERE/backend"
say ""
say "backend: $BACKEND"

# 3. TLS cert (the proxy always runs).
if [ ! -f "$HERE/cert.pem" ] || [ ! -f "$HERE/key.pem" ]; then
	say "generating self-signed cert (cert.pem / key.pem)"
	openssl req -x509 -newkey rsa:2048 -nodes \
		-keyout "$HERE/key.pem" -out "$HERE/cert.pem" -days 3650 \
		-subj "/CN=rec.localhost" \
		-addext "subjectAltName=DNS:rec.localhost,DNS:*.rec.localhost,DNS:localhost,DNS:*.localhost,IP:127.0.0.1" \
		>/dev/null 2>&1
else
	say "cert already present"
fi

# 4. Backend-specific config.
if [ "$BACKEND" = luxon ]; then
	# Luxon ignores the app ids; any GUID keeps the client happy. Don't clobber real ids.
	set_env_default RECFLARE_PHOTON_REALTIME_APP_ID "00000000-0000-4000-8000-000000000001"
	set_env_default RECFLARE_PHOTON_VOICE_APP_ID "00000000-0000-4000-8000-000000000002"
	set_env_default RECFLARE_PHOTON_CHAT_APP_ID "00000000-0000-4000-8000-000000000003"
	if [ ! -x "$LUXON_DIR/luxon_server" ]; then
		arch=$(uname -m)
		os=$(uname -s)
		if [ "$os" = Linux ] && [ "$arch" = x86_64 ]; then
			say "downloading Luxon Server $LUXON_VERSION"
			curl -fsSL --retry 3 -o "$LUXON_DIR/luxon_server" \
				"https://github.com/niansa/LuxonServer/releases/download/$LUXON_VERSION/luxon_server.musl-static.release.linux-x86_64"
			chmod +x "$LUXON_DIR/luxon_server"
		else
			say "!! no prebuilt Luxon for $os/$arch — grab one from"
			say "   https://github.com/niansa/LuxonServer/releases and put it at"
			say "   $LUXON_DIR/luxon_server (chmod +x)"
		fi
	else
		say "luxon_server already present"
	fi
	if [ ! -f "$LUXON_DIR/config.yml" ]; then
		cp "$LUXON_DIR/config.example.yml" "$LUXON_DIR/config.yml"
		say "wrote luxon/config.yml"
	else
		say "luxon/config.yml already present"
	fi
else
	rt=$(ask "Photon Realtime App ID" "")
	vo=$(ask "Photon Voice App ID" "")
	ch=$(ask "Photon Chat App ID" "")
	[ -n "$rt" ] && set_env RECFLARE_PHOTON_REALTIME_APP_ID "$rt"
	[ -n "$vo" ] && set_env RECFLARE_PHOTON_VOICE_APP_ID "$vo"
	[ -n "$ch" ] && set_env RECFLARE_PHOTON_CHAT_APP_ID "$ch"
	say "Photon Cloud mode: not fetching Luxon. Fill in any blank ids in .env yourself."
fi

# 5. Dependencies.
say ""
say "installing dependencies (pnpm install)"
if (cd "$REPO" && pnpm install --child-concurrency=10 >/dev/null); then
	say "  dependencies installed"
else
	say "  pnpm install failed" >&2
	exit 1
fi

# 6. D1 schema into the shared local database.
say "applying D1 migrations into the shared local database"
for w in $MIGRATE_WORKERS; do
	if (cd "$REPO/apps/$w" && PATH="$PWD/node_modules/.bin:$PATH" run-wrangler-migrate --local >/dev/null 2>&1); then
		say "  migrated: $w"
	else
		say "  FAILED: $w (re-run just this one to see why)"
	fi
done

# 7. Shared JWT signing key.
say "seeding the shared JWT key"
if (cd "$REPO/apps/auth" && printf 'local-dev-jwt-secret-do-not-use-in-prod' |
	PATH="$PWD/node_modules/.bin:$PATH" wrangler secrets-store secret create local \
		--name JWT_SECRET --scopes workers \
		--persist-to "$REPO/.wrangler/state" >/dev/null 2>&1); then
	say "  JWT_SECRET created"
else
	say "  JWT_SECRET already present (or create failed — harmless if it exists)"
fi

# 8. Let the proxy bind 443 (the 2023 client's nameserver fetch drops the port).
if [ "$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)" -gt 443 ] 2>/dev/null; then
	if [ -t 0 ]; then
		read -r -p "Allow the proxy to bind 443 now? (runs sudo) [y/N]: " yn || true
		if [ "${yn:-n}" = y ] || [ "${yn:-n}" = Y ]; then
			sudo sysctl -w net.ipv4.ip_unprivileged_port_start=443 ||
				say "  sysctl failed — the proxy will still serve :8443"
		fi
	else
		say "note: to let the proxy bind 443, run:"
		say "  sudo sysctl -w net.ipv4.ip_unprivileged_port_start=443"
	fi
fi

say ""
say "Done."
say "  start:  local/server.sh start"
say "  check:  local/server.sh status"
if [ "$BACKEND" = luxon ]; then
	say "  client: Photon name server 127.0.0.1:5058, RecNet name server https://ns.rec.localhost:8443 (see README)"
else
	say "  client: use your Photon Cloud apps; leave the Photon name server at its default (see README)"
fi
