# -*- coding: utf-8 -*-
"""
vpnsplit — общий модуль vpn-split: раскладка путей, настройки, списки доменов,
сборка конфига sing-box и управление службами (systemd / launchd).

Ни одного жёстко прописанного пути к установке здесь нет:
  * PREFIX вычисляется от расположения самого модуля ($PREFIX/lib/vpnsplit.py);
  * остальная раскладка читается из $PREFIX/share/layout.env (его пишет install.sh);
  * любой ключ раскладки переопределяется переменной окружения VPN_SPLIT_<KEY>;
  * путь к настройкам — VPN_SPLIT_CONF или $SYSCONFDIR/vpn-split.conf.

Без аргументов модуль не запускается; CLI для install.sh:
  python3 vpnsplit.py set-conf FILE KEY=VALUE...   # правка KEY=VALUE с сохранением комментариев
  python3 vpnsplit.py get FILE KEY                 # значение ключа (для shell)
"""

import json
import os
import re
import subprocess
import sys
import tempfile

IS_MAC = sys.platform == "darwin"
OS_NAME = "darwin" if IS_MAC else "linux"

# ------------------------------------------------------------------ layout ---

PREFIX = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

LAYOUT_DEFAULTS = {
    "PREFIX": PREFIX,
    "SYSCONFDIR": "/etc/vpn-split",
    "STATEDIR": "/var/lib/vpn-split",
    "LOGDIR": "/var/log/vpn-split",
    "UNIT_PREFIX": "vpn-split",                    # systemd: vpn-split-<svc>.service
    "LABEL_PREFIX": "io.github.flarinli.vpn-split",  # launchd: <prefix>.<svc>
}


def parse_kv(path):
    """Читает KEY=VALUE (shell-подобный формат, без подстановок)."""
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            out[k] = v
    return out


def load_layout():
    lay = dict(LAYOUT_DEFAULTS)
    path = os.path.join(PREFIX, "share", "layout.env")
    if os.path.exists(path):
        lay.update({k: v for k, v in parse_kv(path).items() if k in lay or k == "PYTHON"})
        lay["PREFIX"] = PREFIX  # установка переносима: PREFIX всегда по факту
    for k in list(lay):
        env = os.environ.get("VPN_SPLIT_" + k)
        if env:
            lay[k] = env
    return lay


LAYOUT = load_layout()


def conf_path():
    return os.environ.get("VPN_SPLIT_CONF") or os.path.join(LAYOUT["SYSCONFDIR"], "vpn-split.conf")


# ---------------------------------------------------------------- settings ---

def default_settings():
    p, st = LAYOUT["PREFIX"], LAYOUT["STATEDIR"]
    return {
        # подписка
        "SUB_URL": "",
        "NODES_FILE": "",
        "SUB_TTL": "21600",
        "EXCLUDE_NAMES": "",
        "INCLUDE_NAMES": "",
        # проверка/выбор узлов
        "TEST_URL": "https://www.youtube.com/generate_204",
        "PROBE_URL": "https://www.youtube.com/generate_204",
        "PING_SAMPLES": "3",
        "PING_TIMEOUT": "2.0",
        "PING_TOP": "0",
        # локальные входы xray
        "SOCKS_PORT": "20808",
        "HTTP_PORT": "20809",
        # сеть
        "DEFAULT_IFACE": "auto",      # iface для прямого трафика sing-box (Linux)
        "DIRECT_IFACE": "auto",       # iface для прямых запросов autoselect (подписка/пинг)
        "ROUTING_MARK": "36864",      # Linux: default_mark sing-box
        "DNS_DIRECT": "77.88.8.8",
        "DNS_PROXY": "1.1.1.1",
        "DNS_PROXY_DOMAINS": "youtube.com,rutracker.org",
        "DIRECT_DOMAINS": "",
        "LOG_LEVEL": "info",
        # пути (по умолчанию выводятся из раскладки, переопределять обычно не нужно)
        "SINGBOX_BIN": os.path.join(p, "bin", "sing-box"),
        "XRAY_BIN": os.path.join(p, "bin", "xray"),
        "XRAY_ASSET_DIR": os.path.join(p, "share", "xray"),
        "RULES_DIR": os.path.join(p, "share", "rules"),
        "SINGBOX_TEMPLATE": os.path.join(p, "share", "singbox.json.tmpl"),
        "SINGBOX_CONF": os.path.join(st, "singbox.json"),
        "XRAY_CONF": os.path.join(st, "xray.json"),
        "STATUS_DIR": st,
        "CURL_BIN": "",               # пусто = найти в PATH
    }


# старые имена ключей (vpn-autoselect.conf до vpn-split)
LEGACY_KEYS = {"IN_SOCKS_PORT": "SOCKS_PORT", "IN_HTTP_PORT": "HTTP_PORT"}


def load_settings(path=None):
    cfg = default_settings()
    path = path or conf_path()
    if path and os.path.exists(path):
        for k, v in parse_kv(path).items():
            k = LEGACY_KEYS.get(k, k)
            if k in cfg:
                cfg[k] = v
    return cfg


def split_list(value):
    return [x.strip() for x in re.split(r"[,\s]+", value or "") if x.strip()]


def set_conf_values(path, values):
    """Меняет/добавляет KEY=VALUE в файле, сохраняя комментарии и права."""
    lines = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    left = dict(values)
    for i, line in enumerate(lines):
        m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
        if m and m.group(1) in left:
            lines[i] = "%s=%s" % (m.group(1), left.pop(m.group(1)))
    lines += ["%s=%s" % kv for kv in left.items()]
    atomic_write(path, "\n".join(lines) + "\n", mode=0o600)


# ------------------------------------------------------------ domain lists ---

def domains_file(kind):
    """kind: proxy | direct."""
    return os.path.join(LAYOUT["SYSCONFDIR"], "domains." + kind)


def read_domains(kind):
    path = domains_file(kind)
    if not os.path.exists(path):
        return []
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            d = line.split("#", 1)[0].strip()
            if d and d not in out:
                out.append(d)
    return out


def write_domains(kind, items):
    header = ("# vpn-split: пользовательские домены (%s). По одному на строку,\n"
              "# домен действует со всеми поддоменами. Правьте через vpn-urls.\n") % (
        "через VPN" if kind == "proxy" else "всегда напрямую")
    atomic_write(domains_file(kind), header + "".join(d + "\n" for d in items), mode=0o644)


def normalize_domain(it):
    it = it.strip().lower()
    for p in ("http://", "https://"):
        if it.startswith(p):
            it = it[len(p):]
    return it.split("/")[0].lstrip("*.").rstrip(".")


# ---------------------------------------------------------------- file I/O ---

def atomic_write(path, data, mode=0o644):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


# ------------------------------------------------------------- networking ---

def default_route_iface():
    """Интерфейс маршрута по умолчанию или None."""
    try:
        if IS_MAC:
            out = subprocess.run(["route", "-n", "get", "default"],
                                 capture_output=True, text=True, timeout=5).stdout
            m = re.search(r"interface: (\S+)", out)
        else:
            out = subprocess.run(["ip", "-4", "route", "show", "default"],
                                 capture_output=True, text=True, timeout=5).stdout
            m = re.search(r"\bdev (\S+)", out)
        return m.group(1) if m else None
    except (OSError, subprocess.SubprocessError):
        return None


# ---------------------------------------------------------- sing-box config ---

def render_singbox(cfg, os_name=OS_NAME, iface=None, extra_proxy=None, extra_direct=None):
    """Собирает конфиг sing-box из шаблона + настроек + пользовательских списков."""
    with open(cfg["SINGBOX_TEMPLATE"], encoding="utf-8") as f:
        d = json.load(f)

    proxy_domains = read_domains("proxy") if extra_proxy is None else extra_proxy
    direct_domains = split_list(cfg["DIRECT_DOMAINS"])
    for x in (read_domains("direct") if extra_direct is None else extra_direct):
        if x not in direct_domains:
            direct_domains.append(x)

    d["log"]["level"] = cfg["LOG_LEVEL"]

    servers = {s["tag"]: s for s in d["dns"]["servers"]}
    servers["dns-direct"]["server"] = cfg["DNS_DIRECT"]
    servers["dns-proxy"]["server"] = cfg["DNS_PROXY"]
    dns_proxy_domains = split_list(cfg["DNS_PROXY_DOMAINS"])
    dns_proxy_domains += [x for x in proxy_domains if x not in dns_proxy_domains]
    if dns_proxy_domains:
        d["dns"]["rules"].append({"domain_suffix": dns_proxy_domains,
                                  "action": "route", "server": "dns-proxy"})

    for ob in d["outbounds"]:
        if ob["tag"] == "proxy":
            ob["server_port"] = int(cfg["SOCKS_PORT"])

    route = d["route"]
    rules = route["rules"]
    # пустой domain_suffix в sing-box матчит всё — пустые правила не добавляем
    idx = next(i for i, r in enumerate(rules) if "rule_set" in r)
    user_rules = []
    if direct_domains:
        user_rules.append({"domain_suffix": direct_domains, "outbound": "direct"})
    if proxy_domains:
        user_rules.append({"domain_suffix": proxy_domains, "outbound": "proxy"})
    rules[idx:idx] = user_rules

    for rs in route["rule_set"]:
        rs["path"] = os.path.join(cfg["RULES_DIR"], rs["tag"] + ".srs")

    if os_name == "linux":
        want = cfg["DEFAULT_IFACE"]
        if want.lower() == "auto":
            want = iface or default_route_iface()
        if want:
            route["default_interface"] = want
        else:
            # нет маршрута по умолчанию (сеть ещё не поднялась) — пусть sing-box ищет сам
            route["auto_detect_interface"] = True
        route["default_mark"] = int(cfg["ROUTING_MARK"])
    else:
        route["auto_detect_interface"] = True
    return d


def singbox_check(cfg, path):
    r = subprocess.run([cfg["SINGBOX_BIN"], "check", "-c", path],
                       capture_output=True, text=True, timeout=60)
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def write_singbox(cfg, conf, check=True):
    """Атомарно пишет конфиг sing-box, предварительно проверив его sing-box check."""
    dst = cfg["SINGBOX_CONF"]
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dst), prefix=".singbox.", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(conf, f, indent=4, ensure_ascii=False)
    os.chmod(tmp, 0o644)
    if check:
        ok, msg = singbox_check(cfg, tmp)
        if not ok:
            os.unlink(tmp)
            raise RuntimeError("sing-box check: " + msg)
    os.replace(tmp, dst)
    return dst


# ---------------------------------------------------------------- services ---

def service_id(name):
    """name: tun | xray | autoselect."""
    if IS_MAC:
        return "%s.%s" % (LAYOUT["LABEL_PREFIX"], name)
    return "%s-%s.service" % (LAYOUT["UNIT_PREFIX"], name)


def restart_service(name):
    if IS_MAC:
        cmd = ["launchctl", "kickstart", "-k", "system/" + service_id(name)]
    else:
        cmd = ["systemctl", "restart", service_id(name)]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60)


# --------------------------------------------------------------------- CLI ---

def _cli(argv):
    if len(argv) >= 3 and argv[0] == "set-conf":
        values = dict(a.split("=", 1) for a in argv[2:])
        set_conf_values(argv[1], values)
        return 0
    if len(argv) == 3 and argv[0] == "get":
        print(parse_kv(argv[1]).get(argv[2], "") if os.path.exists(argv[1]) else "")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
