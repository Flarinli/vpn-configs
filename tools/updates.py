#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
updates — что устарело среди закреплённого в репозитории и обновление.

  tools/updates.py outdated [--json | --markdown]   # код 1, если есть что обновлять
  tools/updates.py bump [--major] [NAME...]          # NAME: sing-box, xray, rules

Источники:
  sing-box  versions.env (SINGBOX_VERSION + sha256)  релизы SagerNet/sing-box
  xray      versions.env (XRAY_VERSION + sha256)     релизы XTLS/Xray-core
  rules     share/rules/SOURCES.env                  релизы runetfreedom (geosite/geoip)

bump без --major обновляет только внутри линейки: у sing-box это major.minor
(минорные релизы ломают формат конфига), у xray — год (26.x.y). Новые линейки
попадают в отчёт «ручной оценки» (outdated --markdown) и в issue «VPN drift».
Релизы моложе COOLDOWN не предлагаются: скомпрометированные версии обычно
отзывают в первые дни. Rule-set'ы пересобираются, если сборке больше
RULES_MAX_AGE и у runetfreedom вышел новый релиз.

Каждое обновление печатается строкой «bump NAME OLD -> NEW» (её читает
workflow «VPN updates»). Только стандартная библиотека Python ≥ 3.8.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSIONS = os.path.join(ROOT, "versions.env")
RULES_SOURCES = os.path.join(ROOT, "share", "rules", "SOURCES.env")

COOLDOWN = timedelta(days=7)
RULES_MAX_AGE = timedelta(days=28)

# имя -> (репозиторий, ключ в versions.env, сколько первых чисел версии задают линейку)
BINARIES = {
    "sing-box": ("SagerNet/sing-box", "SINGBOX_VERSION", 2),
    "xray": ("XTLS/Xray-core", "XRAY_VERSION", 1),
}
RULES_REPOS = {
    "GEOSITE_TAG": "runetfreedom/russia-blocked-geosite",
    "GEOIP_TAG": "runetfreedom/russia-blocked-geoip",
}

_VERSION = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")


def parse_kv(path):
    out = {}
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    return out


def parse_version(tag):
    m = _VERSION.match(tag.strip())
    return tuple(int(x) for x in m.groups()) if m else None


def github(path):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "vpn-split-updates"}
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request("https://api.github.com/" + path, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310 — фиксированный https
        return json.load(resp)


def latest_tag(repo):
    """Тег последнего релиза из редиректа releases/latest — без GitHub API."""
    req = urllib.request.Request("https://github.com/%s/releases/latest" % repo, method="HEAD",
                                 headers={"User-Agent": "vpn-split-updates"})
    with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310 — фиксированный https
        url = resp.geturl()
    if "/releases/tag/" not in url:
        raise RuntimeError("не удалось узнать последний релиз %s" % repo)
    return url.rsplit("/", 1)[1]


def published(release):
    return datetime.strptime(release["published_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


class Item:
    def __init__(self, name, current):
        self.name = name
        self.current = current
        self.latest = None   # новее, в той же линейке, прошло выдержку — bump
        self.major = None    # новая линейка — только ручная оценка (или bump --major)
        self.note = ""

    def as_dict(self):
        return {"name": self.name, "current": self.current, "latest": self.latest,
                "major": self.major, "note": self.note}


def check_binary(name, now):
    repo, key, line = BINARIES[name]
    current = parse_kv(VERSIONS)[key]
    item = Item(name, current)
    cur = parse_version(current)
    releases = github("repos/%s/releases?per_page=60" % repo)
    found = []
    for r in releases:
        v = parse_version(r["tag_name"])
        if v and not r["draft"] and not r["prerelease"] and v > cur:
            found.append((v, r))
    found.sort(key=lambda x: x[0], reverse=True)
    fresh = []
    for v, r in found:
        if now - published(r) < COOLDOWN:
            fresh.append(r["tag_name"])
            continue
        if v[:line] == cur[:line]:
            item.latest = item.latest or "%d.%d.%d" % v
        else:
            item.major = item.major or "%d.%d.%d" % v
    if fresh:
        item.note = "%s моложе %d дн., ждёт выдержки" % (", ".join(fresh), COOLDOWN.days)
    return item


def check_rules(now):
    src = parse_kv(RULES_SOURCES)
    built = src.get("BUILT", "")
    item = Item("rules", built or "неизвестно")
    latest = {k: latest_tag(repo) for k, repo in RULES_REPOS.items()}
    if all(src.get(k) == v for k, v in latest.items()):
        return item
    try:
        age = now - datetime.strptime(built, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError:
        age = RULES_MAX_AGE
    if age >= RULES_MAX_AGE:
        item.latest = now.strftime("%Y-%m-%d")
    else:
        item.note = "у runetfreedom новый релиз, пересборка после %s" % (
            (now - age + RULES_MAX_AGE).strftime("%Y-%m-%d"))
    return item


def check(names):
    now = datetime.now(timezone.utc)
    items = []
    for name in names:
        items.append(check_rules(now) if name == "rules" else check_binary(name, now))
    return items


# ------------------------------------------------------------------ bump ---

def stage_singbox(tmp):
    """sing-box для сборки rule-set'ов: $SINGBOX или поэтапная установка по versions.env."""
    if os.environ.get("SINGBOX"):
        return os.environ["SINGBOX"]
    dest = os.path.join(tmp, "stage")
    subprocess.run([os.path.join(ROOT, "install.sh"), "--no-deps", "-y"],
                   env=dict(os.environ, DESTDIR=dest), check=True, stdout=subprocess.DEVNULL)
    return os.path.join(dest, "opt", "vpn-split", "bin", "sing-box")


def bump(names, major):
    items = check(names)
    env = parse_kv(VERSIONS)
    new = {}
    for it in items:
        target = it.latest or (it.major if major else None)
        if target:
            new[it.name] = target
    binaries = [n for n in BINARIES if n in new]
    if binaries:
        sb = new.get("sing-box", env["SINGBOX_VERSION"])
        xr = new.get("xray", env["XRAY_VERSION"])
        subprocess.run(["bash", os.path.join(ROOT, "tools", "update-versions.sh"), sb, xr],
                       check=True, stdout=subprocess.DEVNULL)
        for n in binaries:
            print("bump %s %s -> %s" % (n, env[BINARIES[n][1]], new[n]))
    if "rules" in new:
        old = parse_kv(RULES_SOURCES).get("BUILT", "?")
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(["bash", os.path.join(ROOT, "tools", "build-rules.sh")],
                           env=dict(os.environ, SINGBOX=stage_singbox(tmp)),
                           check=True, stdout=subprocess.DEVNULL)
        src = parse_kv(RULES_SOURCES)
        print("bump rules %s -> %s (%s, %s)" % (old, src.get("BUILT"), src.get("GEOSITE_TAG"), src.get("GEOIP_TAG")))
    for it in items:
        if it.major and not major:
            print("manual %s %s -> %s (новая линейка)" % (it.name, it.current, it.major))
    return 0


# ---------------------------------------------------------------- report ---

def report(items, fmt):
    if fmt == "json":
        print(json.dumps([i.as_dict() for i in items], ensure_ascii=False, indent=2))
    elif fmt == "markdown":
        # только то, что требует ручной оценки
        manual = [i for i in items if i.major]
        if manual:
            print("| что | сейчас | новая линейка |")
            print("|---|---|---|")
            for i in manual:
                print("| %s | %s | %s |" % (i.name, i.current, i.major))
        else:
            print("Новых мажорных линеек нет.")
    else:
        for i in items:
            state = []
            if i.latest:
                state.append("-> %s" % i.latest)
            if i.major:
                state.append("новая линейка %s" % i.major)
            if i.note:
                state.append(i.note)
            print("%-9s %-12s %s" % (i.name, i.current, "; ".join(state) or "актуально"))
    return 1 if any(i.latest or i.major for i in items) else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1].strip(),
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    o = sub.add_parser("outdated", help="что устарело")
    g = o.add_mutually_exclusive_group()
    g.add_argument("--json", action="store_const", const="json", dest="fmt")
    g.add_argument("--markdown", action="store_const", const="markdown", dest="fmt")
    b = sub.add_parser("bump", help="обновить закреплённое")
    b.add_argument("--major", action="store_true", help="переходить и на новые линейки")
    for p in (o, b):
        p.add_argument("names", nargs="*", metavar="NAME", help="sing-box, xray, rules (по умолчанию все)")
    args = ap.parse_args()
    known = list(BINARIES) + ["rules"]
    for n in args.names:
        if n not in known:
            ap.error("неизвестный источник %s (%s)" % (n, ", ".join(known)))
    names = args.names or known
    if args.cmd == "outdated":
        return report(check(names), args.fmt)
    return bump(names, args.major)


if __name__ == "__main__":
    sys.exit(main())
