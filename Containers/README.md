# simyrik/xray-mikrotik

Slim-образ **Xray VLESS Reality** для контейнеров **MikroTik RouterOS 7.4+**.  
Трафик с роутера уходит через **Xray** → **hev-socks5-tunnel** (TUN). UDP/WebRTC (Discord voice и т.п.) работает корректнее, чем со старым tun2socks.

**Полная инструкция:** [GitHub — SimyriK/Xray-vless-reality-MikroTik](https://github.com/SimyriK/Xray-vless-reality-MikroTik)

---

## Особенности

- Multi-arch: **linux/arm/v7**, **linux/arm64**, **linux/amd64**
- Multi-stage сборка на Alpine (~**19 MB** сжатый образ)
- [Xray-core](https://github.com/XTLS/Xray-core) — актуальный релиз при сборке
- [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) вместо tun2socks
- Конфиг из **FULL_STRING**, **SUBSCRIPTION_URL** или отдельных переменных
- Транспорты **tcp** и **xhttp**
- Автообновление подписки (cron, опционально)

---

## Быстрый старт на MikroTik

1. Включите контейнеры, настройте veth, маршрутизацию и env-список `xvr` — см. [README на GitHub](https://github.com/SimyriK/Xray-vless-reality-MikroTik) или мастер:

```
/tool/fetch url="https://raw.githubusercontent.com/SimyriK/Xray-vless-reality-MikroTik/main/xray-container-setup.rsc" dst-path="xray-setup.rsc"; /import file-name="xray-setup.rsc"
```

2. Добавьте контейнер (пример):

```
/container add hostname=xray-vless interface=docker-xray-vless-veth envlist=xvr root-dir=xray-vless logging=no start-on-boot=yes remote-image=simyrik/xray-mikrotik:latest
/container start [find interface=docker-xray-vless-veth]
```

Docker Hub подберёт образ под архитектуру роутера (ARM / ARM64 / x86).

---

## Переменные окружения (список `xvr`)

**Один из способов конфигурации:**

| Способ | Переменные |
|--------|------------|
| Строка из 3x-ui | `FULL_STRING=vless://...` |
| Подписка | `SUBSCRIPTION_URL`, опционально `SUBSCRIPTION_INDEX`, `SUBSCRIPTION_UPDATE_INTERVAL` |
| По полям | `SERVER_ADDRESS`, `SERVER_PORT`, `ID`, `TYPE`, `FP`, `SNI`, `PBK`, `SID`, … |

**Опционально:**

| Переменная | Назначение |
|------------|------------|
| `CONTAINER_BRIDGE_IP` | IP бриджа veth на роутере, если автоопределение не сработало |
| `XRAY_SOCKS_PORT` | Порт SOCKS Xray (по умолчанию `10800`) |
| `HEV_MTU` | MTU tun0 (по умолчанию `8500`) |
| `RUNTIME_DIR` | Каталог для volatile-файлов (по умолчанию `/tmp`) |

---

## Логирование

По умолчанию на RouterOS используйте **`logging=no`**, чтобы не засорять `/log`. Для отладки:

```
/container set [find interface=docker-xray-vless-veth] logging=yes
```

---

## Сборка своего образа

Контекст сборки — каталог `Containers/` репозитория:

```bash
docker buildx build -f Dockerfile --platform linux/arm/v7 \
  --output=type=docker --tag simyrik/xray-mikrotik:latest .
```

---

## Связанные проекты

- Форк: [catesin/Xray-vless-reality-MikroTik](https://github.com/catesin/Xray-vless-reality-MikroTik)
