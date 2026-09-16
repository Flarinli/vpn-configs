# macOS — сплит-VPN (sing-box TUN + системный xray + автоселект ноды)

## Как работает

- sing-box TUN (LaunchDaemon `com.singbox.tun`) пускает напрямую всё, кроме ru-blocked.
- ru-blocked-трафик уходит в socks `127.0.0.1:20808` — системный xray
  (LaunchDaemon `local.xray`, ставится из brew).
- `vpn-autoselect` (launchd `local.vpn-autoselect`, каждые 10 мин) тянет подписку,
  обновляет список нод xray; выбор ноды — leastPing внутри xray, пробник —
  `https://www.youtube.com/generate_204` (нода обязана открывать запрещённые ресурсы).
- Happ не используется. Откат на старый Happ-вариант:
  `sudo bash install.sh rollback` (конфиг TUN восстанавливается из `config.json.happ.bak`).

## Предпосылки

- Подписка VPN (URL в `/usr/local/etc/vpn-autoselect.conf`).
- Homebrew.

## Установка

```bash
sudo bash install.sh
```

Скрипт:
1. Ставит `sing-box` (brew) и `xray` (brew).
2. Кладёт `rules/*.srs`, `config.json` (proxy → 20808) в `/usr/local/etc/singbox-tun/`.
3. Ставит helper `vpn-urls` и `vpn-autoselect` в `/usr/local/bin/`.
4. Регистрирует LaunchDaemons: `com.singbox.tun`, `local.xray`,
   `local.vpn-autoselect` (таймер обновления подписки).
5. Перед первым запуском впиши `SUB_URL` в `/usr/local/etc/vpn-autoselect.conf`,
   если его там ещё нет (при установке создаётся из `autoselect/vpn-autoselect.conf.example`).

Старый конфиг TUN сохраняется в `config.json.happ.bak` (для rollback).

## Проверка

```bash
launchctl print system/com.singbox.tun | grep -E 'state|pid'
curl --noproxy '*' -s https://api.ipify.org             # RU IP = остальное напрямую
curl --noproxy '*' -sI https://www.instagram.com/ | head -1  # 200 = заблокированные через VPN
tail -f /var/log/singbox-tun.log
```

## Управление списком URL

```bash
sudo vpn-urls add netflix.com
sudo vpn-urls add direct:example.com
sudo vpn-urls remove netflix.com
vpn-urls list
```

## Обновление / переустановка

Повторный запуск `sudo bash install.sh` безопасен — перезаписывает конфиг и
перезапускает демон. Если меняли списки URL через `vpn-urls`, переустановка
их не потрёт (правки в `/usr/local/etc/singbox-tun/config.json`, а не в
исходниках репозитория) — но и не сохранит при переносе на другую машину,
переносите вручную при необходимости.

## Если что-то пошло не так

- **Диалог пароля sudo не появляется / зависает** — типичная проблема
  `osascript ... with administrator privileges` в некоторых терминалах.
  Надёжнее выполнять `sudo` команды напрямую в интерактивном терминале.
- **Весь трафик идёт через VPN** — проверьте, что TUN в Happ выключен
  (см. «Предпосылки» выше); встроенная маршрутизация Happ (`routing.json`)
  в TUN-режиме не применяется — это ограничение самого приложения.
- **`mos.ru` и похожие ругаются на TLS** — нужен сертификат НУЦ Минцифры,
  к сплиту отношения не имеет.
