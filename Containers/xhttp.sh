#!/bin/sh

NETWORK=$(echo "$FULL_STRING" | sed "s/^.*type=//g" | sed "s/&.*$//g")
USER_ID=$(echo "$FULL_STRING" | sed "s/^.*:\/\/\(.*\)@.*$/\1/g" | sed "s/@.*$//g")
SERVER_ADDRESS=$(echo "$FULL_STRING" | sed "s/^.*@//g" | sed "s/?.*$//g" | sed "s/:.*$//g")
SERVER_PORT=$(echo "$FULL_STRING" | sed "s/^.*@//g" | sed "s/?.*$//g" | sed "s/^.*://g")
ENCRYPTION=$(echo "$FULL_STRING" | sed "s/^.*encryption=//g" | sed "s/&.*$//g")
# Если encryption не найден (параметр отсутствует в строке), для VLESS всегда none
if [ -z "$ENCRYPTION" ] || echo "$ENCRYPTION" | grep -q "^vless://"; then
  ENCRYPTION="none"
fi
FINGERPRINT_FP=$(echo "$FULL_STRING" | sed "s/^.*fp=//g" | sed "s/&.*$//g")
# Если fp не найден (параметр отсутствует в строке) или пустой, используем дефолт "chrome"
if [ -z "$FINGERPRINT_FP" ] || echo "$FINGERPRINT_FP" | grep -q "^vless://"; then
  FINGERPRINT_FP="chrome"
fi
SERVER_NAME_SNI=$(echo "$FULL_STRING" | sed "s/^.*sni=//g" | sed "s/&.*$//g")
# Если sni не найден (параметр отсутствует в строке), очищаем
if echo "$SERVER_NAME_SNI" | grep -q "^vless://"; then
  SERVER_NAME_SNI=""
fi
PUBLIC_KEY_PBK=$(echo "$FULL_STRING" | sed "s/^.*pbk=//g" | sed "s/&.*$//g")
# Если pbk не найден (параметр отсутствует в строке), очищаем
if echo "$PUBLIC_KEY_PBK" | grep -q "^vless://"; then
  PUBLIC_KEY_PBK=""
fi
SHORT_ID_SID=$(echo "$FULL_STRING" | sed "s/^.*sid=//g" | sed "s/&.*$//g")
# Если sid не найден (параметр отсутствует в строке), очищаем
if echo "$SHORT_ID_SID" | grep -q "^vless://"; then
  SHORT_ID_SID=""
fi
XHTTP_PATH=$(echo "$FULL_STRING" | sed "s/^.*path=//g" | sed "s/&.*$//g" | sed "s/%2F/\//g")
# Если path не найден (параметр отсутствует в строке), используем значение по умолчанию /
if [ -z "$XHTTP_PATH" ] || echo "$XHTTP_PATH" | grep -q "^vless://"; then
  XHTTP_PATH="/"
fi

echo "XHTTP config:"
echo "NETWORK: $NETWORK"
echo "USER_ID: $USER_ID"
echo "SERVER_ADDRESS: $SERVER_ADDRESS"
echo "SERVER_PORT: $SERVER_PORT"
echo "ENCRYPTION: $ENCRYPTION"
echo "FINGERPRINT_FP: $FINGERPRINT_FP"
echo "SERVER_NAME_SNI: $SERVER_NAME_SNI"
echo "PUBLIC_KEY_PBK: $PUBLIC_KEY_PBK"
echo "SHORT_ID_SID: $SHORT_ID_SID"
echo "XHTTP_PATH: $XHTTP_PATH"

cat <<EOF > /opt/xray/config/config.json
{
  "log": {
    "loglevel": "silent"
  },
  "inbounds": [
    {
      "port": 10800,
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": {
        "udp": true
      },
      "sniffing": {
        "enabled": false,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$SERVER_ADDRESS",
            "port": $SERVER_PORT,
            "users": [
              {
                "id": "$USER_ID",
                "encryption": "$ENCRYPTION"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "$NETWORK",
        "xhttpSettings": {
          "path": "$XHTTP_PATH"
        },
        "security": "reality",
        "realitySettings": {
          "fingerprint": "$FINGERPRINT_FP",
          "serverName": "$SERVER_NAME_SNI",
          "publicKey": "$PUBLIC_KEY_PBK",
          "shortId": "$SHORT_ID_SID"
        }
      },
      "tag": "proxy"
    }
  ]
}
EOF