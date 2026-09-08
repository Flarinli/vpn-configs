#!/bin/bash
# Установка сплит-TUN (sing-box) поверх системного xray от vpn-autoselect (socks 127.0.0.1:20808).
# Через VPN идут ТОЛЬКО заблокированные в РФ ресурсы (runetfreedom ru-blocked,
# 1.3+ млн доменов + 89 тыс. подсетей) и пользовательские URL (sudo vpn-urls add ...).
# Предполагается, что vpn-autoselect (xray + подписка) уже установлен и слушает 127.0.0.1:20808
# (см. https://github.com/<vpn-autoselect> — на этой машине это systemd unit xray.service).
# Запуск от root: sudo bash install.sh
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.12.12}"

echo "== 1/6: бинарник sing-box =="
if command -v sing-box >/dev/null 2>&1; then
  echo "используется уже установленный sing-box: $(command -v sing-box) ($(sing-box version | head -1))"
else
  case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *) echo "неизвестная архитектура $(uname -m)" >&2; exit 1 ;;
  esac
  TMP=$(mktemp -d)
  URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${ARCH}.tar.gz"
  echo "скачиваю $URL"
  curl -sL "$URL" -o "$TMP/sing-box.tar.gz"
  tar -xzf "$TMP/sing-box.tar.gz" -C "$TMP"
  install -m 755 "$TMP"/sing-box-*/sing-box /usr/local/bin/sing-box
  rm -rf "$TMP"
fi

echo "== 2/6: rule-set'ы =="
mkdir -p /usr/local/etc/singbox-tun/rules
install -m 644 "$SRC/rules/geosite-ru-blocked.srs" /usr/local/etc/singbox-tun/rules/
install -m 644 "$SRC/rules/geoip-ru-blocked.srs" /usr/local/etc/singbox-tun/rules/

echo "== 3/6: конфиг TUN =="
DEFAULT_IFACE="$(ip -4 route show default | head -1 | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')"
if [ -z "$DEFAULT_IFACE" ]; then
  echo "не удалось определить дефолтный сетевой интерфейс (ip route show default пуст)" >&2
  exit 1
fi
echo "дефолтный интерфейс: $DEFAULT_IFACE"
sed "s/__DEFAULT_IFACE__/$DEFAULT_IFACE/" "$SRC/config.json" > /usr/local/etc/singbox-tun/config.json
chmod 644 /usr/local/etc/singbox-tun/config.json
/usr/local/bin/sing-box check -c /usr/local/etc/singbox-tun/config.json && echo "конфиг валиден"

echo "== 4/6: helper vpn-urls =="
install -m 755 "$SRC/vpn-urls.sh" /usr/local/bin/vpn-urls

echo "== 5/6: systemd unit =="
install -m 644 "$SRC/singbox-tun.service" /etc/systemd/system/singbox-tun.service
systemctl daemon-reload
systemctl enable --now singbox-tun

echo "== 6/6: проверка TUN =="
sleep 3
systemctl --no-pager status singbox-tun | head -8
ip link show | grep -A1 tun || true
echo
echo "Проверка (нужен живой xray на 127.0.0.1:20808 — vpn-autoselect):"
echo "  curl --noproxy '*' -s https://api.ipify.org            # RU IP = остальное напрямую"
echo "  curl --noproxy '*' -sI https://www.instagram.com/      # 200 = заблокированные через VPN"
echo "Свои URL:  sudo vpn-urls add example.com   |   sudo vpn-urls list"
