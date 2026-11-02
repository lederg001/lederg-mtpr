# LEDERG Telegram WEB Proxy

Docker deployment package for Render. It builds the official [`telegramdesktop/tproxy-server`](https://github.com/telegramdesktop/tproxy-server) relay and the official Telegram MTProxy backend from pinned upstream revisions. Caddy is the only process exposed on Render's HTTP port; the relay and MTProxy backend remain on loopback.

> **Compatibility:** this is Telegram's experimental WEB Proxy protocol, not a regular MTProto proxy URL. The upstream project describes a proof of concept. A compatible Telegram client with the WEB Proxy adapter is required; standard Telegram clients that only support ordinary MTProto/SOCKS proxies cannot use this server just by entering its hostname.

## Deploy to Render

1. Open Render and create **New → Web Service**.
2. Connect `https://github.com/lederg001/lederg-mtpr` and select branch `main`.
3. Choose **Docker** runtime, **Frankfurt** region, and the **Free** plan.
4. Leave the Dockerfile path as `./Dockerfile` and the health-check path as `/`.
5. Add these environment variables:

| Key | Value |
|---|---|
| `WEB_PROXY_SECRET` | 32 lowercase hexadecimal characters (16 random bytes), optionally prefixed with `dd` |
| `CARRIER_MODE` | `websocket` |
| `MTPROXY_MAX_CONNECTIONS` | `512` |

Generate a secret on your computer with Python:

```bash
python -c "import secrets; print(secrets.token_hex(16))"
```

Copy the output into `WEB_PROXY_SECRET` in Render. Keep it private; do not commit it to GitHub or paste it into public chats. `PUBLIC_HOSTNAME` is optional: the container automatically uses Render's `RENDER_EXTERNAL_HOSTNAME`. After attaching a custom domain, set `PUBLIC_HOSTNAME` to that exact lowercase hostname (no `https://`, port, or path), then redeploy.

6. Click **Create Web Service**. Render builds the Docker image, runs upstream Go tests during the build, then starts MTProxy, the relay, and Caddy.

## Proxy details

For a client that implements Telegram WEB Proxy, enter:

- **Server:** the `onrender.com` hostname (or custom domain) shown by Render.
- **Secret:** the exact value stored in `WEB_PROXY_SECRET`.

The link/connection format depends on the compatible client. The relay binds the capability to the configured hostname, so the hostname entered in the client must match `PUBLIC_HOSTNAME`.

## Important Render Free limitations

- Free web services can spin down after inactivity and take time to wake up. Long-lived proxy sessions are interrupted by restarts, deploys, or spin-down.
- The free instance has limited memory/CPU. This package lowers the relay's in-memory session and stream caps for a small test deployment; it is not tuned for heavy public traffic.
- Render exposes one public HTTP port, not an arbitrary inbound TCP port. This design carries client traffic over HTTPS/WebSocket and keeps the MTProxy backend private inside the same container.
- The container filesystem is ephemeral. The shared secret remains stable because it is stored in Render environment variables; active sessions and the relay token key are recreated on restart.
- A health check at `/` only verifies that the public gateway responds. It does not guarantee that Telegram's upstream datacenters are reachable.

## Local Docker test

```bash
docker build -t lederg-web-proxy .
docker run --rm -p 10000:10000 \
  -e PORT=10000 \
  -e PUBLIC_HOSTNAME=localhost.example \
  -e WEB_PROXY_SECRET=0123456789abcdef0123456789abcdef \
  lederg-web-proxy
```

`localhost.example` is only a local hostname placeholder; use your real assigned host in Render.

## Upstream projects and pinning

- Relay: [`telegramdesktop/tproxy-server`](https://github.com/telegramdesktop/tproxy-server), commit `c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8`.
- Backend: [`TelegramMessenger/MTProxy`](https://github.com/TelegramMessenger/MTProxy), commit `f36d8af769ffaeac36978d38c2c0f6d1104c2137`; its source archive is checksum-verified during the Docker build.
- Gateway: [Caddy](https://github.com/caddyserver/caddy), version `2.11.4`; its archive is checksum-verified during the Docker build.

The upstream relay source is fetched during Docker build rather than copied into this repository. Read the upstream project documentation for its protocol, security model, and client requirements before offering this node to other users.
