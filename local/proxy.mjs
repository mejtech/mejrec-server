#!/usr/bin/env node
// Local TLS front door for the RecFlare dev stack.
//
// The clients reach a self-hosted server over HTTPS at the hostnames the `ns` worker
// advertises. Those are `https://<service>.rec.localhost:8443` (see apps/ns/wrangler.jsonc):
// every `*.localhost` name resolves to 127.0.0.1, so no /etc/hosts edit is needed, and
// :8443 avoids binding a privileged port. This terminates that TLS with a self-signed
// cert (the clients' patches disable certificate validation) and reverse-proxies each
// service subdomain to the port `run-wrangler-dev` assigned that worker.
//
// Two port/address quirks are deliberate:
//   - It listens on 443 as well as 8443. The 2025 patch rewrites the whole URI (keeping
//     the :8443), but the 2023 BepInEx plugin swaps only the HOST of `https://ns.rec.net`,
//     so its first nameserver fetch lands on 443. Binding 443 needs privilege; see README.
//   - It listens on both loopbacks. `*.localhost` resolves to 127.0.0.1 *and* ::1, and
//     Wine/BestHTTP will pick the IPv6 one, so missing ::1 means ECONNREFUSED on half the
//     requests.
import fs from 'node:fs'
import http from 'node:http'
import https from 'node:https'
import net from 'node:net'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
// local/ lives directly under the repo root.
const REPO = process.env.RECFLARE_REPO || path.resolve(HERE, '..')
const LISTEN_PORT = Number(process.env.RECFLARE_PROXY_PORT || 8443)
const BASE_PORT = 8787

// Mirrors run-wrangler-dev: the workers are apps/* with a wrangler.jsonc, sorted by their
// package.json `name`, and the Nth (1-based) gets port 8787 + N - 1.
function buildMap() {
	const appsDir = path.join(REPO, 'apps')
	const workers = fs
		.readdirSync(appsDir, { withFileTypes: true })
		.filter((e) => e.isDirectory())
		.map((e) => path.join(appsDir, e.name))
		.filter((dir) => fs.existsSync(path.join(dir, 'wrangler.jsonc')))
		.map((dir) => ({
			dir: path.basename(dir),
			name: JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8')).name,
		}))
		.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))

	const map = new Map()
	workers.forEach((w, i) => map.set(w.name, BASE_PORT + i))
	return map
}

const upstreams = buildMap()

function upstreamPort(hostHeader) {
	if (!hostHeader) return null
	const host = hostHeader.split(':')[0].toLowerCase()
	// `<service>.rec.localhost` -> the service label is the worker name.
	return upstreams.get(host.split('.')[0]) ?? null
}

const tls = {
	key: fs.readFileSync(path.join(HERE, 'key.pem')),
	cert: fs.readFileSync(path.join(HERE, 'cert.pem')),
}

function notFound(res, host) {
	res.writeHead(404, { 'content-type': 'text/plain' })
	res.end(`no local RecFlare service for ${host ?? '(no host)'}\n`)
}

function makeServer() {
	const server = https.createServer(tls, (req, res) => {
		const port = upstreamPort(req.headers.host)
		if (!port) {
			console.log(`[proxy] 404 ${req.headers.host} ${req.method} ${req.url}`)
			return notFound(res, req.headers.host)
		}
		console.log(`[proxy] -> :${port} ${req.method} ${req.headers.host}${req.url}`)

		const proxied = http.request(
			{
				host: '127.0.0.1',
				port,
				method: req.method,
				path: req.url,
				// Preserve the client's Host (and every other header) so the worker builds
				// URLs against the same host the client is talking to.
				headers: req.headers,
			},
			(up) => {
				res.writeHead(up.statusCode || 502, up.headers)
				up.pipe(res)
			}
		)
		proxied.on('error', (err) => {
			console.log(`[proxy] upstream :${port} error: ${err.message}`)
			if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' })
			res.end(`upstream :${port} error: ${err.message}\n`)
		})
		req.pipe(proxied)
	})

	// SignalR / chat / match run over WebSockets; pipe the raw upgrade socket.
	server.on('upgrade', (req, socket, head) => {
		const port = upstreamPort(req.headers.host)
		if (!port) {
			console.log(`[proxy] 404 upgrade ${req.headers.host}`)
			socket.destroy()
			return
		}
		console.log(`[proxy] -> :${port} UPGRADE ${req.headers.host}${req.url}`)

		const up = net.connect(port, '127.0.0.1', () => {
			const lines = [`${req.method} ${req.url} HTTP/1.1`]
			for (let i = 0; i < req.rawHeaders.length; i += 2) {
				lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`)
			}
			up.write(lines.join('\r\n') + '\r\n\r\n')
			if (head?.length) up.write(head)
			socket.pipe(up)
			up.pipe(socket)
		})
		up.on('error', () => socket.destroy())
		socket.on('error', () => up.destroy())
	})

	return server
}

const PORTS = [LISTEN_PORT, 443]
const HOSTS = ['127.0.0.1', '::1']
console.log(`[proxy] repo: ${REPO}`)
for (const [name, port] of upstreams) console.log(`[proxy]   ${name} -> :${port}`)
for (const port of PORTS) {
	for (const host of HOSTS) {
		makeServer()
			.listen(port, host, () => console.log(`[proxy] listening on https://${host}:${port}`))
			.on('error', (err) => console.error(`[proxy] cannot listen on ${host}:${port}: ${err.code}`))
	}
}
