#!/usr/bin/env bash
# Проверка репозитория (CI job check, запускается и локально без sudo):
#   1. синтаксис shell (bash -n, shellcheck если есть) и Python (py_compile);
#   2. тесты tests/ (stdlib unittest, без сети);
#   3. поэтапная установка в DESTDIR: качает sing-box и xray закреплённых
#      версий под текущую ОС и сверяет sha256 из versions.env;
#   4. конфиг sing-box для linux и darwin -> `sing-box check` (вместе с rule-set'ами);
#   5. конфиг xray из tests/nodes.txt -> `xray run -test`.
# Так обновление версий в PR «VPN updates» проверяется на реальных бинарниках.
#   tools/check.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PY="${PYTHON:-python3}"

step() { printf '\n== %s\n' "$*"; }

step "shell: bash -n, shellcheck"
shells="install.sh lib/download.sh libexec/vpn-split-update tools/build-rules.sh tools/update-versions.sh tools/check.sh"
for f in $shells; do bash -n "$f"; done
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  shellcheck -x -S warning $shells  # info/style отличаются между версиями shellcheck
else
  echo "shellcheck не найден — пропускаю"
fi

step "python: py_compile"
for f in lib/vpnsplit.py libexec/render-config libexec/vpn-autoselect libexec/migrate-legacy \
         bin/vpn-urls tools/updates.py; do
  "$PY" -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f"
done

step "тесты"
"$PY" -m unittest discover -s tests

step "поэтапная установка (DESTDIR)"
D="$WORK/stage"
DESTDIR="$D" ./install.sh --no-deps -y >"$WORK/install.log" 2>&1 || { cat "$WORK/install.log"; exit 1; }
P="$D/opt/vpn-split"
"$P/bin/sing-box" version | head -1
"$P/bin/xray" version | head -1
[[ -f $P/share/source-rev ]] && echo "source-rev: $(cat "$P/share/source-rev")"
if [[ -e .git ]]; then  # из клона ставится и таймер автообновления
  case "$(uname -s)" in
    Linux)  ls "$D"/etc/systemd/system/vpn-split-update.{service,timer} ;;
    Darwin) ls "$D"/Library/LaunchDaemons/io.github.flarinli.vpn-split.update.plist ;;
  esac
fi

export VPN_SPLIT_SYSCONFDIR="$D/etc/vpn-split" VPN_SPLIT_STATEDIR="$D/var/lib/vpn-split"
export VPN_SPLIT_CONF="$D/etc/vpn-split/vpn-split.conf"

step "sing-box check (linux, darwin)"
for os in linux darwin; do
  "$PY" "$P/libexec/render-config" --os "$os" --iface lo --stdout >"$WORK/singbox-$os.json"
  "$P/bin/sing-box" check -c "$WORK/singbox-$os.json"
  echo "$os: ok"
done

step "xray run -test (tests/nodes.txt)"
"$PY" - "$P/libexec/vpn-autoselect" "$ROOT/tests/nodes.txt" "$WORK/xray.json" <<'PY'
import importlib.machinery, importlib.util, json, sys
src, nodes, out = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("autoselect", src)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("autoselect", loader))
loader.exec_module(mod)
mod.CFG = mod.vpnsplit.load_settings()
mod.CFG["DIRECT_DOMAINS"] = "corp.lan,full:intranet.example"
uris = mod.extract_uris(open(nodes, encoding="utf-8").read())
top = []
for i, u in enumerate(uris, 1):
    r = mod.parse_uri(u)
    assert r, "не распарсился: " + u
    name, host, port, ob = r
    ob["tag"] = "node-%02d" % i
    top.append({"name": name, "host": host, "port": port, "outbound": ob})
json.dump(mod.build_config(top, None), open(out, "w"), indent=1)
ok, msg = mod.xray_validate(out)
print("%d узлов: %s" % (len(top), "ok" if ok else msg))
sys.exit(0 if ok else 1)
PY

step "vpn-split-update: fast-forward и переустановка только при новом коммите"
# origin -> клон; вместо install.sh в клоне заглушка, которая пишет source-rev
U="$WORK/update"
commit() { git -C "$U/clone" -c user.name=t -c user.email=t@t commit -q "$@"; }
git init -q --bare -b main "$U/origin.git"
git clone -q "$U/origin.git" "$U/clone" 2>/dev/null
git -C "$U/clone" checkout -q -b main
cat >"$U/clone/install.sh" <<EOF
#!/bin/sh
git -C "$U/clone" rev-parse HEAD > "$U/prefix/share/source-rev"; echo installed >> "$U/installs"
EOF
chmod +x "$U/clone/install.sh"
git -C "$U/clone" add install.sh
commit -m stub
git -C "$U/clone" push -q origin main
mkdir -p "$U/prefix/libexec" "$U/prefix/share"
cp libexec/vpn-split-update "$U/prefix/libexec/"
echo "SRC_DIR=$U/clone" >"$U/prefix/share/layout.env"
upd() { TMPDIR="$U" "$U/prefix/libexec/vpn-split-update"; }
installs() { wc -l <"$U/installs" 2>/dev/null | tr -d ' ' || echo 0; }
upd >/dev/null; [[ $(installs) == 1 ]] || { echo "первый запуск должен установить"; exit 1; }
upd >/dev/null; [[ $(installs) == 1 ]] || { echo "без нового коммита переустановки быть не должно"; exit 1; }
# новый коммит в origin из другого клона
git clone -q "$U/origin.git" "$U/other"
git -C "$U/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
git -C "$U/other" push -q origin main
echo dirty >>"$U/clone/install.sh"
upd >/dev/null; [[ $(installs) == 1 ]] || { echo "грязный клон нельзя обновлять"; exit 1; }
git -C "$U/clone" checkout -q install.sh
upd
[[ $(installs) == 2 ]] || { echo "новый коммит в origin должен переустановить"; exit 1; }
[[ $(git -C "$U/clone" log -1 --format=%s) == two ]] || { echo "клон не подтянут"; exit 1; }
echo "ok"

step "готово"
