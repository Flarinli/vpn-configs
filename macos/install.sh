#!/bin/bash
# Установка сплит-TUN (sing-box) + системный xray + vpn-autoselect — паритет с Linux.
# Через VPN идут ТОЛЬКО заблокированные в РФ ресурсы (runetfreedom ru-blocked)
# и пользовательские URL (sudo vpn-urls add ...). Нода выбирается автоматически
# (leastPing) из подписки; Happ не используется.
#
#   sudo bash install.sh            # установить/обновить
#   sudo bash install.sh rollback   # откат: Happ-вариант (socks 127.0.0.1:10808)
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
AUTOSEL_SRC="$(cd "$SRC/../autoselect" && pwd)"

XRAY_BIN=/opt/homebrew/bin/xray
SB_CONF=/usr/local/etc/singbox-tun/config.json
XRAY_DIR=/usr/local/etc/xray
LOG_DIR=/usr/local/var/log

if [[ "${1:-}" == "rollback" ]]; then
  echo "== откат на Happ-вариант =="
  launchctl bootout system/local.vpn-autoselect 2>/dev/null || true
  launchctl bootout system/local.xray 2>/dev/null || true
  if [[ -f "$SB_CONF.happ.bak" ]]; then
    cp "$SB_CONF.happ.bak" "$SB_CONF"
    /usr/local/bin/sing-box check -c "$SB_CONF"
  fi
  launchctl kickstart -k system/com.singbox.tun
  echo "готово: TUN снова смотрит на 127.0.0.1:10808."
  echo "xray/vpn-autoselect выгружены, файлы конфигов не тронуты."
  echo "Подключите Happ (socks 127.0.0.1:10808)."
  exit 0
fi

echo "== 1/8: sing-box =="
if [[ ! -x /usr/local/bin/sing-box ]]; then
  echo "ставлю sing-box (brew)"; brew install sing-box
fi
HAPP_SINGBOX=/Applications/Happ.app/Contents/MacOS/tun/sing-box
[[ -x /usr/local/bin/sing-box ]] || { [[ -x "$HAPP_SINGBOX" ]] && sudo install -m 755 "$HAPP_SINGBOX" /usr/local/bin/sing-box; }
/usr/local/bin/sing-box version | head -1

echo "== 2/8: xray (brew) =="
if [[ ! -x "$XRAY_BIN" ]]; then
  brew install xray
fi
"$XRAY_BIN" version | head -1

echo "== 3/8: rule-set'ы =="
mkdir -p /usr/local/etc/singbox-tun/rules "$XRAY_DIR" "$LOG_DIR"
install -m 644 "$SRC/rules/geosite-ru-blocked.srs" /usr/local/etc/singbox-tun/rules/
install -m 644 "$SRC/rules/geoip-ru-blocked.srs" /usr/local/etc/singbox-tun/rules/

echo "== 4/8: конфиг TUN (proxy -> 20808, бэкап старого) =="
[[ -f "$SB_CONF" && ! -f "$SB_CONF.happ.bak" ]] && cp "$SB_CONF" "$SB_CONF.happ.bak"
install -m 644 "$SRC/config.json" "$SB_CONF"
/usr/local/bin/sing-box check -c "$SB_CONF" && echo "конфиг валиден"

echo "== 5/8: helper vpn-urls =="
install -m 755 "$SRC/vpn-urls.sh" /usr/local/bin/vpn-urls

echo "== 6/8: vpn-autoselect =="
install -m 755 "$AUTOSEL_SRC/vpn-autoselect" /usr/local/bin/vpn-autoselect
mkdir -p /usr/local/etc /usr/local/var/vpn-autoselect
if [[ ! -f /usr/local/etc/vpn-autoselect.conf ]]; then
  install -m 600 "$AUTOSEL_SRC/vpn-autoselect.conf.example" /usr/local/etc/vpn-autoselect.conf
  echo "ВНИМАНИЕ: впиши SUB_URL в /usr/local/etc/vpn-autoselect.conf и перезапусти установку"
fi

echo "== 7/8: LaunchDaemons =="
install -m 644 "$SRC/autoselect/com.local.xray.plist" /Library/LaunchDaemons/com.local.xray.plist
install -m 644 "$SRC/autoselect/com.local.vpn-autoselect.plist" /Library/LaunchDaemons/com.local.vpn-autoselect.plist
launchctl bootstrap system /Library/LaunchDaemons/com.local.xray.plist 2>/dev/null || true
# первый прогон: генерирует конфиг xray из подписки (без рестарта — демон ещё не запущен)
/usr/local/bin/vpn-autoselect --force --no-restart
launchctl kickstart -k system/local.xray
launchctl bootstrap system /Library/LaunchDaemons/com.local.vpn-autoselect.plist 2>/dev/null \
  || launchctl kickstart -k system/local.vpn-autoselect

echo "== 8/8: рестарт TUN и проверка =="
launchctl bootstrap system /Library/LaunchDaemons/com.singbox.tun.plist 2>/dev/null \
  || launchctl kickstart -k system/com.singbox.tun
sleep 4
launchctl print system/local.xray 2>/dev/null | grep -E '^\s*(state|pid)' || true
echo
echo "Проверка:"
echo "  curl --noproxy '*' -s https://api.ipify.org            # RU IP = остальное напрямую"
echo "  curl --noproxy '*' -sI https://www.instagram.com/      # 200 = заблокированные через VPN"
echo "  curl --noproxy '*' -sI --socks5-hostname 127.0.0.1:20808 https://www.youtube.com/ | head -1"
echo "Текущая нода: cat /usr/local/var/vpn-autoselect/status.json"
echo "Откат: sudo bash $SRC/install.sh rollback (и включить Happ)"
