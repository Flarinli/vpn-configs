#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
amnezia-export.py — выгрузить серверы AmneziaVPN в nodes.txt для vpn-split.

Читает настройки AmneziaVPN (macOS plist / Linux JSON) и пишет список
vless:// vmess:// trojan:// ss:// — формат, который ест vpn-autoselect.

  python3 tools/amnezia-export.py -o /tmp/amnezia-nodes.txt

Потом:
  sudo cp /tmp/amnezia-nodes.txt /etc/vpn-split/nodes.txt
  # в vpn-split.conf: NODES_FILE=/etc/vpn-split/nodes.txt  (SUB_URL пусто)
  sudo vpn-autoselect --force
"""

import argparse
import base64
import json
import os
import plistlib
import subprocess
import sys
import urllib.parse


def load_macos():
    r = subprocess.run(
        ["defaults", "export", "org.amneziavpn.AmneziaVPN", "-"],
        capture_output=True,
    )
    if r.returncode != 0 or not r.stdout:
        raise SystemExit("не удалось прочитать org.amneziavpn.AmneziaVPN: %s" % r.stderr.decode())
    d = plistlib.loads(r.stdout)
    raw = d.get("Servers/serversList") or d.get("Servers.serversList")
    if isinstance(raw, bytes):
        return json.loads(raw)
    raise SystemExit("Servers/serversList не найден")


def load_linux():
    home = os.path.expanduser("~")
    candidates = [
        os.path.join(home, ".config", "AmneziaVPN", "servers.json"),
        os.path.join(home, ".config", "AmneziaVPN", "AmneziaVPN.conf"),
        os.path.join(home, ".local", "share", "AmneziaVPN", "servers.json"),
        "/opt/AmneziaVPN/servers.json",
    ]
    for p in candidates:
        if not os.path.exists(p):
            continue
        text = open(p, encoding="utf-8", errors="replace").read()
        if text.lstrip().startswith("["):
            try:
                return json.loads(text)
            except ValueError:
                pass
    raise SystemExit(
        "Не нашёл серверы Amnezia на Linux. Экспортируйте конфиг из GUI "
        "(или скопируйте servers.json) и положите в ~/.config/AmneziaVPN/servers.json"
    )


def qenc(s):
    return urllib.parse.quote(str(s), safe="")


def uri_from_xray_config(cfg, name):
    ob = cfg["outbounds"][0]
    st = ob.get("streamSettings", {}) or {}
    if ob["protocol"] == "vless":
        vn = ob["settings"]["vnext"][0]
        u = vn["users"][0]
        q = {"encryption": "none"}
        if u.get("flow"):
            q["flow"] = u["flow"]
        sec = st.get("security", "none") or "none"
        q["security"] = sec
        net = st.get("network", "tcp") or "tcp"
        q["type"] = net
        if sec == "reality":
            rs = st.get("realitySettings", {}) or {}
            q["sni"] = rs.get("serverName", "")
            q["fp"] = rs.get("fingerprint", "chrome")
            q["pbk"] = rs.get("publicKey", "")
            q["sid"] = rs.get("shortId", "")
        elif sec == "tls":
            ts = st.get("tlsSettings", {}) or {}
            q["sni"] = ts.get("serverName", "")
            q["fp"] = ts.get("fingerprint", "")
        if net == "grpc":
            g = st.get("grpcSettings", {}) or {}
            q["path"] = g.get("serviceName", "")
            if g.get("multiMode"):
                q["mode"] = "multi"
        if net == "ws":
            w = st.get("wsSettings", {}) or {}
            q["path"] = w.get("path", "/")
            q["host"] = (w.get("headers") or {}).get("Host", "")
        if net in ("xhttp", "splithttp"):
            x = st.get("xhttpSettings", {}) or {}
            q["path"] = x.get("path", "/")
            q["host"] = x.get("host", "")
            q["mode"] = x.get("mode", "auto")
        qs = "&".join("%s=%s" % (k, qenc(v)) for k, v in q.items() if v not in (None, ""))
        return "vless://%s@%s:%s?%s#%s" % (u["id"], vn["address"], vn["port"], qs, qenc(name))
    if ob["protocol"] == "vmess":
        vn = ob["settings"]["vnext"][0]
        net = st.get("network", "tcp") or "tcp"
        header = ""
        if net == "tcp" and (st.get("tcpSettings", {}) or {}).get("header", {}).get("type") == "http":
            header = "http"
        j = {
            "v": "2",
            "ps": name,
            "add": vn["address"],
            "port": str(vn["port"]),
            "id": vn["users"][0]["id"],
            "aid": "0",
            "scy": vn["users"][0].get("security", "auto"),
            "net": net,
            "type": header,
            "host": "",
            "path": "",
            "tls": st.get("security", "") if st.get("security") not in (None, "none") else "",
        }
        if st.get("tlsSettings", {}).get("serverName"):
            j["sni"] = st["tlsSettings"]["serverName"]
        b = base64.b64encode(json.dumps(j).encode()).decode()
        return "vmess://" + b
    if ob["protocol"] == "trojan":
        srv = ob["settings"]["servers"][0]
        q = {
            "security": st.get("security", "tls") or "tls",
            "type": st.get("network", "tcp") or "tcp",
        }
        if st.get("tlsSettings", {}).get("serverName"):
            q["sni"] = st["tlsSettings"]["serverName"]
        if st.get("wsSettings"):
            q["path"] = st["wsSettings"].get("path", "/")
            q["host"] = (st["wsSettings"].get("headers") or {}).get("Host", "")
        qs = "&".join("%s=%s" % (k, qenc(v)) for k, v in q.items() if v)
        return "trojan://%s@%s:%s?%s#%s" % (
            qenc(srv["password"]), srv["address"], srv["port"], qs, qenc(name),
        )
    return None


def uri_from_ss(cfg, name):
    ob = cfg["outbounds"][0]
    srv = ob["settings"]["servers"][0]
    return "ss://%s@%s:%s#%s" % (
        qenc("%s:%s" % (srv["method"], srv["password"])),
        srv["address"], srv["port"], qenc(name),
    )


def collect(servers):
    uris = []
    for s in servers:
        name = s.get("description") or s.get("hostName") or "amnezia"
        for c in s.get("containers", []):
            cont = c.get("container")
            if cont == "amnezia-xray":
                cfg = json.loads(c["xray"]["last_config"])
                u = uri_from_xray_config(cfg, name)
                if u:
                    uris.append(u)
            elif cont == "amnezia-ssxray":
                cfg = json.loads(c["ssxray"]["last_config"])
                uris.append(uri_from_ss(cfg, name + " SS"))
            elif cont in ("amnezia-wireguard", "amnezia-awg"):
                print("[skip] %s: %s — WireGuard/AWG не конвертируется в xray URI" % (name, cont),
                      file=sys.stderr)
    return uris


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default="/tmp/amnezia-nodes.txt")
    ap.add_argument("--os", choices=("auto", "macos", "linux"), default="auto")
    a = ap.parse_args()
    if a.os == "macos" or (a.os == "auto" and sys.platform == "darwin"):
        servers = load_macos()
    else:
        servers = load_linux()
    uris = collect(servers)
    if not uris:
        raise SystemExit("ни одного xray/ss узла не выгружено")
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write("\n".join(uris) + "\n")
    print("узлов: %d -> %s" % (len(uris), a.out))


if __name__ == "__main__":
    main()
