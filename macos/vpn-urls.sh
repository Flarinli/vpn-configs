#!/bin/bash
# vpn-urls — управление списком URL/доменов для VPN поверх автоматического ru-blocked.
# Работает на macOS (launchd) и Linux (systemd) — определяет платформу сам.
# Использование (нужен sudo — рестартует TUN-демон):
#   sudo vpn-urls add openai.com claude.ai        # через VPN (домен и все поддомены)
#   sudo vpn-urls add direct:example.com          # наоборот: всегда напрямую
#   sudo vpn-urls remove openai.com
#   sudo vpn-urls list
set -euo pipefail

CONF=/usr/local/etc/singbox-tun/config.json
LBL=com.singbox.tun

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

restart_daemon() {
  if [[ "$(uname)" == "Darwin" ]]; then
    launchctl kickstart -k "system/$LBL"
  else
    systemctl restart singbox-tun
  fi
}

python_edit() {
  python3 - "$CONF" "$@" <<'PY'
import json, sys
conf, action, items = sys.argv[1], sys.argv[2], sys.argv[3:]
d = json.load(open(conf))
rules = d["route"]["rules"]

def user_proxy_rule():
    for r in rules:
        if r.get("outbound") == "proxy" and "domain_suffix" in r and "rule_set" not in r:
            return r
    r = {"domain_suffix": [], "outbound": "proxy"}
    idx = next((i for i, rr in enumerate(rules) if rr.get("outbound") == "proxy" and "rule_set" in rr), len(rules))
    rules.insert(idx, r)
    return r

def direct_rule():
    for r in rules:
        if r.get("outbound") == "direct" and "domain_suffix" in r:
            return r
    sys.exit("не найдено direct-правило в конфиге")

def norm(it):
    it = it.strip().lower()
    for p in ("http://", "https://"):
        if it.startswith(p): it = it[len(p):]
    return it.split("/")[0].lstrip("*.").rstrip(".")

for it in items:
    it = norm(it)
    if not it: continue
    if it.startswith("direct:"):
        dom, r = norm(it[7:]), direct_rule()
        if action == "add":
            if dom not in r["domain_suffix"]: r["domain_suffix"].append(dom)
        else:
            r["domain_suffix"] = [x for x in r["domain_suffix"] if x != dom]
    else:
        r = user_proxy_rule()
        if action == "add":
            if it not in r["domain_suffix"]: r["domain_suffix"].append(it)
        else:
            r["domain_suffix"] = [x for x in r["domain_suffix"] if x != it]
            if not r["domain_suffix"]:
                rules.remove(r)   # пустое правило в sing-box матчит всё — удаляем

json.dump(d, open(conf, "w"), indent=4, ensure_ascii=False)
PY
}

case "${1:-}" in
  add|remove)
    [[ $# -ge 2 ]] || usage
    if [[ $EUID -ne 0 ]]; then
      echo "запустите с sudo: sudo $0 $*" >&2; exit 1
    fi
    python_edit "$@"
    ;;
  list)
    python3 - "$CONF" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["route"]["rules"]:
    if r.get("outbound") == "proxy" and "rule_set" not in r:
        s = r.get("domain_suffix", [])
        print("через VPN (пользовательские):", ", ".join(s) if s else "—")
    if r.get("outbound") == "direct" and "domain_suffix" in r:
        s = [x for x in r["domain_suffix"] if x != "gosniias.lan"]
        if s: print("всегда напрямую (пользовательские):", ", ".join(s))
print("автоматически через VPN: все домены и подсети ru-blocked (runetfreedom, 1.3+ млн)")
PY
    exit 0
    ;;
  *) usage ;;
esac

/usr/local/bin/sing-box check -c "$CONF" || { echo "КОНФИГ НЕВАЛИДЕН: $CONF"; exit 1; }
restart_daemon
echo "готово: TUN-демон перезапущен"
vpn-urls list
