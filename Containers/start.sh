#!/bin/sh
echo "Starting setup container please wait"
sleep 1

# Определяем IP бриджа один раз в начале скрипта (будет использоваться для маршрутов к серверу подписки и серверу Xray)
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
  echo "$FULL_STRING" > /tmp/current_full_string.txt
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

NET_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|tun' | head -n1 | cut -d'@' -f1)
CONTAINER_IP=$(ip -4 addr show $NET_IFACE | grep inet | awk '{ print $2 }' | cut -d/ -f1)

sleep 15

HOST_STRING=$(sed -n '/xray-vless/=' /etc/hosts)
if [ ! -z "$HOST_STRING" ]; then
  sed -r -i "$HOST_STRING c\\$CONTAINER_IP xray-vless" /etc/hosts
fi

SERVER_ADDRESS=$(echo "$FULL_STRING" | sed "s/^.*@//g" | sed "s/?type.*$//g" | sed "s/:.*$//g")
SERVER_IP_ADDRESS=$(ping -c 1 "$SERVER_ADDRESS" | awk -F'[()]' '{print $2}')

if [ -z "$SERVER_IP_ADDRESS" ]; then
  echo "Failed to obtain an IP address for FQDN $SERVER_ADDRESS"
  echo "Please configure DNS on Mikrotik (add rule in IP - Firewall - Filter Rules):"
  echo "Chain: input Dst Address: <docker_bridge_address> Protocol: udp Dst. Port: 53 Action: accept"
  exit 1
fi

ip tuntap del mode tun dev tun0
ip tuntap add mode tun dev tun0
ip addr add 172.31.200.10/30 dev tun0
ip link set dev tun0 up
ip route del default via "$CONTAINER_BRIDGE_IP" 2>/dev/null
ip route add default via 172.31.200.9
ip route add "$SERVER_IP_ADDRESS"/32 via "$CONTAINER_BRIDGE_IP"
#ip route add 1.0.0.1/32 via "$CONTAINER_BRIDGE_IP"
#ip route add 8.8.4.4/32 via "$CONTAINER_BRIDGE_IP"

rm -f /etc/resolv.conf
tee -a /etc/resolv.conf <<< "nameserver $CONTAINER_BRIDGE_IP"
#tee -a /etc/resolv.conf <<< "nameserver 1.0.0.1"
#tee -a /etc/resolv.conf <<< "nameserver 8.8.4.4"

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
echo "Xray and tun2socks preparing for launch"
rm -rf /tmp/xray/ && mkdir /tmp/xray/
7z x /opt/xray/xray.7z -o/tmp/xray/ -y
chmod 755 /tmp/xray/xray
rm -rf /tmp/tun2socks/ && mkdir /tmp/tun2socks/
7z x /opt/tun2socks/tun2socks.7z -o/tmp/tun2socks/ -y
chmod 755 /tmp/tun2socks/tun2socks
echo "Start Xray core"
/tmp/xray/xray run -config /opt/xray/config/config.json &
#pkill xray
echo "Waiting for Xray SOCKS port 10800..."
for i in $(seq 1 10); do
    if nc -z 127.0.0.1 10800 2>/dev/null; then
        echo "SOCKS port is up!"
        break
    fi
    echo "Port Xray not ready, retrying..."
    sleep 1
done
echo "Start tun2socks"
/tmp/tun2socks/tun2socks -loglevel silent -tcp-sndbuf 3m -tcp-rcvbuf 3m -device tun0 -proxy socks5://127.0.0.1:10800 -interface $NET_IFACE &
#pkill tun2socks
echo "Container customization is complete"

# Настраиваем cron для автоматического обновления подписки, если указан SUBSCRIPTION_URL
if [ -n "$SUBSCRIPTION_URL" ] && [ -n "$SUBSCRIPTION_UPDATE_INTERVAL" ]; then
  SUBSCRIPTION_INDEX=${SUBSCRIPTION_INDEX:-1}
  UPDATE_INTERVAL_HOURS=${SUBSCRIPTION_UPDATE_INTERVAL}
  
  # Создаем crontab файл для периодического обновления
  CRON_LOG="/var/log/subscription_update.log"
  
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
fi
