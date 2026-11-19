#!/bin/bash
# Telegram MTProto proxy: держим маршруты к TG DC и Cloudflare-фронтам
# напрямую через физический интерфейс (шлюз default-маршрута),
# чтобы прокси не зависел от VPN-туннелей (utun).
GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')
[ -z "$GW" ] && exit 0
NETS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22"
for net in $NETS; do
  /sbin/route add -net "$net" "$GW" 2>/dev/null || /sbin/route change -net "$net" "$GW" 2>/dev/null
done
exit 0
