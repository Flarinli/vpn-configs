#!/bin/bash
# Установка сплит-TUN (sing-box) поверх ядра Happ (socks 127.0.0.1:10808).
# Через VPN идут ТОЛЬКО заблокированные в РФ ресурсы (runetfreedom ru-blocked,
# 1.3+ млн доменов + 89 тыс. подсетей) и пользовательские URL (sudo vpn-urls add ...).
# Happ должен работать БЕЗ своего TUN (Настройки → Advanced → TUN выключен),
# в режиме прокси (socks на 127.0.0.1:10808 — порт по умолчанию у Happ).
# Запуск от root: sudo bash install.sh
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "== 1/5: бинарник sing-box и rule-set'ы =="
HAPP_SINGBOX=/Applications/Happ.app/Contents/MacOS/tun/sing-box
if [[ -x "$HAPP_SINGBOX" ]]; then
  install -m 755 "$HAPP_SINGBOX" /usr/local/bin/sing-box
elif command -v sing-box >/dev/null 2>&1; then
  echo "используется уже установленный sing-box: $(command -v sing-box)"
else
  echo "не найден sing-box (ни в Happ.app, ни в PATH)." >&2
  echo "поставьте вручную (brew install sing-box) и повторите." >&2
  exit 1
fi
mkdir -p /usr/local/etc/singbox-tun/rules
install -m 644 "$SRC/rules/geosite-ru-blocked.srs" /usr/local/etc/singbox-tun/rules/
install -m 644 "$SRC/rules/geoip-ru-blocked.srs" /usr/local/etc/singbox-tun/rules/

echo "== 2/5: конфиг TUN =="
install -m 644 "$SRC/config.json" /usr/local/etc/singbox-tun/config.json
/usr/local/bin/sing-box check -c /usr/local/etc/singbox-tun/config.json && echo "конфиг валиден"

echo "== 3/5: helper vpn-urls =="
install -m 755 "$SRC/vpn-urls.sh" /usr/local/bin/vpn-urls

echo "== 4/5: LaunchDaemon =="
install -m 644 "$SRC/com.singbox.tun.plist" /Library/LaunchDaemons/com.singbox.tun.plist
launchctl bootstrap system /Library/LaunchDaemons/com.singbox.tun.plist 2>/dev/null \
  || launchctl kickstart -k system/com.singbox.tun

echo "== 5/5: проверка TUN =="
sleep 4
launchctl print system/com.singbox.tun 2>/dev/null | grep -E '^\s*(state|pid)' || true
ifconfig | grep -A2 utun | head -6 || true
echo
echo "ВАЖНО: в Happ выключите собственный TUN (Настройки → Advanced → TUN off)"
echo "и подключитесь обычным способом (ядро Happ должно слушать socks 127.0.0.1:10808)."
echo
echo "Проверка после подключения Happ:"
echo "  curl --noproxy '*' -s https://api.ipify.org            # RU IP = остальное напрямую"
echo "  curl --noproxy '*' -sI https://www.instagram.com/      # 200 = заблокированные через VPN"
echo "Свои URL:  sudo vpn-urls add example.com   |   sudo vpn-urls list"
