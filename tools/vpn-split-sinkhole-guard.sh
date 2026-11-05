#!/bin/bash
# vpn-split sinkhole guard — отравленные корпоративным DNS sinkhole-IP
# (сюда резолвятся западные домены: chatgpt.com, drive.google.com, api.ipify.org, ...)
# направляются в TUN sing-box (table 2022), чтобы сработал sniff SNI и доменные правила
# (domains.proxy / PROXY_DOMAINS / rule-set) отправили трафик через прокси.
# Без этого трафик к sinkhole уходит по /32-пинам office-net-guard'а через
# офисный шлюз мимо TUN, и браузер ходит с RU-адреса (OpenAI: 403 "Unable to load site").
# Список SINKS пополняется при обнаружении новых отравленных IP:
#   getent ahosts <домен>  против  curl 'https://1.1.1.1/dns-query?name=<домен>&type=A'
# Деградация мягкая: при остановленном sing-box таблица 2022 пуста, lookup
# проваливается к следующим правилам — прямой ход как раньше.
# Идемпотентен. Синхронизирован с office-net-guard (dispatcher 70-*).
set -uo pipefail
RULE_PRIO="${RULE_PRIO:-8990}"
TABLE="${TABLE:-2022}"
SINKS=(8.6.112.0 8.47.69.0 193.58.251.4)
for ip in "${SINKS[@]}"; do
  ip rule show | grep -q "to $ip lookup $TABLE" || \
    ip rule add to "$ip" table "$TABLE" prio "$RULE_PRIO"
done
exit 0
