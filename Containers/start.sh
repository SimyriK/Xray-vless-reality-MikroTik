#!/bin/sh
echo "Starting setup container please wait"
sleep 1

# Нужно для маршрутизации через tun0 и корректной работы UDP (Discord voice/RTC)
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true

# Volatile-файлы (hev.yml, current_full_string, лог cron) — в RUNTIME_DIR или /tmp
runtimeDir="${RUNTIME_DIR:-/tmp}"
mkdir -p "${runtimeDir}"

# Определяем IP бриджа один раз в начале скрипта
# (будет использоваться для маршрутов к серверу подписки и серверу Xray)
if [ -n "$CONTAINER_BRIDGE_IP" ]; then
  echo "Using CONTAINER_BRIDGE_IP from environment: $CONTAINER_BRIDGE_IP"
else
  sleep 5
  # Сначала пробуем через ip route (более надежно, работает до изменения маршрутов)
  CONTAINER_BRIDGE_IP=$(ip route | awk '/default/ { print $3 }' | head -n1)
  # Если не получилось, пробуем через ARP
  if [ -z "$CONTAINER_BRIDGE_IP" ]; then
    CONTAINER_BRIDGE_IP=$(arp -a | grep ether | awk -F'(' '{print $2}' | cut -d')' -f1 | head -n1)
  fi
fi

# Если указан SUBSCRIPTION_URL, получаем конфиг из подписки
# Для этого добавляем прямой маршрут до сервера подписки через основной шлюз
if [ -n "$SUBSCRIPTION_URL" ]; then
  echo "Fetching configuration from subscription URL..."

  # Извлекаем домен из SUBSCRIPTION_URL (убираем протокол и путь)
  SUBSCRIPTION_HOST=$(echo "$SUBSCRIPTION_URL" | sed 's|^https\?://||' | sed 's|^http://||' | sed 's|/.*$||')

  if [ -n "$SUBSCRIPTION_HOST" ] && [ -n "$CONTAINER_BRIDGE_IP" ]; then
    # Резолвим IP адрес сервера подписки
    SUBSCRIPTION_IP=$(ping -c 1 "$SUBSCRIPTION_HOST" 2>/dev/null | awk -F'[()]' '{print $2}' | head -n1)

    if [ -n "$SUBSCRIPTION_IP" ]; then
      # Добавляем маршрут до сервера подписки через основной шлюз
      # Маршрут оставляем постоянно для обновления подписки даже при неработающем туннеле
      echo "Adding route to subscription server $SUBSCRIPTION_HOST ($SUBSCRIPTION_IP) via $CONTAINER_BRIDGE_IP"
      # Удаляем маршрут если уже существует, затем добавляем заново (на случай изменения CONTAINER_BRIDGE_IP)
      ip route del "$SUBSCRIPTION_IP"/32 via "$CONTAINER_BRIDGE_IP" 2>/dev/null
      ip route add "$SUBSCRIPTION_IP"/32 via "$CONTAINER_BRIDGE_IP" 2>/dev/null

      # Небольшая задержка для установления маршрута
      sleep 2
    fi
  fi

  # Получаем конфигурацию из подписки
  SUBSCRIPTION_INDEX=${SUBSCRIPTION_INDEX:-1}
  FULL_STRING=$(wget -qO- "$SUBSCRIPTION_URL" | base64 -d | grep "^vless://" | sed -n "${SUBSCRIPTION_INDEX}p" | tr -d '\r\n')
  if [ -z "$FULL_STRING" ] || [ -z "$(echo "$FULL_STRING" | grep "^vless://")" ]; then
    echo "Failed to get configuration #$SUBSCRIPTION_INDEX from subscription URL or invalid format"
    exit 1
  fi
  echo "Using configuration #$SUBSCRIPTION_INDEX from subscription"
  # Сохраняем текущую конфигурацию для сравнения в скрипте обновления
  echo "$FULL_STRING" > "${runtimeDir}/current_full_string.txt"
  # Экспортируем FULL_STRING для дочерних скриптов
  export FULL_STRING
fi

# Если FULL_STRING не задан, проверяем отдельные переменные (старый способ)
if [ -z "$FULL_STRING" ]; then
  if [ -n "$SERVER_ADDRESS" ] && [ -n "$SERVER_PORT" ] && [ -n "$ID" ]; then
    echo "Using legacy configuration with individual variables"
    # Собираем FULL_STRING из отдельных переменных
    NETWORK_TYPE=${TYPE:-tcp}
    ENCRYPTION_VAL=${ENCRYPTION:-none}
    FLOW_VAL=${FLOW:-}
    FP_VAL=${FP:-}
    SNI_VAL=${SNI:-}
    PBK_VAL=${PBK:-}
    SID_VAL=${SID:-}
    SPX_VAL=${SPX:-}
    PQV_VAL=${PQV:-}

    # Формируем базовую строку
    FULL_STRING="vless://${ID}@${SERVER_ADDRESS}:${SERVER_PORT}?type=${NETWORK_TYPE}&encryption=${ENCRYPTION_VAL}&security=reality"

    # Добавляем опциональные параметры
    [ -n "$FP_VAL" ] && FULL_STRING="${FULL_STRING}&fp=${FP_VAL}"
    [ -n "$SNI_VAL" ] && FULL_STRING="${FULL_STRING}&sni=${SNI_VAL}"
    [ -n "$PBK_VAL" ] && FULL_STRING="${FULL_STRING}&pbk=${PBK_VAL}"
    [ -n "$SID_VAL" ] && FULL_STRING="${FULL_STRING}&sid=${SID_VAL}"
    [ -n "$SPX_VAL" ] && FULL_STRING="${FULL_STRING}&spx=${SPX_VAL}"
    [ -n "$PQV_VAL" ] && FULL_STRING="${FULL_STRING}&pqv=${PQV_VAL}"
    [ -n "$FLOW_VAL" ] && FULL_STRING="${FULL_STRING}&flow=${FLOW_VAL}"

    echo "Generated FULL_STRING from individual variables"
    # Экспортируем FULL_STRING для дочерних скриптов
    export FULL_STRING
  else
    echo "Error: Either FULL_STRING, SUBSCRIPTION_URL, or individual variables (SERVER_ADDRESS, SERVER_PORT, ID) must be set"
    exit 1
  fi
fi

# Интерфейс контейнера (veth) — не lo и не tun
NET_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|tun' | head -n1 | cut -d'@' -f1)
CONTAINER_IP=$(ip -4 addr show "${NET_IFACE}" | grep inet | awk '{ print $2 }' | cut -d/ -f1)

sleep 15

# Обновляем /etc/hosts для tcpraw/xhttp (xray-vless → IP контейнера)
HOST_STRING=$(sed -n '/xray-vless/=' /etc/hosts)
if [ -n "$HOST_STRING" ]; then
  sed -r -i "$HOST_STRING c\\$CONTAINER_IP xray-vless" /etc/hosts
fi

# Резолвим FQDN сервера Xray через DNS роутера (CONTAINER_BRIDGE_IP)
SERVER_ADDRESS=$(echo "$FULL_STRING" | sed "s/^.*@//g" | sed "s/?type.*$//g" | sed "s/:.*$//g")
SERVER_IP_ADDRESS=$(ping -c 1 "$SERVER_ADDRESS" | awk -F'[()]' '{print $2}')

if [ -z "$SERVER_IP_ADDRESS" ]; then
  echo "Failed to obtain an IP address for FQDN $SERVER_ADDRESS"
  echo "Please configure DNS on Mikrotik (add rule in IP - Firewall - Filter Rules):"
  echo "Chain: input Dst Address: <docker_bridge_address> Protocol: udp Dst. Port: 53 Action: accept"
  exit 1
fi

# Очищаем остатки от предыдущего запуска (tun2socks / hev)
ip route del default dev tun0 2>/dev/null || true
ip route del default via 172.31.200.9 2>/dev/null || true
ip tuntap del mode tun dev tun0 2>/dev/null || true

# До запуска hev default должен идти через veth → бридж роутера
# (нужен для DNS, ping сервера Xray и маршрута к серверу подписки)
if ! ip route | awk '/^default /{found=1} END{exit !found}'; then
  ip route add default via "$CONTAINER_BRIDGE_IP" dev "$NET_IFACE" 2>/dev/null || true
fi
# Трафик к серверу Xray — напрямую через бридж, минуя tun0
ip route del "$SERVER_IP_ADDRESS"/32 via "$CONTAINER_BRIDGE_IP" 2>/dev/null || true
ip route add "$SERVER_IP_ADDRESS"/32 via "$CONTAINER_BRIDGE_IP" dev "$NET_IFACE" 2>/dev/null || true

# ARP для корректной работы маршрута через veth
sysctl -w "net.ipv4.conf.${NET_IFACE}.arp_ignore=0" 2>/dev/null || true
sysctl -w "net.ipv4.conf.${NET_IFACE}.arp_announce=0" 2>/dev/null || true

# hev подключается к SOCKS Xray; SOCKS_LISTEN=127.0.0.1 — только localhost
export SOCKS_LISTEN="${SOCKS_LISTEN:-127.0.0.1}"
socksPort="${XRAY_SOCKS_PORT:-10800}"
hevMtu="${HEV_MTU:-8500}"
hevLog="${HEV_LOG_LEVEL:-warn}"

# DNS через роутер (бридж контейнеров)
rm -f /etc/resolv.conf
echo "nameserver $CONTAINER_BRIDGE_IP" >> /etc/resolv.conf
#tee -a /etc/resolv.conf <<< "nameserver 1.0.0.1"
#tee -a /etc/resolv.conf <<< "nameserver 8.8.4.4"

# Генерируем config.json Xray из FULL_STRING (tcpraw или xhttp)
NETWORK=$(echo "$FULL_STRING" | sed "s/^.*type=//g" | sed "s/&.*$//g")
# Экспортируем FULL_STRING для дочерних скриптов
export FULL_STRING
if [ "$NETWORK" = "tcp" ]; then
  /bin/sh /opt/tcpraw.sh
elif [ "$NETWORK" = "xhttp" ]; then
  /bin/sh /opt/xhttp.sh
else
  echo "Unsupported network type: $NETWORK. Using tcp as fallback."
  /bin/sh /opt/tcpraw.sh
fi

echo "Start Xray core"
/usr/local/bin/xray run -config /opt/xray/config/config.json &
XRAY_PID=$!

# Ждём пока Xray поднимет SOCKS — hev без него не стартует
echo "Waiting for Xray SOCKS port ${socksPort} on ${SOCKS_LISTEN}..."
for i in $(seq 1 15); do
  if nc -z "${SOCKS_LISTEN}" "${socksPort}" 2>/dev/null; then
    echo "SOCKS port is up!"
    break
  fi
  echo "Port Xray not ready, retrying..."
  sleep 1
done

# Генерируем конфиг hev из шаблона (плейсхолдеры → env)
sed \
  -e "s/__SOCKS_PORT__/${socksPort}/g" \
  -e "s/__SOCKS_ADDRESS__/${SOCKS_LISTEN}/g" \
  -e "s/__HEV_MTU__/${hevMtu}/g" \
  -e "s/__HEV_LOG__/${hevLog}/g" \
  /opt/hev-socks5-tunnel.yml > "${runtimeDir}/hev.yml"

echo "Start hev-socks5-tunnel via socks5://${SOCKS_LISTEN}:${socksPort}"
/usr/local/bin/hev-socks5-tunnel "${runtimeDir}/hev.yml" &
HEV_PID=$!
sleep 3

# hev сам создаёт tun0; если не создал — что-то пошло не так
if ! ip link show tun0 >/dev/null 2>&1; then
  echo "hev-socks5-tunnel failed to create tun0 (see container log)"
  exit 1
fi

# Весь остальной трафик — через tun0 → SOCKS → Xray
ip route replace default dev tun0
echo "Container startup complete (default route: dev tun0)"

# Настраиваем cron для автоматического обновления подписки, если указан SUBSCRIPTION_URL
CRON_PID=""
if [ -n "$SUBSCRIPTION_URL" ] && [ -n "$SUBSCRIPTION_UPDATE_INTERVAL" ]; then
  SUBSCRIPTION_INDEX=${SUBSCRIPTION_INDEX:-1}
  UPDATE_INTERVAL_HOURS=${SUBSCRIPTION_UPDATE_INTERVAL}

  # Лог обновления подписки
  CRON_LOG="${runtimeDir}/subscription_update.log"

  # Формируем cron расписание: каждые N часов или раз в сутки
  if [ "$UPDATE_INTERVAL_HOURS" -ge 24 ]; then
    CRON_SCHEDULE="0 0 * * *"
  else
    CRON_SCHEDULE="0 */${UPDATE_INTERVAL_HOURS} * * *"
  fi

  # Добавляем задачу в crontab
  echo "${CRON_SCHEDULE} /bin/sh /opt/update_subscription.sh \"${SUBSCRIPTION_URL}\" ${SUBSCRIPTION_INDEX} >> ${CRON_LOG} 2>&1" | crontab -

  echo "Subscription updater configured via cron. Update interval: ${UPDATE_INTERVAL_HOURS} hours"
  echo "Cron schedule: ${CRON_SCHEDULE}"

  # Запускаем cron
  crond -f -l 2 &
  CRON_PID=$!
fi

# Держим контейнер живым — ждём основные процессы
if [ -n "$CRON_PID" ]; then
  wait "$XRAY_PID" "$HEV_PID" "$CRON_PID"
else
  wait "$XRAY_PID" "$HEV_PID"
fi
