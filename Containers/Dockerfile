#Используем базовый образ с Alpine Linux для минимального размера
ARG ALPINE_VERSION=3.23
ARG TARGETARCH
ARG HEV_VERSION=

FROM alpine:${ALPINE_VERSION} AS builder
ARG TARGETARCH
ARG HEV_VERSION

RUN apk add --no-cache p7zip unzip wget ca-certificates

WORKDIR /build
COPY fetch-binaries.sh /build/fetch-binaries.sh
COPY xray-core/ /build/xray-core/
COPY hev/ /build/hev/

RUN chmod +x /build/fetch-binaries.sh \
    && TARGETARCH="${TARGETARCH}" HEV_VERSION="${HEV_VERSION}" /build/fetch-binaries.sh


FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.title="xray-mikrotik" \
      org.opencontainers.image.description="Xray VLESS Reality + hev-socks5-tunnel для MikroTik RouterOS" \
      org.opencontainers.image.source="https://github.com/SimyriK/Xray-vless-reality-MikroTik" \
      org.opencontainers.image.documentation="https://github.com/SimyriK/Xray-vless-reality-MikroTik" \
      org.opencontainers.image.vendor="simyrik"

RUN apk add --no-cache iproute2 ca-certificates wget dcron

COPY --from=builder /out/xray /usr/local/bin/xray
COPY --from=builder /out/hev-socks5-tunnel /usr/local/bin/hev-socks5-tunnel

RUN mkdir -p /opt/xray/config

COPY start.sh /opt/start.sh
COPY tcpraw.sh /opt/tcpraw.sh
COPY xhttp.sh /opt/xhttp.sh
COPY update_subscription.sh /opt/update_subscription.sh
COPY hev-socks5-tunnel.yml /opt/hev-socks5-tunnel.yml

RUN chmod +x \
      /usr/local/bin/xray \
      /usr/local/bin/hev-socks5-tunnel \
      /opt/start.sh \
      /opt/tcpraw.sh \
      /opt/xhttp.sh \
      /opt/update_subscription.sh \
    && sed -i 's/\r//' \
      /opt/start.sh \
      /opt/tcpraw.sh \
      /opt/xhttp.sh \
      /opt/update_subscription.sh \
      /opt/hev-socks5-tunnel.yml

ENTRYPOINT ["/bin/sh", "/opt/start.sh"]

# https://github.com/XTLS/Xray-core
# https://github.com/heiher/hev-socks5-tunnel
