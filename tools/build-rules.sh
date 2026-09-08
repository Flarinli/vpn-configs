#!/bin/bash
# Пересобирает rule-set'ы sing-box (geosite-ru-blocked.srs, geoip-ru-blocked.srs)
# из свежих списков блокировок runetfreedom и раскладывает их в macos/rules и linux/rules.
#
# Источник: https://github.com/runetfreedom/russia-blocked-geosite (ru-blocked-all.txt)
#           https://github.com/runetfreedom/russia-blocked-geoip   (geoip.dat, v2ray-формат)
#
# Нужен sing-box (для `sing-box rule-set compile`) и python3. Запуск без sudo.
#   bash build-rules.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SINGBOX=$(command -v sing-box || true)
if [[ -z "$SINGBOX" && -x /Applications/Happ.app/Contents/MacOS/tun/sing-box ]]; then
  SINGBOX=/Applications/Happ.app/Contents/MacOS/tun/sing-box
fi
[[ -n "$SINGBOX" ]] || { echo "нужен sing-box в PATH (или Happ.app на macOS)" >&2; exit 1; }
echo "sing-box: $SINGBOX ($($SINGBOX version | head -1))"

echo "== 1/4: скачивание списков ru-blocked-all (домены) и geoip.dat (подсети) =="
curl -sL --max-time 300 -o "$WORK/ru-blocked-all.txt" \
  'https://github.com/runetfreedom/russia-blocked-geosite/releases/latest/download/ru-blocked-all.txt'
curl -sL --max-time 300 -o "$WORK/geoip.dat" \
  'https://github.com/runetfreedom/russia-blocked-geoip/releases/latest/download/geoip.dat'
wc -l "$WORK/ru-blocked-all.txt"
ls -la "$WORK/geoip.dat"

echo "== 2/4: домены -> rule-set json =="
# Ресурсы вне списка runetfreedom, которые тоже должны идти через VPN —
# переживают пересборку списка блокировок.
EXTRA_PROXY_DOMAINS=(
  "ggsel.net"
  "ggsel.com"
)
python3 - "$WORK/ru-blocked-all.txt" "$WORK/rules-geosite.json" "${EXTRA_PROXY_DOMAINS[@]}" <<'PY'
import json, sys
src, dst, *extra = sys.argv[1:]
suffixes = set()
with open(src, encoding='utf-8', errors='ignore') as f:
    for line in f:
        line = line.strip()
        if line.startswith('domain:'):
            d = line[7:].strip().lower()
        elif line.startswith('full:'):
            d = line[5:].strip().lower()
        else:
            continue
        if d and all(ord(c) < 128 for c in d):
            suffixes.add(d)
suffixes.update(x.lower() for x in extra)
print("уникальных доменов:", len(suffixes), f"(+{len(extra)} вручную добавленных)")
json.dump({"version": 3, "rules": [{"domain_suffix": sorted(suffixes)}]}, open(dst, "w"))
PY

echo "== 3/4: подсети (protobuf geoip.dat) -> rule-set json =="
python3 - "$WORK/geoip.dat" "$WORK/rules-geoip.json" <<'PY'
import json, sys

def read_varint(buf, pos):
    result = 0; shift = 0
    while True:
        b = buf[pos]; pos += 1
        result |= (b & 0x7f) << shift
        if not (b & 0x80): break
        shift += 7
    return result, pos

def parse_fields(buf, start, end):
    pos = start
    while pos < end:
        key, pos = read_varint(buf, pos)
        fnum, wtype = key >> 3, key & 7
        if wtype == 0:
            val, pos = read_varint(buf, pos)
        elif wtype == 2:
            ln, pos = read_varint(buf, pos)
            val = buf[pos:pos+ln]; pos += ln
        elif wtype == 5:
            val = buf[pos:pos+4]; pos += 4
        else:
            raise ValueError(f"wtype {wtype}")
        yield fnum, wtype, val

src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
targets = {}
for fnum, wt, entry in parse_fields(data, 0, len(data)):
    if fnum != 1 or wt != 2: continue
    cc = None; cidrs = []
    for f2, w2, v2 in parse_fields(entry, 0, len(entry)):
        if f2 == 1 and w2 == 2: cc = v2.decode()
        elif f2 == 2 and w2 == 2:
            ip = b''; prefix = 0
            for f3, w3, v3 in parse_fields(v2, 0, len(v2)):
                if f3 == 1 and w3 == 2: ip = v3
                elif f3 == 2 and w3 == 0: prefix = v3
            cidrs.append((ip, prefix))
    if cc: targets[cc.upper()] = cidrs

merged = targets.get('RU-BLOCKED', []) + targets.get('RU-BLOCKED-COMMUNITY', [])
cidr_list = [f"{ip[0]}.{ip[1]}.{ip[2]}.{ip[3]}/{p}" for ip, p in merged if len(ip) == 4]
print("IPv4 подсетей:", len(cidr_list))
json.dump({"version": 3, "rules": [{"ip_cidr": cidr_list}]}, open(dst, "w"))
PY

echo "== 4/4: компиляция в .srs и раскладка по macos/linux =="
"$SINGBOX" rule-set compile "$WORK/rules-geosite.json" -o "$WORK/geosite-ru-blocked.srs"
"$SINGBOX" rule-set compile "$WORK/rules-geoip.json" -o "$WORK/geoip-ru-blocked.srs"
for d in "$ROOT/macos/rules" "$ROOT/linux/rules"; do
  mkdir -p "$d"
  cp "$WORK/geosite-ru-blocked.srs" "$WORK/geoip-ru-blocked.srs" "$d/"
done
ls -la "$ROOT/macos/rules" "$ROOT/linux/rules"
echo "готово — не забудьте переустановить (install.sh) и перезапустить демон на каждой машине."
