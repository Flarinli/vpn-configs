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

## Что не хранится в репо

`/etc/vpn-split/vpn-split.conf` в репо НЕ хранится: файл содержит токен
подписки и имеет права 0600. Нестандартные параметры смотрите в
`etc/vpn-split.conf.example`.
