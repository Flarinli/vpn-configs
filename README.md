# vpn-configs — сплит-VPN только на заблокированные в РФ ресурсы

Через VPN идёт трафик **только** к ресурсам из блок-листов РКН (runetfreedom
`ru-blocked-all`: ~1.36 млн доменов + 89.5 тыс. подсетей) и к доменам, которые вы
явно добавили. Весь остальной трафик, включая офисные сети и `*.gosniias.lan`,
идёт напрямую.

## Как это работает

```
приложения → sing-box TUN (systemd/launchd, root)
               ├─ домен/IP из ru-blocked или из вашего списка → системный xray → узел (автоселект)
               └─ всё остальное → напрямую
```

На обеих платформах туннель обеспечивает связка **системный xray + `vpn-autoselect`**:
скрипт по таймеру тянет подписку, обновляет список нод, а xray сам непрерывно
выбирает лучшую ноду (`leastPing`), пробуя `youtube/generate_204` — т.е. нода
гарантированно открывает запрещённые ресурсы. Happ выведен из цепочки; на macOS
осталась возможность отката на старый Happ-вариант (`install.sh rollback`).

## Структура

- [`macos/`](macos/) — macOS: sing-box (launchd) + xray (brew) + автоселект (launchd-таймер)
- [`linux/`](linux/) — Linux (systemd): та же схема, socks 127.0.0.1:20808
- [`autoselect/`](autoselect/) — скрипт `vpn-autoselect` и пример конфига (общий для платформ)
- [`tools/build-rules.sh`](tools/build-rules.sh) — пересборка списков блокировок (обновление рекомендуется раз в 1-2 месяца)

Каждая платформенная папка самодостаточна: конфиг, systemd/launchd-юнит,
готовые бинарные rule-set'ы (`rules/*.srs`) и `install.sh`.

## Быстрый старт

```bash
# macOS — после установки впиши SUB_URL в /usr/local/etc/vpn-autoselect.conf
cd macos && sudo bash install.sh

# Linux (vpn-autoselect уже установлен отдельно; его исходники — в autoselect/)
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

macOS: `launchctl print system/com.singbox.tun`, `/usr/local/var/log/xray.log`,
`cat /usr/local/var/vpn-autoselect/status.json` (текущая нода и здоровье)
Linux: `systemctl status singbox-tun xray`, `journalctl -u singbox-tun -f`,
`cat /var/lib/vpn-autoselect/status.json`

## Известные нюансы

- Некоторые гос-сайты (напр. `mos.ru`) требуют сертификат НУЦ Минцифры в
  системном хранилище — из консоли (`curl`) это выглядит как ошибка TLS,
  в браузере с установленным сертификатом всё работает. К сплиту отношения не имеет.
- Если запущен Happ с собственным TUN — два TUN конфликтуют, сплит развалится.
  Закройте Happ или выключите в нём TUN (в новой схеме он не нужен).
- LTE-узлы подписки (квота 0 ГБ) исключены фильтром `EXCLUDE_NAMES` в конфиге
  автоселекта; провайдерский узел «Автовыбор» и российские узлы — тоже.
- Списки блокировок стареют — пересобирайте `tools/build-rules.sh` время от
  времени и переустанавливайте (`install.sh`) на каждой машине.
