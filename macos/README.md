# macOS — сплит-VPN поверх Happ

## Предпосылки

- Установлен [Happ](https://happ.su) с рабочей подпиской/сервером.
- **В Happ выключен собственный TUN**: Настройки → Advanced → TUN → off.
  Если TUN Happ включён, он перехватит весь системный трафик через `auto_route`,
  и наш сплит-демон работать не будет (два TUN конфликтуют).
- Happ подключается как обычно — его ядро при этом слушает
  `socks 127.0.0.1:10808` (порт по умолчанию), через который наш TUN
  отправляет заблокированные ресурсы.

## Установка

```bash
sudo bash install.sh
```

Скрипт:
1. Берёт бинарник `sing-box` из `Happ.app` (либо использует уже установленный
   в PATH — например, `brew install sing-box`).
2. Кладёт `rules/*.srs` и `config.json` в `/usr/local/etc/singbox-tun/`.
3. Ставит helper `vpn-urls` в `/usr/local/bin/`.
4. Регистрирует `com.singbox.tun.plist` как LaunchDaemon (root, автозапуск).

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
