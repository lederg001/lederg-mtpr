FROM golang:1.26.5-bookworm AS relay-build
ARG TPROXY_SERVER_COMMIT=c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/telegramdesktop/tproxy-server.git /src/tproxy-server \
    && git -C /src/tproxy-server checkout --detach "${TPROXY_SERVER_COMMIT}" \
    && cd /src/tproxy-server && mkdir -p /out \
    && go test ./... \
    && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/tproxy-server ./cmd/tproxy-server

FROM debian:bookworm-slim AS mtproxy-build
ARG MTPROXY_COMMIT=f36d8af769ffaeac36978d38c2c0f6d1104c2137
ARG MTPROXY_SHA256=919795c416b870670841a21d1930ad97a24c7b84b9eb8c6f9e3de32f2fdf4655
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl build-essential libssl-dev zlib1g-dev tar \
    && rm -rf /var/lib/apt/lists/* \
    && curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
       --output /tmp/MTProxy.tar.gz "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz" \
    && echo "${MTPROXY_SHA256}  /tmp/MTProxy.tar.gz" | sha256sum -c - \
    && mkdir -p /src/MTProxy \
    && tar -C /src/MTProxy --strip-components=1 -xzf /tmp/MTProxy.tar.gz \
    && make -C /src/MTProxy -j2 \
    && test -x /src/MTProxy/objs/bin/mtproto-proxy

FROM debian:bookworm-slim AS caddy-build
ARG CADDY_VERSION=2.11.4
ARG CADDY_SHA512=8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl tar \
    && rm -rf /var/lib/apt/lists/* \
    && curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
       --output /tmp/caddy.tar.gz "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" \
    && echo "${CADDY_SHA512}  /tmp/caddy.tar.gz" | sha512sum -c - \
    && mkdir -p /out && tar -C /out -xzf /tmp/caddy.tar.gz caddy \
    && test -x /out/caddy

FROM debian:bookworm-slim
ENV PORT=10000
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl iproute2 libssl3 util-linux zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home /nonexistent --shell /usr/sbin/nologin mtproxy \
    && useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy \
    && mkdir -p /app/site /tmp/tproxy /tmp/mtproxy
COPY --from=relay-build /out/tproxy-server /usr/local/bin/tproxy-server
COPY --from=mtproxy-build /src/MTProxy/objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
COPY --from=caddy-build /out/caddy /usr/local/bin/caddy
COPY start.sh /app/start.sh
COPY Caddyfile /app/Caddyfile
COPY site/ /app/site/
RUN chmod 0755 /app/start.sh /usr/local/bin/tproxy-server /usr/local/bin/mtproto-proxy /usr/local/bin/caddy \
    && chmod 0755 /app /app/site
EXPOSE 10000
ENTRYPOINT ["/app/start.sh"]
