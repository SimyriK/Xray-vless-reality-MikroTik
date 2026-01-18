#Используем базовый образ с Alpine Linux для минимального размера
ARG ALPINE_VERSION=3.23
#--------------------------------Image--------------------------------
FROM alpine:${ALPINE_VERSION}
ARG TARGETARCH
RUN set -ex; \
    apk update && apk add --no-cache bash openrc openresolv iproute2 libqrencode p7zip wget dcron

#Tun2Socks
RUN mkdir -p /opt/tun2socks
COPY ./tun2socks/tun2socks-linux-${TARGETARCH}.7z /opt/tun2socks/tun2socks.7z
#Xray core
RUN mkdir -p /opt/xray/config/
COPY ./xray-core/Xray-linux-${TARGETARCH}.7z /opt/xray/xray.7z

COPY ./start.sh /opt/start.sh
COPY ./tcpraw.sh /opt/tcpraw.sh
COPY ./xhttp.sh /opt/xhttp.sh
COPY ./update_subscription.sh /opt/update_subscription.sh
RUN chmod +x /opt/start.sh /opt/tcpraw.sh /opt/xhttp.sh /opt/update_subscription.sh
RUN sed -i 's/\r//' /opt/start.sh /opt/tcpraw.sh /opt/xhttp.sh /opt/update_subscription.sh

RUN sed -i 's/^tty/#tty/' /etc/inittab
ENTRYPOINT ["sh", "-c"]
CMD ["/bin/bash /opt/start.sh && /sbin/init"]

#https://github.com/XTLS/Xray-core
#https://github.com/xjasonlyu/tun2socks