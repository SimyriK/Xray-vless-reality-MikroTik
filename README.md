# :sparkles: XRay Vless Reality + MikroTik :sparkles:


![img](Demonstration/logo.png)

> 📦 Этот репозиторий является форком оригинального проекта [catesin/Xray-vless-reality-MikroTik](https://github.com/catesin/Xray-vless-reality-MikroTik)

**Основные изменения в этом форке:**
- ✨ **Единый multi-arch Dockerfile** — один Dockerfile для всех архитектур (ARM, ARM64, AMD64)
- 🔗 **Поддержка FULL_STRING** — использование полной строки подключения из 3x-ui
- 📡 **Поддержка SUBSCRIPTION_URL** — автоматическое получение конфигурации из подписки
- 🔄 **Автоматическое обновление подписки** — периодическое обновление через cron
- 🌐 **Поддержка xhttp транспорта** — в дополнение к tcp
- 🤖 **Автоматическое определение сетевых параметров** — не требуется ручная настройка IP бриджа и интерфейсов
- 🚀 **Интерактивный скрипт установки** — автоматическая настройка контейнера через пошаговый мастер

:dizzy: Аналог [AmneziaWG + MikroTik](https://github.com/catesin/AmneziaWG-MikroTik)

---

## 🚀 Быстрая установка (одна команда)

Выполните в терминале MikroTik:

```
/tool/fetch url="https://raw.githubusercontent.com/SimyriK/Xray-vless-reality-MikroTik/main/xray-container-setup.rsc" dst-path="xray-setup.rsc"; /import file-name="xray-setup.rsc"
```

Или если предпочитаете сохранить как скрипт для повторного использования:

```
/system/script/add name=xray-setup source=([/tool/fetch url="https://raw.githubusercontent.com/SimyriK/Xray-vless-reality-MikroTik/main/xray-container-setup.rsc" output=user as-value]->"data")
/system/script/run xray-setup
```

> ⚠️ **Требования:** RouterOS 7.4+ с включенным режимом контейнеров, доступ в интернет

---


В данном репозитории рассматривается работа MikroTik RouterOS V7.20.6+ с протоколом **XRay Vless Reality** с использованием контейнеров внутри RouterOS. 

Предполагается что вы уже настроили серверную часть Xray например [с помощью панели управления 3x-ui](https://github.com/MHSanaei/3x-ui) и протестировали конфигурацию клиента, например на смартфоне или персональном ПК.

:school: Внимание! Инструкция среднего уровня сложности. Перед применением настроек вам необходимо иметь опыт в настройке MikroTik уровня сертификации MTCNA. 

В репозитории присутствует инструкция с готовыми контейнерами и шаблоны для самостоятельной сборки в каталоге **"Containers"**. Контейнеры делятся на три архитектуры **ARM, ARM64 и x86**.

------------

* [Преднастройка RouterOS](#Pre_edit)
* [RouterOS с контейнером](#R_Xray_1)
	- [Включение функции контейнеров в RouterOS](#R_Xray_1_container)
	- [Настройка контейнера в RouterOS](#R_Xray_1_settings)
	- [Добавление контейнера](#R_Xray_1_add_container)
	

------------

<a name='Pre_edit'></a>
## Преднастройка RouterOS

Создадим отдельную таблицу маршрутизации:
```
/routing table 
add disabled=no fib name=r_to_vpn
```
Добавим address-list "to_vpn" что бы находившиеся в нём IP адреса и подсети заворачивать в пока ещё не созданный туннель
```
/ip firewall address-list
add address=172.217.168.206 list=to_vpn
```
Добавим address-list "RFC1918" что бы не потерять доступ до RouterOS при дальнейшей настройке
```
/ip firewall address-list
add address=10.0.0.0/8 list=RFC1918
add address=172.16.0.0/12 list=RFC1918
add address=192.168.0.0/16 list=RFC1918
```

Добавим правила в mangle для address-list "RFC1918" и переместим его в самый верх правил
```
/ip firewall mangle
add action=accept chain=prerouting dst-address-list=RFC1918 in-interface-list=!WAN
```

Добавим правило транзитного трафика в mangle для address-list "to_vpn"
```
/ip firewall mangle
add action=mark-connection chain=prerouting connection-mark=no-mark dst-address-list=to_vpn in-interface-list=!WAN \
    new-connection-mark=to-vpn-conn passthrough=yes
```
Добавим правило для транзитного трафика отправляющее искать маршрут до узла назначения через таблицу маршрутизации "r_to_vpn", созданную на первом шаге
```
add action=mark-routing chain=prerouting connection-mark=to-vpn-conn in-interface-list=!WAN new-routing-mark=r_to_vpn \
    passthrough=yes
```
Маршрут по умолчанию в созданную таблицу маршрутизации "r_to_vpn" добавим чуть позже.

:exclamation:Два выше обозначенных правила будут работать только для трафика, проходящего через маршрутизатор. 
Если вы хотите заворачивать трафик, генерируемый самим роутером (например команда ping 172.217.168.206 c роутера для проверки туннеля в контейнере), тогда добавляем ещё два правила (не обязательно). 
Они должны находиться по порядку, следуя за вышеобозначенными правилами.
```
/ip firewall mangle
add action=mark-connection chain=output connection-mark=no-mark \
    dst-address-list=to_vpn new-connection-mark=to-vpn-conn-local \
    passthrough=yes
add action=mark-routing chain=output connection-mark=to-vpn-conn-local \
    new-routing-mark=r_to_vpn passthrough=yes
```

------------
<a name='R_Xray_1'></a>
## RouterOS с контейнером

Данный пункт настройки подходит только для устройств с архитектурой **ARM, ARM64 или x86**. 
Перед запуском контейнера в RouteOS убедитесь что у вас [включены контейнеры](https://help.mikrotik.com/docs/spaces/ROS/pages/84901929/Container). 
С полным списком поддерживаемых устройств можно ознакомится [тут](https://mikrotik.com/products/matrix). 

:warning: Предполагается что на устройстве (или если есть USB порт с флешкой) имеется +- 40 Мбайт свободного места для разворачивания контейнера внутри RouterOS. Сам контейнер весит не более 30 Мбайт. Если места не хватает, его можно временно расширить [за счёт оперативной памяти](https://help.mikrotik.com/docs/spaces/ROS/pages/91193346/Disks#Disks-AllocateRAMtofolder). После перезагрузки RouterOS, всё что находится в RAM, стирается. 

<a name='R_Xray_1_container'></a>
### Включение функции контейнеров в RouterOS

Основная инструкция по включению функции контейнеров находится [ТУТ](https://help.mikrotik.com/docs/spaces/ROS/pages/84901929/Container#Container-Summary) или [ТУТ](https://www.google.com/search?q=%D0%9A%D0%B0%D0%BA+%D0%B2%D0%BA%D0%BB%D1%8E%D1%87%D0%B8%D1%82%D1%8C+%D0%BA%D0%BE%D0%BD%D1%82%D0%B5%D0%B9%D0%BD%D0%B5%D1%80%D1%8B+%D0%B2+mikrotik&oq=%D0%BA%D0%B0%D0%BA+%D0%B2%D0%BA%D0%BB%D1%8E%D1%87%D0%B8%D1%82%D1%8C+%D0%BA%D0%BE%D0%BD%D1%82%D0%B5%D0%B9%D0%BD%D0%B5%D1%80%D1%8B+%D0%B2+mikrotik)

Порядок действий выглядит так: 

* Обновляемся до последней версии RouterOS
* Скачиваем дополнительный пакет из расширений "all packages" на [официальном сайте](https://mikrotik.com/download)
* Устанавливаем пакет
* Включаем функцию контейнеров

<a name='R_Xray_1_settings'></a>
### Настройка контейнера в RouterOS

В текущем примере на устройстве MikroTik флешки нет. Хранить будем всё в корне.
Если у вас есть USB порт и флешка, лучше размещать контейнер на ней.  Можно комбинировать память загрузив контейнер в расшаренный диск [за счёт оперативной памяти](https://www.youtube.com/watch?v=uZKTqRtXu4M), а сам контейнер разворачивать в постоянной памяти.

Рекомендую создать пространство из ОЗУ хотя бы для tmp директории. Размер регулируйте самостоятельно:
```
/disk
add slot=ramstorage tmpfs-max-size=100M type=tmpfs
```

:exclamation:**Если контейнер не запускается на флешке.**
Например, вы хотите разместить контейнер в каталоге /usb1/docker/xray. Не создавайте заранее каталог xray на USB-флеш-накопителе. При создании контейнера добавьте в команду распаковки параметр "root-dir=usb1/docker/xray", в этом случае контейнер распакуется самостоятельно создав каталог /usb1/docker/xray и запустится без проблем.

**В RouterOS выполняем:**

0) Подключим Docker HUB в наш RouterOS

```
/container config set tmpdir=ramstorage

/container/config/set registry-url=https://registry-1.docker.io tmpdir=/ramstorage
```

1) Создадим интерфейс для контейнера
```
/interface veth add address=172.18.20.6/30 gateway=172.18.20.5 gateway6="" name=docker-xray-vless-veth
```

2) Добавим правило в mangle для изменения mss для трафика, уходящего в контейнер. Поместите его после правила с RFC1918 (его мы создали ранее).
```
/ip firewall mangle add action=change-mss chain=forward new-mss=1360 out-interface=docker-xray-vless-veth passthrough=yes protocol=tcp tcp-flags=syn tcp-mss=1420-65535
```

3) Назначим на созданный интерфейс IP адрес. IP 172.18.20.6 возьмёт себе контейнер, а 172.18.20.5 будет адрес RouterOS.
```
/ip address add interface=docker-xray-vless-veth address=172.18.20.5/30
```
4) В таблице маршрутизации "r_to_vpn" создадим маршрут по умолчанию ведущий на контейнер
```
/ip route add distance=1 dst-address=0.0.0.0/0 gateway=172.18.20.6 routing-table=r_to_vpn
```
5) Включаем masquerade для всего трафика, уходящего в контейнер.
```
/ip firewall nat add action=masquerade chain=srcnat out-interface=docker-xray-vless-veth
```
6) Создадим переменные окружения envs под названием "xvr", которые позже при запуске будем передавать в контейнер.

Контейнер поддерживает три способа настройки:

<details>
<summary><strong>Вариант 1: FULL_STRING</strong></summary>

Используйте полную строку подключения из 3x-ui:

Пример импортируемой строки из 3x-ui раздела клиента "Details":
```
vless://62878542-8f68-42f0-8c66-e5a46e9c2cb1@mydomain.com:443?type=tcp&encryption=none&security=reality&pbk=7JTFIDt3Eyihq723jpp564DnK8X_GHLs_jHjLrRMFng&fp=chrome&sni=google.com&sid=aeb4c72f73a05af2&spx=%2F&pqv=LjRcyvTpvdwE2DV-s7rUGVotLw1LNH...
```

|   **Переменная**   |             **Пример значения**             | **Пояснение**                                    |
| :----------------: | :-----------------------------------------: | :----------------------------------------------- |
|   **FULL_STRING**  | vless://...                                 | Полная строка подключения из 3x-ui (раздел клиента "Details") |

```
/container envs
add key=FULL_STRING list=xvr value="vless://62878542-8f68-42f0-8c66-e5a46e9c2cb1@mydomain.com:443?type=tcp&encryption=none&security=reality&pbk=..."
```

</details>

<details>
<summary><strong>Вариант 2: SUBSCRIPTION_URL</strong></summary>

Используйте URL подписки для автоматического получения конфигурации:

|   **Переменная**   |             **Пример значения**             | **Пояснение**                                    |
| :----------------: | :-----------------------------------------: | :----------------------------------------------- |
| **SUBSCRIPTION_URL** | https://mydomain.com/your-subscription-link | URL подписки для автоматического получения конфигурации |
| **SUBSCRIPTION_INDEX** |                     1                      | Номер конфигурации из подписки (по умолчанию: 1) |
| **SUBSCRIPTION_UPDATE_INTERVAL** |                  24                      | Интервал автоматического обновления подписки в часах (опционально) |

```
/container envs
add key=SUBSCRIPTION_URL list=xvr value=https://mydomain.com/your-subscription-link
add key=SUBSCRIPTION_INDEX list=xvr value=1
add key=SUBSCRIPTION_UPDATE_INTERVAL list=xvr value=24
```

</details>

<details>
<summary><strong>Вариант 3: Отдельные переменные</strong></summary>

|   **Переменная**   |             **Пример значения**             | **Пояснение**                                    |
| :----------------: | :-----------------------------------------: | :----------------------------------------------- |
| **SERVER_ADDRESS** |             mydomain.com                    | Адрес Xray сервера                               |
|   **SERVER_PORT**  |                     443                     | Порт сервера                                     |
|       **ID**       |     62878542-8f68-42f0-8c66-e5a46e9c2cb1    | UUID клиента VLESS                               |
|   **ENCRYPTION**   |                     none                    | Для VLESS всегда `none`                          |
|      **TYPE**      |                      tcp                    | Тип транспорта: `tcp` или `xhttp`                |
|      **FLOW**      |               xtls-rprx-vision              | Flow для Xray (Vision / другие)                  |
|       **FP**       |                    chrome                   | Fingerprint REALITY (браузерная маскировка)      |
|       **SNI**      |                  google.com                 | SNI для TLS / REALITY                            |
|       **PBK**      | 7JTFIDt3Eyihq723jpp564DnK8X_GHLs_jHjLrRMFng | Публичный ключ REALITY                           |
|       **SID**      |               aeb4c72f73a05af2              | ShortId REALITY                                  |
|       **SPX**      |                      /                      | Путь SpiderX для REALITY                         |
|       **PQV**      |      LjRcyvTpvdwE2DV-s7rUGVotLw1LNH…        | PQV (post-quantum value), сокращено для удобства |

```
/container envs
add key=SERVER_ADDRESS list=xvr value=mydomain.com
add key=SERVER_PORT list=xvr value=443
add key=ID list=xvr value=62878542-8f68-42f0-8c66-e5a46e9c2cb1
add key=ENCRYPTION list=xvr value=none
add key=TYPE list=xvr value=tcp
add key=FLOW list=xvr value=xtls-rprx-vision
add key=FP list=xvr value=chrome
add key=SNI list=xvr value=google.com
add key=PBK list=xvr value=7JTFIDt3Eyihq723jpp564DnK8X_GHLs_jHjLrRMFng
add key=SID list=xvr value=aeb4c72f73a05af2
add key=SPX list=xvr value=/
add key=PQV list=xvr value="LjRcyvTpvdwE2DV-s7rUGVotLw1LNHH3cPCHnBlRXgJ7aGpImVv-axSQhotFbEcQfm_VQgEMzoLvzFlv9gFj8vWpsiDRqPYmDzs_3ZsTNJVx-X9dmrXuqMvenoEw-wc5OtITk5kOTks62ipPkem3ZX4aLzhNH9BhK-H4XE3nJybcpNc3yOBH1OwOBDV6OnpDXexqsbxuCJPBoUgW8TY8hW5GqSHKs7hg1sSegM_App-CLjMhnL3_u3T41B7pbI0ScRj63wLT9oz_i3DxoMHiz1o57XkxUTvS3f-YoFlUhs6LHXCeEwDU1TRkd-tQuNx3xK1fMbgxaK-Tk2YVD25L7-eWEOiZ2yiED_kRIZWH-1TjEPSvB9rIPYBlQTUxa4T4zIkbnCRDStu4nx4mqJg2cAFQqJXAmuyKGyuTEHBqPLJSpnQJ1es9BFCDEEXstkD3vzVBDpFNl0DZcTh9yDFMz7WDSX5LGuwOkywKhvSXBUG42ZtWpZVkFnGJmRIkkvs8-LoY1AvbVy52ylhSvfDsjIk6WeKhyBRfT5WRhWfO5rUdQeN8c8gD7WMTqCLAci1QChXLQRleD8irni1a-40C4h1UNWFBCj8MrZw8O9k5jxIvoVFyTOxkeepv_Ll8Pb6lb4qeO0wKfjACHnQBq6psWRABCUuUKPmEwllACQk44wDpfdpcl4oKHM5-lQ9nzuOo_-THMZRKH1zjYLi5bUH_NQu7BEyZjXNBakV5bEq6FtNxWO9kCB2Ny7NeGelLL7xdg2Je30AMTEHMMymq1mNWL5R926TdGMTuJYHx49YfIygcZJaZWc8h_YCGs53lsGMG6vCBRHfF72J_bqKAndKWd8atC1ivxmGayMomfwaT85QitSQ-U7ka4nzktgnim4qsoMarwWwrteWQkjelGHCZl3RyGQoLZaNl_aV2YHn2QRQ0GyJdaJylJpnYfbUrQZymz8aF2-3HAtVos18vJrKEdpxpgyVth5JzPO8VSlzolYMuR_CCEJnd-aw27iBR-XStYfmTNqEe93nLNbpfr3h6M4avVFTbZQsqpD7V4CC3wAHhpemx2s9NyH-qnSmyBLMsM1t4XxjPBJ-6vEXyZOJ0bgaV4jF9NZ2XnuY64fRf1RrNEZOmA3-t2cGs2j5qROqE7r3ZppEpBqt9hJys5aWOZfYxpgAi-79O9ArjsngGAtOR2mxXsJJd77LT5K_P9jCZSd3GoCFdJBhenI4e2UO4YjWTfwUV8tchRUE-0lI09DkkVwwpxumxvjVt4SXzcDw0Zrr59mMvWFHT14IQ20pRoI64uizd2nGvXJ3E4_bxwi2GEmlqheTo2IYfqVnLzJ2HzM1TYvPGMH_DILdDMQRjlYFJURSYEaCPc2ebjdz1PJZglV01eQkZh3S18FE2C7CqvKAIwqpTLk5FA_ZYZ5pzCFMMyR9Gjrsm9GXlyjlVbcz2Z51aXj905qjoJ0hUesIgK3tAuDShrD7BgCek0711DQRfil02GbLMeHV7UAAPA61IKrEZq2gfM4IBWA-BfY8sI8E005OLDqn8BRp0AlilG0RO-fOA6xverjKtJTdRR8tU8b7HA57Ht9im42hrgcwV7hFVK_sMn-MxrS5ZqRn-bEwthWlgL6avDJQKnu94ykPOfcjzvPFamjusGjOJtgYWslMiKXjRh0VgD3zuXaPz14FENpiCPYf2z-aYU3ZaJHa2-Ri2uww6BT6zHJvRY4qwDjbga8RuvPH9_dBjWK8HjNpqkOlcvacgbRe_-wqIFkX7oFSNzZwOBgbqFUSPGS2lWZeHHO5n5caBazcmGnf5qZI75BKbVs196Vp0aGOu_tWkQb98XwJB7xrAocMTMyqT63AJG5sUQ4k9_dta0Gnp1CfQQTbaoodL4UizK6JUgubKmLcYX_zdclnBySJAfDQGvnDBO6mhlnN7TJ0gB_wQ4AdLeXJtQn0CmABSVsL3IiRYNBp6BWrntBS26Kt1GAhatRAC4leUU-XrtCHof9zf4KbCQvxl2GN2ducRPpZrzxAXNpIY6yAXVQTVGxutHgsdEbzdSXVYyS7P4rK0idr_DFTTZvSoYJIJ4cBmPWL1yQW-c-NBwYOGotZvJPdoNSEzo5_6RwL1fsA23MDcbnsps15z-iIDophqddg56z3PN9PUi8kFc3vqjxhD9usDXOv1vFLzawZHPstH2Jx2zIMrceBHa8ShZcUVws7iWxwF4Ie9ciaOwLXgiLw8IZm0-wb4tLdCvJwQjN2v2R3Are4PulLcma7J6gEiVKdT9-wA2A1M4W-o916UaTSs2llielbh92UDOti-2L_u5CoGBNxjtlQ8ZKyFJxxtwl6tsEgwvV2FHFCt-BfEJ6kSrYVTnsexi03kf8STuE_QJNgouUgYdC9xRqg-KvcIW3Ag_FcACaqIE5YDM7rvVeKNz-F8JgxqMIThA95_sLxzeAqzfBci0i3Hq7qXCphKKILHmh-OK0Fmz93fbc1-VKkQqCKl0VqygsxAafGW15nTW-qYgeoxOQPLud0Mzh7gZdwzenc8a65dwH8pvZGzoayBmRGgOf91IcRxFTMyxkwrVkav5qIt1lMto62VgPkR2PTrWDUlAHA"
```

</details>

<details>
<summary><strong>Опциональные переменные для всех вариантов конфигурации</strong></summary>

|   **Переменная**   | **Пример значения** | **Пояснение**                                    |
| :----------------: | :-----------------: | :----------------------------------------------- |
| **CONTAINER_BRIDGE_IP** |     172.18.20.5     | IP бриджа контейнера (если автоматическое определение не работает) |

```
/container envs
add key=CONTAINER_BRIDGE_IP list=xvr value=172.18.20.5
```

</details>

<a name='R_Xray_1_add_container'></a>
### Добавление контейнера

7) Теперь добавим сам контейнер в RouterOS. Есть два способа получения образа:

<details>
<summary><strong>Вариант 1: Использование готового образа из Docker Hub</strong></summary>

Используйте образ из [Docker Hub репозитория](https://hub.docker.com/r/simyrik/xray-mikrotik):

```
/container add hostname=xray-vless interface=docker-xray-vless-veth envlist=xvr root-dir=xray-vless logging=yes start-on-boot=yes remote-image=simyrik/xray-mikrotik:latest
```

Docker автоматически выберет правильный образ для архитектуры вашего устройства.

</details>

<details>
<summary><strong>Вариант 2: Самостоятельная сборка образа</strong></summary>

Если вы хотите собрать образ самостоятельно, выполните следующие шаги:

**Как определить архитектуру вашего MikroTik:**
- В WinBox: перейдите в **System → Resources** и посмотрите поле **CPU**
- На сайте: найдите вашу модель в [таблице продуктов MikroTik](https://mikrotik.com/products/matrix)
- Типы архитектур:
  - **ARMv8 (arm64/v8)** — спецификация 8-го поколения оборудования ARM, которое поддерживает архитектуры AArch32 и AArch64
  - **ARMv7 (arm/v7)** — спецификация 7-го поколения оборудования ARM, которое поддерживает только архитектуру AArch32
  - **AMD64 (amd64)** — это 64-битный процессор, который добавляет возможности 64-битных вычислений к архитектуре x86

**Установка зависимостей:**

Для самостоятельной сборки следует установить подсистему Docker [buildx](https://github.com/docker/buildx?tab=readme-ov-file).

**Настройка buildx для кросс-платформенной сборки (Linux):**

Если вы собираете образ для архитектуры, отличной от вашей (например, ARM на amd64), необходимо настроить QEMU для эмуляции:

```bash
# Установка QEMU для поддержки кросс-платформенной сборки
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# Создание builder с поддержкой мультиплатформенности
docker buildx create --name multiarch --driver docker-container --use
docker buildx inspect --bootstrap
```

**Сборка образа:**

Для всех архитектур используется единый `Dockerfile` с параметром `--platform`:

Для ARMv8 (arm64/v8):
```bash
docker image prune -f
docker buildx build -f Dockerfile --no-cache --progress=plain --platform linux/arm64 --output=type=docker --tag user/docker-xray-vless:latest .
```

Для ARMv7 (arm/v7):
```bash
docker image prune -f
docker buildx build -f Dockerfile --no-cache --progress=plain --platform linux/arm/v7 --output=type=docker --tag user/docker-xray-vless:latest .
```

Для amd64:
```bash
docker image prune -f
docker buildx build -f Dockerfile --no-cache --progress=plain --platform linux/amd64 --output=type=docker --tag user/docker-xray-vless:latest .
```

Иногда процесс создания образа может подвиснуть из-за плохого соединения с интернетом. Следует повторно запустить сборку.

**Загрузка собранного образа в RouterOS:**

После сборки образа его нужно загрузить в RouterOS. Можно использовать один из способов:

1. **Через Docker Hub:** Загрузите образ в свой Docker Hub репозиторий и используйте его как в Варианте 1:

```bash
# Авторизуйтесь в Docker Hub
docker login

# Создание multi-arch manifest с тегом latest
docker buildx build -f Dockerfile \
  --platform linux/amd64,linux/arm/v7,linux/arm64 \
  --tag user/xray-mikrotik:latest \
  --push .
```

Эта команда соберёт и загрузит образы для всех трёх архитектур, создав единый manifest list. Docker автоматически выберет нужный образ при использовании тега `latest`.

Затем в RouterOS:
```
/container add hostname=xray-vless interface=docker-xray-vless-veth envlist=xvr root-dir=xray-vless logging=yes start-on-boot=yes remote-image=user/xray-mikrotik:latest
```

2. **Через файл:** Экспортируйте образ в файл и загрузите его в RouterOS через контейнеры.

</details>

**Примечание:** не создавайте заранее каталог для параметра "root-dir"

Отредактируйте местоположение контейнера в ```root-dir``` при необходимости.

Подождите немного пока контейнер распакуется до конца. В итоге у вас должна получиться похожая картина, в которой есть распакованный контейнер и окружение envs. Если в процессе импорта возникают ошибки, внимательно читайте лог из RouterOS.

![img](Demonstration/1.1.png)

![img](Demonstration/1.2.png)

![img](Demonstration/1.3.png)

:anger:
Контейнер будет использовать только локальный DNS сервер на IP адресе 172.18.20.5. Необходимо разрешить DNS запросы TCP/UDP порт 53 на данный IP в правилах RouterOS в разделе ```/ip firewall filter```
Указанные правила должны быть выше запрещающих. 
```
/ip firewall filter
add chain=input in-interface=docker-xray-vless-veth src-address=172.18.20.6 dst-address=172.18.20.5 protocol=udp dst-port=53 action=accept comment="container -> local DNS (UDP/53)"
add chain=input in-interface=docker-xray-vless-veth src-address=172.18.20.6 dst-address=172.18.20.5 protocol=tcp dst-port=53 action=accept comment="container -> local DNS (TCP/53)"
```


8) Запускаем контейнер через WinBox в разделе меню Winbox "container". В логах MikroTik вы увидите характерные сообщения о запуске контейнера. 

:fire::fire::fire: Поздравляю! Настройка завершена. Можно проверить доступность IP 172.217.168.206 из списка "to_vpn" (этот адрес мы добавили ранее). Проверям доступность через запрос на https порт (запрос в браузере, telnet или TNC PowerShell)
 
По желанию логирование контейнера можно отключить что бы не засорялся лог RouteOS.

[Donate :sparkling_heart:](https://telegra.ph/Youre-making-the-world-a-better-place-01-14)
