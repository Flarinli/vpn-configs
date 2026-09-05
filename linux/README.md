# Linux — сплит-VPN поверх vpn-autoselect (xray)

## Предпосылки

- Установлен и работает `vpn-autoselect` (xray с автовыбором сервера из
  подписки), слушающий `socks 127.0.0.1:20808`. Это отдельный компонент —
  данный проект его не разворачивает, только достраивает сплит-маршрутизацию
  поверх уже поднятого туннеля.
- Если ваш xray/vpn-autoselect слушает другой порт — поправьте
  `server_port` в [`config.json`](config.json) (outbound `proxy`) до установки.

## Установка

```bash
sudo bash install.sh
```

Скрипт:
1. Скачивает `sing-box` (если не установлен) с GitHub-релизов под архитектуру машины.
2. Кладёт `rules/*.srs` и `config.json` в `/usr/local/etc/singbox-tun/`.
3. Ставит helper `vpn-urls` в `/usr/local/bin/`.
4. Регистрирует и запускает systemd-юнит `singbox-tun.service`.

## Проверка

```bash
systemctl status singbox-tun
curl --noproxy '*' -s https://api.ipify.org             # RU IP = остальное напрямую
curl --noproxy '*' -sI https://www.instagram.com/ | head -1  # 200 = заблокированные через VPN
journalctl -u singbox-tun -f
```

## Управление списком URL

```bash
sudo vpn-urls add netflix.com
sudo vpn-urls add direct:example.com
sudo vpn-urls remove netflix.com
vpn-urls list
```

## Офисные/локальные сети

`gosniias.lan` и приватные подсети (`ip_is_private`) всегда идут напрямую —
дополнительно ничего настраивать не нужно. Если нужно закрепить конкретные
офисные подсети за LAN-интерфейсом при одновременной работе VPN (аналог
`office-net-guard` из macOS-деплоя), это отдельная задача маршрутизации ОС,
сюда не входит.

## Если что-то пошло не так

- **`socks: connection refused` в логе** — `vpn-autoselect`/xray не запущен
  или слушает другой порт, проверьте `systemctl status xray` и порт в конфиге.
- **Список блокировок устарел** — пересоберите его `../tools/build-rules.sh`
  и повторите `install.sh`.
