# vpn-split — сплит-VPN только на заблокированные в РФ ресурсы

Через VPN идёт трафик **только** к ресурсам из блок-листов РКН (runetfreedom
`ru-blocked-all`: ~1.36 млн доменов + 89.5 тыс. подсетей) и к доменам, которые вы
явно добавили. Весь остальной трафик, включая офисные и приватные сети, идёт напрямую.

Одна установка для **Linux (systemd)** и **macOS (launchd)**, amd64/arm64.

## Как это работает

```
приложения → sing-box TUN (служба tun, root)
               ├─ домен/IP из ru-blocked или domains.proxy → xray (127.0.0.1:20808) → узел подписки
               └─ всё остальное                            → напрямую
```

- **xray** держит локальные SOCKS/HTTP-входы и сам непрерывно выбирает лучшую
  ноду (`leastPing`), пробуя `youtube/generate_204`, т.е. нода гарантированно
  открывает запрещённые ресурсы.
- **vpn-autoselect** (таймер, раз в 10 мин) тянет подписку и обновляет список нод xray.
- **render-config** собирает конфиг sing-box из шаблона, настроек и ваших списков
  доменов при каждом старте TUN-службы.

## Установка

```bash
git clone … vpn-configs && cd vpn-configs
sudo VPN_SPLIT_SUB_URL='https://…/sub/…' ./install.sh
```

Без `VPN_SPLIT_SUB_URL` установщик спросит URL интерактивно (или впишите его
потом в `/etc/vpn-split/vpn-split.conf` и повторите `sudo ./install.sh`).
Повторный запуск безопасен: он обновляет файлы, бинарники и юниты, но не трогает настройки и списки.

`install.sh` делает следующее:

1. **Проверяет и ставит зависимости** (`sudo ./install.sh deps --check-only` —
   только отчёт):
   - `curl`, `tar`, sha256-утилита, CA-сертификаты, `python3` ≥ 3.8, на Linux `iproute2`.
     Ставятся пакетным менеджером системы: apt, dnf/yum, pacman, zypper, apk.
   - macOS: если Python нет, ставится **Homebrew** (официальный установщик,
     от вашего пользователя, не от root), а через него `python3`.
   - Если подходящего Python нет или пакетный менеджер не справился, используется
     **uv**: он ставится в `/opt/vpn-split/tools`, изолированный Python — в
     `/opt/vpn-split/python` (принудительно: `--python=uv`).
   - Проверяет systemd и `/dev/net/tun` (Linux), `launchctl` (macOS).
   - Скрипты проекта используют только стандартную библиотеку Python — pip/venv и
     Node/npx не нужны. Если появится `requirements.txt`, зависимости встанут в
     `/opt/vpn-split/venv` через uv.
2. Скачивает **закреплённые версии** sing-box и xray из GitHub-релизов под вашу
   ОС и архитектуру и сверяет sha256 из [`versions.env`](versions.env).
   Системные brew/apt-версии не используются.
3. Раскладывает файлы по FHS (см. ниже), создаёт `vpn-split.conf` (0600), ставит
   юниты systemd или LaunchDaemons и запускает службы.
4. Если найдена старая установка (`/usr/local/etc/singbox-tun`, `singbox-tun.service`,
   `com.singbox.tun`, `local.xray`…), переносит пользовательские домены, DNS и
   подписку, делает резервную копию в `/var/backups/vpn-split-legacy-*.tar.gz`
   и удаляет старые файлы. На Linux старые `xray.service`/`vpn-autoselect`
   отключаются только с `--migrate-xray` (или после подтверждения).

Опции: `--no-deps`, `--no-start`, `--python=auto|system|uv`, `--migrate-xray`, `-y`.
Раскладку можно переопределить переменными `PREFIX`, `SYSCONFDIR`, `STATEDIR`,
`LOGDIR`, `BINDIR`, `SBINDIR`. `DESTDIR=…` — поэтапная установка в каталог
(службы не трогаются), удобно для проверки и пакетирования.

## Где что лежит

| Что | Путь |
|---|---|
| Бинарники и код | `/opt/vpn-split/{bin,lib,libexec,share}` |
| Настройки (0600, токен подписки) | `/etc/vpn-split/vpn-split.conf` |
| Ваши домены | `/etc/vpn-split/domains.proxy`, `/etc/vpn-split/domains.direct` |
| Сгенерированные конфиги, статус | `/var/lib/vpn-split/{singbox.json,xray.json,status.json}` |
| Логи | Linux: journald; macOS: `/var/log/vpn-split/*.log` (ротация newsyslog) |
| Команды | `/usr/local/bin/vpn-urls`, `/usr/local/sbin/vpn-autoselect` (macOS: `/usr/local/bin`) |
| Службы Linux | `vpn-split-tun.service`, `vpn-split-xray.service`, `vpn-split-autoselect.timer` |
| Службы macOS | `io.github.flarinli.vpn-split.{tun,xray,autoselect}` в `/Library/LaunchDaemons` |

Симлинков нет: команды в PATH — это маленькие обёртки. Путь установки скрипты
определяют по своему расположению и `share/layout.env`, который пишет установщик.

## Настройки

Все параметры задаются в одном файле `/etc/vpn-split/vpn-split.conf`; полный
список с комментариями — в [`etc/vpn-split.conf.example`](etc/vpn-split.conf.example).
Основные: `SUB_URL`, `EXCLUDE_NAMES`, `DNS_DIRECT` (локальный/офисный резолвер),
`DIRECT_DOMAINS` (внутренние зоны, например `corp.lan`), `SOCKS_PORT`.

После правки:
- подписка и узлы: `sudo vpn-autoselect --force`;
- DNS, домены, порты: перезапустите TUN — `sudo systemctl restart vpn-split-tun`
  или `sudo launchctl kickstart -k system/io.github.flarinli.vpn-split.tun`.

## Свои домены

```bash
sudo vpn-urls add netflix.com          # через VPN (домен и все поддомены)
sudo vpn-urls add direct:example.com   # наоборот — всегда напрямую
sudo vpn-urls remove netflix.com
vpn-urls list
```

Списки лежат отдельно от сгенерированного конфига, поэтому переживают
переустановку. На другую машину их можно перенести простым копированием
`domains.*`.

## Диагностика

```bash
sudo ./install.sh status                                  # службы + текущие узлы
curl --noproxy '*' -s https://api.ipify.org               # RU IP = остальное напрямую
curl --noproxy '*' -sI https://www.instagram.com/ | head -1   # 200 = заблокированное через VPN
cat /var/lib/vpn-split/status.json                        # текущая нода и здоровье
```

- Linux: `journalctl -u vpn-split-tun -u vpn-split-xray -u vpn-split-autoselect -f`
- macOS: `tail -f /var/log/vpn-split/*.log`

## Удаление

```bash
sudo ./install.sh uninstall          # настройки и состояние остаются
sudo ./install.sh uninstall --purge  # удалить всё
```

## Для разработки

- [`tools/build-rules.sh`](tools/build-rules.sh) пересобирает `share/rules/*.srs`
  из свежих списков runetfreedom. Обновлять рекомендуется раз в 1–2 месяца,
  затем выполнить `sudo ./install.sh` на каждой машине.
- [`tools/update-versions.sh`](tools/update-versions.sh) `[sing-box] [xray]`
  меняет закреплённые версии и пересчитывает sha256 в `versions.env`.

## Известные нюансы

- Некоторые гос-сайты (напр. `mos.ru`) требуют сертификат НУЦ Минцифры в
  системном хранилище. Из консоли (`curl`) это выглядит как ошибка TLS, в
  браузере с установленным сертификатом всё работает. К сплиту отношения не имеет.
- Два TUN одновременно (например, другой VPN-клиент со своим TUN) конфликтуют:
  сплит развалится.
- На Linux sing-box привязывает прямой трафик к интерфейсу маршрута по умолчанию,
  который определяется при старте службы. После смены сети выполните
  `systemctl restart vpn-split-tun` (или задайте `DEFAULT_IFACE`).
