#!/usr/bin/env bash
# One-time setup for the local stack: self-signed TLS cert, Luxon binary + config.
# Safe to re-run; it only creates what's missing.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LUXON_DIR="$HERE/luxon"
LUXON_VERSION="v1.4.2"

# 1. Self-signed cert for *.rec.localhost. The clients' patches disable certificate
#    validation, so a self-signed cert is enough.
if [ ! -f "$HERE/cert.pem" ] || [ ! -f "$HERE/key.pem" ]; then
	echo "generating self-signed cert (cert.pem / key.pem)"
	openssl req -x509 -newkey rsa:2048 -nodes \
		-keyout "$HERE/key.pem" -out "$HERE/cert.pem" -days 3650 \
		-subj "/CN=rec.localhost" \
		-addext "subjectAltName=DNS:rec.localhost,DNS:*.rec.localhost,DNS:localhost,DNS:*.localhost,IP:127.0.0.1" \
		>/dev/null 2>&1
else
	echo "cert already present"
fi

# 2. Luxon Server binary (self-hosted Photon Realtime).
if [ ! -x "$LUXON_DIR/luxon_server" ]; then
	arch=$(uname -m)
	os=$(uname -s)
	if [ "$os" = "Linux" ] && [ "$arch" = "x86_64" ]; then
		url="https://github.com/niansa/LuxonServer/releases/download/$LUXON_VERSION/luxon_server.musl-static.release.linux-x86_64"
		echo "downloading Luxon Server $LUXON_VERSION"
		curl -fsSL --retry 3 -o "$LUXON_DIR/luxon_server" "$url"
		chmod +x "$LUXON_DIR/luxon_server"
	else
		echo "!! No prebuilt Luxon for $os/$arch — grab one from" >&2
		echo "   https://github.com/niansa/LuxonServer/releases and put it at" >&2
		echo "   $LUXON_DIR/luxon_server (chmod +x)" >&2
	fi
else
	echo "luxon_server already present"
fi

# 3. Luxon config.
if [ ! -f "$LUXON_DIR/config.yml" ]; then
	cp "$LUXON_DIR/config.example.yml" "$LUXON_DIR/config.yml"
	echo "wrote luxon/config.yml"
else
	echo "luxon/config.yml already present"
fi

cat <<EOF

Setup done. Next:

  1. cp .env.example .env   (set RECFLARE_DOMAIN=rec.localhost:8443 and your Photon app ids)
  2. pnpm install
  3. Apply local migrations into the shared D1:
       for w in api auth chat clubs econ img leaderboard lists match roomcomments rooms; do
         (cd apps/\$w && PATH="\$PWD/node_modules/.bin:\$PATH" run-wrangler-migrate --local)
       done
  4. Allow the proxy to bind 443 (the 2023 client's first nameserver fetch):
       sudo sysctl -w net.ipv4.ip_unprivileged_port_start=443
       # persist: echo 'net.ipv4.ip_unprivileged_port_start=443' | sudo tee /etc/sysctl.d/99-recflare.conf
  5. local/start-server.sh start

Client side (see local/README.md): point the RecNet nameserver at
https://ns.rec.localhost:8443 and Photon at 127.0.0.1:5058.
EOF
