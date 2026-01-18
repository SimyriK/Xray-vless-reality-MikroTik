#!/bin/sh

# Скрипт обновления подписки
# Запускается через cron для проверки и обновления конфигурации

SUBSCRIPTION_URL="$1"
SUBSCRIPTION_INDEX="$2"
CURRENT_FULL_STRING_FILE="/tmp/current_full_string.txt"

if [ -z "$SUBSCRIPTION_URL" ]; then
  echo "Usage: update_subscription.sh <SUBSCRIPTION_URL> <SUBSCRIPTION_INDEX>"
  exit 1
fi

SUBSCRIPTION_INDEX=${SUBSCRIPTION_INDEX:-1}

echo "[$(date)] Checking subscription for updates..."

# Определяем IP бриджа для маршрута к серверу подписки (если еще не определен)
if [ -z "$CONTAINER_BRIDGE_IP" ]; then
  CONTAINER_BRIDGE_IP=$(ip route | awk '/default/ { print $3 }' | head -n1)
  if [ -z "$CONTAINER_BRIDGE_IP" ]; then
    CONTAINER_BRIDGE_IP=$(arp -a | grep ether | awk -F'(' '{print $2}' | cut -d')' -f1 | head -n1)
  fi
fi

# Извлекаем домен из SUBSCRIPTION_URL и добавляем маршрут если нужно
SUBSCRIPTION_HOST=$(echo "$SUBSCRIPTION_URL" | sed 's|^https\?://||' | sed 's|^http://||' | sed 's|/.*$||')

if [ -n "$SUBSCRIPTION_HOST" ] && [ -n "$CONTAINER_BRIDGE_IP" ]; then
  SUBSCRIPTION_IP=$(ping -c 1 "$SUBSCRIPTION_HOST" 2>/dev/null | awk -F'[()]' '{print $2}' | head -n1)
  if [ -n "$SUBSCRIPTION_IP" ]; then
    # Убеждаемся что маршрут к серверу подписки существует (он должен оставаться постоянно)
    # Это нужно для обновления подписки даже при неработающем туннеле
    ip route del "$SUBSCRIPTION_IP"/32 via "$CONTAINER_BRIDGE_IP" 2>/dev/null
    ip route add "$SUBSCRIPTION_IP"/32 via "$CONTAINER_BRIDGE_IP" 2>/dev/null
  fi
fi

# Получаем новую конфигурацию из подписки
NEW_FULL_STRING=$(wget -qO- "$SUBSCRIPTION_URL" | base64 -d | grep "^vless://" | sed -n "${SUBSCRIPTION_INDEX}p" | tr -d '\r\n')

if [ -z "$NEW_FULL_STRING" ] || [ -z "$(echo "$NEW_FULL_STRING" | grep "^vless://")" ]; then
  echo "[$(date)] Failed to get configuration from subscription URL, skipping update"
  exit 1
fi

# Читаем текущую конфигурацию
if [ -f "$CURRENT_FULL_STRING_FILE" ]; then
  CURRENT_FULL_STRING=$(cat "$CURRENT_FULL_STRING_FILE")
else
  CURRENT_FULL_STRING=""
fi

# Сравниваем конфигурации
if [ "$NEW_FULL_STRING" = "$CURRENT_FULL_STRING" ]; then
  echo "[$(date)] Configuration unchanged, no update needed"
  exit 0
fi

echo "[$(date)] Configuration changed, updating..."

# Обновляем файл с текущей конфигурацией
echo "$NEW_FULL_STRING" > "$CURRENT_FULL_STRING_FILE"
export FULL_STRING="$NEW_FULL_STRING"

# Получаем сетевые параметры
SERVER_ADDRESS=$(echo "$NEW_FULL_STRING" | sed "s/^.*@//g" | sed "s/?type.*$//g" | sed "s/:.*$//g")

# Получаем старый IP сервера из текущей конфигурации
OLD_SERVER_ADDRESS=""
if [ -n "$CURRENT_FULL_STRING" ]; then
  OLD_SERVER_ADDRESS=$(echo "$CURRENT_FULL_STRING" | sed "s/^.*@//g" | sed "s/?type.*$//g" | sed "s/:.*$//g")
fi

# Определяем IP бриджа (используем ту же логику что и в start.sh)
if [ -z "$CONTAINER_BRIDGE_IP" ]; then
  CONTAINER_BRIDGE_IP=$(ip route | awk '/default/ { print $3 }' | head -n1)
  if [ -z "$CONTAINER_BRIDGE_IP" ]; then
    CONTAINER_BRIDGE_IP=$(arp -a | grep ether | awk -F'(' '{print $2}' | cut -d')' -f1 | head -n1)
  fi
fi

# Обновляем маршрут для нового сервера
SERVER_IP_ADDRESS=$(ping -c 1 "$SERVER_ADDRESS" 2>/dev/null | awk -F'[()]' '{print $2}')
if [ -n "$SERVER_IP_ADDRESS" ] && [ -n "$CONTAINER_BRIDGE_IP" ]; then
  # Удаляем старый маршрут, если сервер изменился
  if [ -n "$OLD_SERVER_ADDRESS" ] && [ "$OLD_SERVER_ADDRESS" != "$SERVER_ADDRESS" ]; then
    OLD_SERVER_IP=$(ping -c 1 "$OLD_SERVER_ADDRESS" 2>/dev/null | awk -F'[()]' '{print $2}')
    if [ -n "$OLD_SERVER_IP" ]; then
      ip route del "$OLD_SERVER_IP"/32 via "$CONTAINER_BRIDGE_IP" 2>/dev/null
      echo "[$(date)] Removed old route for $OLD_SERVER_ADDRESS ($OLD_SERVER_IP)"
    fi
  fi
  
  # Удаляем маршрут для нового сервера, если уже существует
  ip route del "$SERVER_IP_ADDRESS"/32 via "$CONTAINER_BRIDGE_IP" 2>/dev/null
  # Добавляем новый маршрут
  ip route add "$SERVER_IP_ADDRESS"/32 via "$CONTAINER_BRIDGE_IP" 2>/dev/null
  echo "[$(date)] Updated route for $SERVER_ADDRESS ($SERVER_IP_ADDRESS)"
fi

# Генерируем новый config.json
NETWORK=$(echo "$NEW_FULL_STRING" | sed "s/^.*type=//g" | sed "s/&.*$//g")
if [ "$NETWORK" = "tcp" ]; then
  /bin/sh /opt/tcpraw.sh
elif [ "$NETWORK" = "xhttp" ]; then
  /bin/sh /opt/xhttp.sh
else
  echo "[$(date)] Unsupported network type: $NETWORK, using tcp as fallback"
  /bin/sh /opt/tcpraw.sh
fi

# Перезапускаем Xray
echo "[$(date)] Restarting Xray..."
pkill xray
sleep 2

# Запускаем Xray с новой конфигурацией
/tmp/xray/xray run -config /opt/xray/config/config.json &

# Ждем пока Xray запустится
echo "[$(date)] Waiting for Xray SOCKS port 10800..."
for i in $(seq 1 10); do
  if nc -z 127.0.0.1 10800 2>/dev/null; then
    echo "[$(date)] Xray restarted successfully"
    break
  fi
  sleep 1
done

if ! nc -z 127.0.0.1 10800 2>/dev/null; then
  echo "[$(date)] Warning: Xray port 10800 is not responding after update"
fi