# vpn-configs — сплит-VPN только на заблокированные в РФ ресурсы

Через VPN идёт трафик **только** к ресурсам из блок-листов РКН (runetfreedom
`ru-blocked-all`: ~1.36 млн доменов + 89.5 тыс. подсетей) и к доменам, которые вы
явно добавили. Весь остальной трафик, включая офисные сети и `*.gosniias.lan`,
идёт напрямую.

## Как это работает

```
приложения → sing-box TUN (systemd/launchd, root)
               ├─ домен/IP из ru-blocked или из вашего списка → прокси (существующий VPN-клиент) → узел
               └─ всё остальное → напрямую
```

sing-box берёт на себя только маршрутизацию (TUN + правила). Сам VPN-туннель
(протокол, сервер, подписка) обеспечивает уже имеющийся у вас клиент —
на macOS это [Happ](https://happ.su) в режиме прокси, на Linux — `vpn-autoselect`
(xray с автовыбором сервера). Настройка не заменяет их, а достраивает сплит поверх.

## Структура

- [`macos/`](macos/) — установка на macOS поверх Happ (socks 127.0.0.1:10808)
- [`linux/`](linux/) — установка на Linux (systemd) поверх xray/vpn-autoselect (socks 127.0.0.1:20808)
- [`tools/build-rules.sh`](tools/build-rules.sh) — пересборка списков блокировок (обновление рекомендуется раз в 1-2 месяца)

Каждая платформенная папка самодостаточна: конфиг, systemd/launchd-юнит,
готовые бинарные rule-set'ы (`rules/*.srs`) и `install.sh`.

## Быстрый старт

```bash
# macOS
cd macos && sudo bash install.sh

# Linux
cd linux && sudo bash install.sh
```

Подробности и предпосылки — в README каждой папки.

## Управление списком URL (одинаково на обеих платформах)

```bash
sudo vpn-urls add netflix.com          # через VPN (домен и все поддомены)
sudo vpn-urls add direct:example.com   # наоборот — всегда напрямую
sudo vpn-urls remove netflix.com
vpn-urls list                          # без sudo — только чтение
```

## Диагностика

```bash
curl --noproxy '*' -s https://api.ipify.org             # RU IP = остальное напрямую
curl --noproxy '*' -sI https://www.instagram.com/ | head -1  # 200 = заблокированные через VPN
```

macOS: `launchctl print system/com.singbox.tun` и `/var/log/singbox-tun.log`
Linux: `systemctl status singbox-tun` и `journalctl -u singbox-tun -f`

## Известные нюансы

- Некоторые гос-сайты (напр. `mos.ru`) требуют сертификат НУЦ Минцифры в
  системном хранилище — из консоли (`curl`) это выглядит как ошибка TLS,
  в браузере с установленным сертификатом всё работает. К сплиту отношения не имеет.
- На macOS **не включайте** собственный TUN-режим Happ — он перехватит весь
  трафик и сплит перестанет работать (Happ должен быть в режиме прокси).
- Списки блокировок стареют — пересобирайте `tools/build-rules.sh` время от
  времени и переустанавливайте (`install.sh`) на каждой машине.
