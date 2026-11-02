#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

log() { printf '[LEDERG-WEB-PROXY] %s\n' "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

if [[ -z "${PORT:-}" ]]; then PORT=10000; fi
if [[ -z "${PUBLIC_HOSTNAME:-}" ]]; then PUBLIC_HOSTNAME="${RENDER_EXTERNAL_HOSTNAME:-}"; fi
if [[ -z "${WEB_PROXY_SECRET:-}" ]]; then WEB_PROXY_SECRET=""; fi
if [[ -z "${CARRIER_MODE:-}" ]]; then CARRIER_MODE=websocket; fi
if [[ -z "${MTPROXY_MAX_CONNECTIONS:-}" ]]; then MTPROXY_MAX_CONNECTIONS=512; fi

[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || fail 'PORT must be a valid TCP port.'
[[ "$PUBLIC_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || \
  fail 'Set PUBLIC_HOSTNAME to the lowercase Render hostname or attached custom domain.'
WEB_PROXY_SECRET="$(printf '%s' "$WEB_PROXY_SECRET" | tr 'A-F' 'a-f')"
[[ "$WEB_PROXY_SECRET" =~ ^(dd)?[0-9a-f]{32}$ ]] || \
  fail 'WEB_PROXY_SECRET must be 32 hex characters, optionally prefixed with dd.'
case "$CARRIER_MODE" in
  https|https-lanes|websocket|websocket-lanes) ;;
  *) fail 'CARRIER_MODE must be https, https-lanes, websocket, or websocket-lanes.' ;;
esac
[[ "$MTPROXY_MAX_CONNECTIONS" =~ ^[1-9][0-9]*$ ]] || fail 'MTPROXY_MAX_CONNECTIONS must be a positive integer.'

mkdir -p /tmp/tproxy /tmp/mtproxy
chmod 0700 /tmp/tproxy /tmp/mtproxy
log 'Downloading Telegram MTProxy routing data.'
curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 --max-time 45 \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --output /tmp/mtproxy/proxy-secret https://core.telegram.org/getProxySecret
curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 --max-time 45 \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --output /tmp/mtproxy/proxy-multi.conf https://core.telegram.org/getProxyConfig
[[ "$(wc -c < /tmp/mtproxy/proxy-secret)" -eq 128 ]] || fail 'Telegram MTProxy secret download has an unexpected size.'
grep -q '^default ' /tmp/mtproxy/proxy-multi.conf || fail 'Telegram MTProxy routing configuration is invalid.'
grep -q '^proxy_for ' /tmp/mtproxy/proxy-multi.conf || fail 'Telegram MTProxy routing configuration is incomplete.'
chown -R mtproxy:mtproxy /tmp/mtproxy

BACKEND_SECRET="$(printf '%s' "$WEB_PROXY_SECRET" | sed 's/^dd//')"
printf '{"profiles":[{"name":"default","secret":"%s","backend":"127.0.0.1:2398","carrier_mode":"%s"}]}\n' \
  "$WEB_PROXY_SECRET" "$CARRIER_MODE" > /tmp/tproxy/profiles.json
head -c 32 /dev/urandom > /tmp/tproxy/token.key
chmod 0400 /tmp/tproxy/token.key

cat > /tmp/tproxy/config.json <<JSON
{
  "public_hostname": "$PUBLIC_HOSTNAME",
  "base_path": "",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
  "public_dir": "/app/site",
  "token_key_file": "/tmp/tproxy/token.key",
  "static_routes": "exact",
  "profiles_file": "/tmp/tproxy/profiles.json",
  "enable_pprof": false,
  "limits": {
    "max_header_bytes": 16384,
    "max_body_bytes": 2097152,
    "max_frame_payload": 1048576,
    "carrier_batch_bytes": 1048576,
    "max_streams_per_session": 64,
    "max_closed_stream_ids": 1024,
    "max_pending_per_session": 8388608,
    "max_pending_global": 67108864,
    "max_pending_items_per_session": 4096,
    "max_pending_items_global": 16384,
    "max_sessions_per_ip": 0,
    "max_sessions_global": 8,
    "max_streams_global": 256,
    "max_backend_dials_in_flight": 32,
    "new_sessions_per_minute": 60,
    "new_sessions_burst": 16,
    "new_streams_per_minute": 600,
    "new_streams_burst": 64,
    "max_bootstraps_per_ip": 0,
    "max_bootstraps_global": 32,
    "new_bootstraps_per_minute": 120,
    "new_bootstraps_burst": 32,
    "max_profiles": 1
  }
}
JSON
chown -R tproxy:tproxy /tmp/tproxy
chmod 0600 /tmp/tproxy/config.json /tmp/tproxy/profiles.json
/usr/local/bin/tproxy-server -config /tmp/tproxy/config.json -check

LOCAL_IP="$(ip -4 route get 149.154.175.50 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
PUBLIC_IP=""
for probe in https://api.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
  PUBLIC_IP="$(curl --fail --silent --show-error --location --ipv4 --max-time 12 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 "$probe" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
  PUBLIC_IP=""
done
MT_PROXY_NAT_ARGS=""
if [[ -n "$LOCAL_IP" && -n "$PUBLIC_IP" && "$LOCAL_IP" != "$PUBLIC_IP" ]]; then
  MT_PROXY_NAT_ARGS="--nat-info $LOCAL_IP:$PUBLIC_IP"
  log 'Detected container NAT; configuring MTProxy NAT translation.'
else
  log 'WARNING: egress NAT address could not be confirmed; MTProxy connectivity may fail.'
fi

log 'Starting official MTProxy backend on loopback.'
# MT_PROXY_NAT_ARGS is intentionally word-split to supply zero or two argv values.
# shellcheck disable=SC2086
/usr/local/bin/mtproto-proxy -u mtproxy -p 8888 -H 2398 -S "$BACKEND_SECRET" \
  $MT_PROXY_NAT_ARGS --aes-pwd /tmp/mtproxy/proxy-secret /tmp/mtproxy/proxy-multi.conf \
  -M 1 -C "$MTPROXY_MAX_CONNECTIONS" &
MTPROXY_PID=$!

log 'Starting WEB proxy relay.'
runuser -u tproxy -- /usr/local/bin/tproxy-server -config /tmp/tproxy/config.json &
TPROXY_PID=$!

CADDY_PID=""
cleanup() {
  log 'Stopping proxy processes.'
  if [[ -n "$CADDY_PID" ]]; then kill "$CADDY_PID" 2>/dev/null || true; fi
  kill "$TPROXY_PID" "$MTPROXY_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' TERM INT

READY=""
for _ in $(seq 1 40); do
  if curl --fail --silent --output /dev/null http://127.0.0.1:8081/healthz; then
    READY=1
    break
  fi
  kill -0 "$TPROXY_PID" 2>/dev/null || fail 'WEB proxy relay exited during startup.'
  sleep 1
done
[[ -n "$READY" ]] || fail 'WEB proxy relay did not become healthy.'

log "Starting public HTTP gateway on 0.0.0.0:$PORT; hostname=$PUBLIC_HOSTNAME."
/usr/local/bin/caddy run --config /app/Caddyfile --adapter caddyfile &
CADDY_PID=$!
wait -n "$CADDY_PID" "$TPROXY_PID" "$MTPROXY_PID"
