# Списки доменов хоста maxims-macbook-air

Пользовательские списки доменов для vpn-split (MacBook Air, Maxims-MacBook-Air):

- `domains.proxy` — домены, которые всегда ходят через VPN;
- `domains.direct` — домены, которые всегда ходят напрямую.

По одному домену на строку, домен действует со всеми поддоменами.

## Восстановление на этом или новом хосте

```sh
sudo cp etc/maxims-macbook-air/domains.* /etc/vpn-split/
sudo vpn-autoselect --force
sudo launchctl kickstart -k system/io.github.flarinli.vpn-split.tun
```

## tg-ws-proxy (локальный MTProto-WS-прокси для Telegram Desktop)

Слушает `127.0.0.1:1443`, Telegram Desktop ходит через него. Файлы на хосте:

- `~/.local/bin/tg-ws-proxy` — бинарник (Rust-порт `valnesfjord/tg-ws-proxy-rs`,
  версия v2.7.0; апдейтить с гитхаба релиза);
- `~/.local/bin/tg-ws-proxy-launch.sh` — скрипт запуска (копия в этом каталоге);
- `~/.config/tg-ws-proxy/env` — env с секретом, 0600 (в репо НЕ хранится —
  см. `tg-ws-proxy.env.example`);
- `~/Library/LaunchAgents/com.tgwsproxy.rs.plist` — LaunchAgent `com.tgwsproxy.rs`.

Восстановление:

```sh
mkdir -p ~/.config/tg-ws-proxy
cp etc/maxims-macbook-air/tg-ws-proxy-launch.sh ~/.local/bin/ && chmod +x ~/.local/bin/tg-ws-proxy-launch.sh
# создать env по tg-ws-proxy.env.example, вписать TG_SECRET
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tgwsproxy.rs.plist
# в Telegram Desktop: Прокси → MTProto → 127.0.0.1:1443, secret = TG_SECRET
```

Прокси бесполезен, когда мертвы CF-домены из `TG_CF_DOMAIN` (домены
VPN-провайдера — та же инфраструктура) — при ротации провайдером обновить
`TG_CF_DOMAIN` и перезапустить: `launchctl kickstart -k gui/$(id -u)/com.tgwsproxy.rs`.

### tg-direct-routes (LaunchDaemon `com.tgwsproxy.direct-routes`)

Каждые 60с пиннит диапазоны Telegram-DC напрямую через физический шлюз,
чтобы TG не зависел от utun: `/usr/local/sbin/tg-direct-routes.sh`,
копия в `etc/maxims-macbook-air/tg-direct-routes.sh`. В списке ТОЛЬКО
диапазоны Telegram (91.108.0.0/16, 149.154.160.0/20).

⚠️ НЕ добавлять туда диапазоны Cloudflare (104.16.0.0/13, 172.64.0.0/13):
CF-пин уводит мимо vpn-split весь Cloudflare-трафик, включая
`auth.openai.com` — Codex/ChatGPT получает 403 из-за выхода с RU-IP
(cf-ray …-DME). CF-домены провайдера и так ходят напрямую через
sing-box (`final: direct`), пин им не нужен.

## Что не хранится в репо

`/etc/vpn-split/vpn-split.conf` в репо НЕ хранится: файл содержит токен
подписки и имеет права 0600. Нестандартные параметры смотрите в
`etc/vpn-split.conf.example`.

`~/.config/tg-ws-proxy/env` в репо НЕ хранится: содержит `TG_SECRET`.
Структура — `tg-ws-proxy.env.example`.
