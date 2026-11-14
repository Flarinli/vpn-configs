#!/usr/bin/env bash
# vpn-split — установщик сплит-VPN (sing-box TUN + xray + vpn-autoselect)
# для Linux (systemd), macOS (launchd) и Windows (Git Bash + WinSW + планировщик), amd64/arm64.
#
#   sudo ./install.sh [install] [опции]    установить или обновить (повторный запуск безопасен)
#   sudo ./install.sh deps [--check-only]  проверить и доустановить зависимости
#   sudo ./install.sh uninstall [--purge]  удалить (--purge — вместе с настройками и состоянием)
#   ./install.sh status                    состояние служб и текущий узел
#
# Windows: запускать из Git Bash «от имени администратора». Службы — WinSW
# (vpn-split-tun, vpn-split-xray, автостарт), расписание — задачи планировщика
# (vpn-split-autoselect каждые 10 минут от SYSTEM; vpn-split-update раз в час).
# Python при отсутствии ставится через winget.
#
# Если установка запущена из git-клона, ставится и таймер автообновления
# (vpn-split-update, раз в час): он подтягивает main клона и при новом коммите
# повторяет установку. Выключить: AUTO_UPDATE=0 в vpn-split.conf.
#
# Опции:
#   --no-deps        не ставить зависимости, только проверить наличие
#   --check-only     (deps) только отчёт; код возврата ≠0, если чего-то не хватает
#   --no-start       разложить файлы, но не запускать службы
#   --python=MODE    auto (по умолчанию) | system | uv — откуда брать Python ≥ 3.8
#                    (на Windows: auto|system, Python через winget)
#   --migrate-xray   Linux: отключить старые xray.service и vpn-autoselect (порт 20808)
#   --purge          (uninstall) удалить также настройки, состояние и логи
#   -y, --yes        не задавать вопросов
#
# Переменные окружения:
#   VPN_SPLIT_SUB_URL      URL подписки для нового vpn-split.conf
#   PREFIX SYSCONFDIR STATEDIR LOGDIR BINDIR SBINDIR — раскладка, по умолчанию
#                          /opt/vpn-split /etc/vpn-split /var/lib/vpn-split /var/log/vpn-split
#                          /usr/local/bin /usr/local/sbin (macOS: /usr/local/bin;
#                          Windows: C:/Program Files/vpn-split, C:/ProgramData/vpn-split/{etc,lib,log})
#   DESTDIR                поэтапная установка в каталог (службы не трогаются);
#                          на Windows с DESTDIR задавайте POSIX-префикс: PREFIX=/opt/vpn-split
#
# Скрипт совместим с bash 3.2 (системный bash macOS).
set -euo pipefail
umask 022

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
. "$REPO/versions.env"
# shellcheck source=lib/download.sh
. "$REPO/lib/download.sh"

# ------------------------------------------------------------------ вывод ---
log()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf 'ВНИМАНИЕ: %s\n' "$*" >&2; }
die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
# системные каталоги (/usr/local/bin, /var/backups, …) только создаём, права существующих не меняем
mkd() { local d; for d in "$@"; do [[ -d $d ]] || install -d -m 755 "$d"; done; }

# ------------------------------------------------------------- платформа ---
case "$(uname -s)" in
  Linux)  OS=linux ;;
  Darwin) OS=darwin ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;   # Git Bash / MSYS2
  *) die "неподдерживаемая ОС: $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "неподдерживаемая архитектура: $(uname -m)" ;;
esac

# ---------------------------------------------------------------- раскладка ---
DESTDIR="${DESTDIR:-}"
if [[ $OS == windows ]]; then
  if [[ -n $DESTDIR ]]; then
    # поэтапная установка: "$D$PREFIX" склеивается — все пути POSIX-формы
    PREFIX="${PREFIX:-/opt/vpn-split}"
    SYSCONFDIR="${SYSCONFDIR:-/etc/vpn-split}"
    STATEDIR="${STATEDIR:-/var/lib/vpn-split}"
    LOGDIR="${LOGDIR:-/var/log/vpn-split}"
    [[ $PREFIX == [A-Za-z]:* || $SYSCONFDIR == [A-Za-z]:* || $STATEDIR == [A-Za-z]:* ]] \
      && die "с DESTDIR на Windows задайте POSIX-пути: PREFIX=/opt/vpn-split SYSCONFDIR=…"
  else
    # пути в POSIX/MSYS-форме: с ними работают и утилиты Git Bash, и Python;
    # в файлы Windows (cmd/xml/ps1) они попадают через winpath (обратно-слэш)
    PREFIX="${PREFIX:-C:/Program Files/vpn-split}"
    SYSCONFDIR="${SYSCONFDIR:-C:/ProgramData/vpn-split/etc}"
    STATEDIR="${STATEDIR:-C:/ProgramData/vpn-split/lib}"
    LOGDIR="${LOGDIR:-C:/ProgramData/vpn-split/log}"
  fi
  BINDIR="${BINDIR:-$PREFIX/bin}"; SBINDIR="${SBINDIR:-$PREFIX/bin}"
else
  PREFIX="${PREFIX:-/opt/vpn-split}"
  SYSCONFDIR="${SYSCONFDIR:-/etc/vpn-split}"
  STATEDIR="${STATEDIR:-/var/lib/vpn-split}"
  LOGDIR="${LOGDIR:-/var/log/vpn-split}"
  BINDIR="${BINDIR:-/usr/local/bin}"
  if [[ $OS == darwin ]]; then SBINDIR="${SBINDIR:-/usr/local/bin}"; else SBINDIR="${SBINDIR:-/usr/local/sbin}"; fi
fi
BACKUP_DIR="${BACKUP_DIR:-/var/backups}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
LAUNCHD_DIR="${LAUNCHD_DIR:-/Library/LaunchDaemons}"
NEWSYSLOG_DIR="${NEWSYSLOG_DIR:-/etc/newsyslog.d}"
UNIT_PREFIX="${UNIT_PREFIX:-vpn-split}"
LABEL_PREFIX="${LABEL_PREFIX:-io.github.flarinli.vpn-split}"
SERVICES="xray autoselect tun"   # порядок запуска
D="$DESTDIR"

# -------------------------------------------------------- Windows helpers ---
winpath() {  # путь в Windows-форму (C:\…) — для cmd/xml/ps1 и задач планировщика
  [[ $OS == windows ]] && cygpath -w "$1" || printf '%s' "$1"
}
native() {  # запуск команды Windows без преобразования MSYS-путей (/Delete и т.п.)
  MSYS2_ARG_CONV_EXCL='*' "$@"
}

# ------------------------------------------------------------------ опции ---
CMD=install
NO_DEPS=0; CHECK_ONLY=0; NO_START=0; PY_MODE=auto; MIGRATE_XRAY=0; PURGE=0; ASSUME_YES=0
for a in ${1+"$@"}; do
  case "$a" in
    install|deps|uninstall|status) CMD=$a ;;
    --no-deps)      NO_DEPS=1 ;;
    --check-only)   CHECK_ONLY=1 ;;
    --no-start)     NO_START=1 ;;
    --python=*)     PY_MODE=${a#--python=} ;;
    --migrate-xray) MIGRATE_XRAY=1 ;;
    --purge)        PURGE=1 ;;
    -y|--yes)       ASSUME_YES=1 ;;
    -h|--help)      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "неизвестный аргумент: $a (см. --help)" ;;
  esac
done
case "$PY_MODE" in auto|system|uv) ;; *) die "--python: auto | system | uv" ;; esac
[[ $OS == windows && $PY_MODE == uv ]] && die "--python=uv на Windows не поддерживается (auto|system)"
[[ -n $D ]] && NO_START=1   # поэтапная установка никогда не трогает службы хоста

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

need_root() {
  if [[ $OS == windows ]]; then
    [[ -n $D ]] || net session >/dev/null 2>&1 \
      || die "нужны права администратора: запустите Git Bash «от имени администратора»"
  else
    [[ $EUID -eq 0 || -n $D ]] || die "нужны права root: sudo $0 $*"
  fi
}
interactive() { [[ -t 0 && $ASSUME_YES -eq 0 ]]; }
confirm() {  # confirm "вопрос" -> 0 = да
  interactive || return 1
  local ans; read -r -p "$1 [y/N] " ans
  case "$ans" in y|Y|yes|да|Да) return 0 ;; *) return 1 ;; esac
}
sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
safe_rm() {  # rm -rf только для «наших» путей, никогда для корня/системных каталогов
  local p
  for p in "$@"; do
    case "${p%/}" in
      ""|/|/usr|/usr/local|/usr/local/bin|/etc|/var|/var/lib|/var/log|/opt|/Library|"$D"|\
      "C:"|"/c"|"C:/Program Files"|"/c/Program Files"|"C:/ProgramData"|"/c/ProgramData"|\
      "C:/Windows"|"/c/Windows"|"C:/Users"|"/c/Users") die "отказ удалять $p" ;;
    esac
    rm -rf "$p"
  done
}

# ======================================================== зависимости ===
# Логическая зависимость -> пакет конкретного менеджера.
PM=""
BREW=""
detect_pm() {
  if [[ $OS == darwin ]]; then PM=brew; return; fi
  if [[ $OS == windows ]]; then PM=""; return; fi   # Python — через winget напрямую
  local pm
  for pm in apt-get dnf yum pacman zypper apk; do
    if have "$pm"; then PM=$pm; return; fi
  done
}
pkg_for() {
  case "$1:$PM" in
    python3:pacman) echo python ;;
    python3:*)      echo python3 ;;
    ip:dnf|ip:yum)  echo iproute ;;
    ip:*)           echo iproute2 ;;
    sha256:*)       echo coreutils ;;
    *)              echo "$1" ;;  # curl, tar, ca-certificates
  esac
}

find_brew() {
  [[ -n $BREW && -x $BREW ]] && return 0
  local b=""
  b="$(command -v brew 2>/dev/null || true)"
  # из-под sudo PATH урезан: спрашиваем login-shell пользователя, потом стандартные префиксы brew
  if [[ -z $b && -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    b="$(sudo -H -u "$SUDO_USER" /bin/bash -lc 'command -v brew' 2>/dev/null || true)"
  fi
  if [[ -z $b ]]; then
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew ""; do [[ -x $b ]] && break; done
  fi
  [[ -n $b && -x $b ]] && BREW=$b
}
brew_run() {
  [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] \
    || die "Homebrew нельзя запускать от root: запустите установку через sudo из-под обычного пользователя"
  sudo -H -u "$SUDO_USER" "$BREW" "$@"
}
install_brew() {
  [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] \
    || die "для установки Homebrew запустите install.sh через sudo из-под обычного пользователя"
  log "установка Homebrew (официальный установщик, от пользователя $SUDO_USER)"
  local script="$TMP/brew-install.sh"
  curl -fsSL -o "$script" https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
  chmod 755 "$script"
  sudo -H -u "$SUDO_USER" env NONINTERACTIVE=1 /bin/bash "$script"
  find_brew || die "Homebrew установлен, но brew не найден"
}

pm_install() {
  info "устанавливаю через $PM: $*"
  case "$PM" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get update -qq
             DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
    dnf|yum) "$PM" install -y -q "$@" ;;
    pacman)  pacman -Sy --noconfirm --needed "$@" ;;
    zypper)  zypper --non-interactive install --no-recommends "$@" ;;
    apk)     apk add --no-cache "$@" ;;
    brew)    find_brew || install_brew; brew_run install "$@" ;;
    *) return 1 ;;
  esac
}

ca_ok() {
  local f
  if [[ $OS == windows ]]; then
    for f in /mingw64/etc/ssl/certs/ca-bundle.crt /mingw32/etc/ssl/certs/ca-bundle.crt \
             /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; do
      [[ -s $f ]] && return 0
    done
    return 1
  fi
  for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
           /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem; do
    [[ -s $f ]] && return 0
  done
  return 1
}

# Python: PYTHON — путь, который пишется в юниты (без DESTDIR); PY — чем запускать сейчас.
PYTHON=""; PY=""
py_ok() { "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; }
find_system_python() {
  local c p
  if [[ $OS == windows ]]; then
    for c in ${PYTHON_BIN:-} python python3; do
      p="$(command -v "$c" 2>/dev/null)" || continue
      py_ok "$p" || continue
      # абсолютный Windows-путь реального интерпретатора (не заглушка PATH)
      p="$("$p" -c 'import os, sys; print(os.path.realpath(sys.executable))' 2>/dev/null)" || continue
      PYTHON=$p; PY=$p; return 0
    done
    for p in "$LOCALAPPDATA/Programs/Python"/Python3*/python.exe; do
      [[ -f $p ]] || continue
      if py_ok "$p"; then PYTHON=$p; PY=$p; return 0; fi
    done
    return 1
  fi
  for c in ${PYTHON_BIN:-} python3 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
    p="$(command -v "$c" 2>/dev/null)" || continue
    # macOS без Command Line Tools: /usr/bin/python3 — заглушка, открывающая диалог установки
    if [[ $OS == darwin && $p == /usr/bin/python3 ]] && ! xcode-select -p >/dev/null 2>&1; then continue; fi
    if py_ok "$p"; then PYTHON=$p; PY=$p; return 0; fi
  done
  if [[ $OS == darwin ]] && find_brew; then
    p="$(dirname "$BREW")/python3"
    if [[ -x $p ]] && py_ok "$p"; then PYTHON=$p; PY=$p; return 0; fi
  fi
  return 1
}

win_install_python() {  # Python для Windows — официальный установщик через winget
  have winget || die "Python ≥ 3.8 не найден и winget недоступен — установите Python с python.org и повторите"
  log "установка Python 3.12 через winget"
  winget install -e --id Python.Python.3.12 --silent --accept-package-agreements \
    --accept-source-agreements || die "winget не смог установить Python"
  find_system_python || die "Python установлен, но не найден — откройте новый терминал и повторите"
}
find_uv_python() {
  local uv="$D$PREFIX/tools/uv" p
  [[ -x $uv ]] || return 1
  p="$(UV_PYTHON_INSTALL_DIR="$D$PREFIX/python" "$uv" python find --managed-python \
        "$UV_PYTHON_VERSION" 2>/dev/null)" || return 1
  py_ok "$p" || return 1
  # конкретный путь интерпретатора, а не ссылка uv на минорную версию
  p="$("$p" -c 'import os, sys; print(os.path.realpath(sys.executable))')"
  PY=$p; PYTHON=${p#"$D"}
}
install_uv_python() {
  local tools="$D$PREFIX/tools"
  if [[ ! -x $tools/uv ]]; then
    log "установка uv в $PREFIX/tools"
    install -d -m 755 "$tools"
    if curl -LsSf -o "$TMP/uv-install.sh" https://astral.sh/uv/install.sh; then
      info "официальный установщик astral.sh"
      env UV_INSTALL_DIR="$tools" UV_NO_MODIFY_PATH=1 sh "$TMP/uv-install.sh" >/dev/null
    else
      # astral.sh недоступен — тот же бинарник из релиза GitHub, со сверкой .sha256 релиза
      local triple base
      case "$OS-$ARCH" in
        linux-amd64)  triple=x86_64-unknown-linux-musl ;;
        linux-arm64)  triple=aarch64-unknown-linux-musl ;;
        darwin-amd64) triple=x86_64-apple-darwin ;;
        darwin-arm64) triple=aarch64-apple-darwin ;;
      esac
      base="https://github.com/astral-sh/uv/releases/latest/download/uv-$triple.tar.gz"
      info "astral.sh недоступен — релиз GitHub: $base"
      curl -fsSL --retry 3 -o "$TMP/uv.tar.gz" "$base" || die "не удалось скачать uv"
      curl -fsSL --retry 3 -o "$TMP/uv.sha256" "$base.sha256" || die "не удалось скачать $base.sha256"
      [[ "$(sha256_of "$TMP/uv.tar.gz")" == "$(awk '{print $1}' "$TMP/uv.sha256")" ]] \
        || die "sha256 uv не совпал"
      tar -xzf "$TMP/uv.tar.gz" -C "$TMP"
      install -m 755 "$TMP/uv-$triple/uv" "$tools/uv"
    fi
  fi
  info "uv python install $UV_PYTHON_VERSION -> $PREFIX/python"
  UV_PYTHON_INSTALL_DIR="$D$PREFIX/python" UV_CACHE_DIR="$TMP/uv-cache" \
    "$tools/uv" python install --no-bin "$UV_PYTHON_VERSION" >/dev/null
  find_uv_python || die "uv не смог установить Python $UV_PYTHON_VERSION"
}

# Сейчас все Python-скрипты — только stdlib. Если появится requirements.txt,
# зависимости ставятся в изолированный venv через uv, а юниты используют его Python.
ensure_python_deps() {
  local req="$REPO/requirements.txt"
  [[ -s $req ]] || return 0
  local tools="$D$PREFIX/tools"
  [[ -x $tools/uv ]] || install_uv_python
  log "Python-зависимости проекта -> $PREFIX/venv"
  UV_CACHE_DIR="$TMP/uv-cache" "$tools/uv" venv --quiet --python "$PY" "$D$PREFIX/venv"
  UV_CACHE_DIR="$TMP/uv-cache" "$tools/uv" pip install --quiet \
    --python "$D$PREFIX/venv/bin/python" -r "$req"
  PY="$D$PREFIX/venv/bin/python"; PYTHON="$PREFIX/venv/bin/python"
}

REPORT=""
report() { REPORT="$REPORT$(printf '   %-16s %s' "$1" "$2")"$'\n'; }

cmd_deps() {
  log "зависимости ($OS/$ARCH)"
  detect_pm
  if [[ $OS == windows ]]; then
    info "менеджер пакетов: winget (только Python)"
  else
    info "менеджер пакетов: ${PM:-не найден}"
  fi
  [[ $PM == apk ]] && warn "Alpine: systemd нет — службы придётся запускать вручную (OpenRC не поддерживается)"

  local missing="" dep ok fatal=0
  for dep in curl tar sha256 ca-certificates; do
    case $dep in
      sha256) have sha256sum || have shasum && ok=1 || ok=0 ;;
      ca-certificates) ca_ok && ok=1 || ok=0 ;;
      *) have "$dep" && ok=1 || ok=0 ;;
    esac
    if [[ $ok == 1 ]]; then report "$dep" "найдено"; else missing="$missing $dep"; fi
  done
  if [[ $OS == linux ]]; then
    if have ip; then report ip "найдено"; else missing="$missing ip"; fi
  fi
  if [[ $PY_MODE != uv ]]; then
    if find_system_python || find_uv_python; then report python3 "найдено: $PY"; else missing="$missing python3"; fi
  fi

  # установка недостающего пакетным менеджером (на Windows — только Python через winget ниже)
  if [[ -n $missing && $CHECK_ONLY -eq 0 && $NO_DEPS -eq 0 && $OS != windows ]]; then
    need_root deps
    local pkgs="" m
    for m in $missing; do
      [[ $m == python3 && $PY_MODE == uv ]] && continue
      [[ $OS == darwin && $m != python3 ]] && continue  # curl/tar/shasum/сертификаты встроены в macOS
      pkgs="$pkgs $(pkg_for "$m")"
    done
    if [[ -n ${pkgs// /} ]]; then
      if [[ -n $PM ]]; then
        # shellcheck disable=SC2086
        pm_install $pkgs || warn "$PM завершился с ошибкой"
      else
        warn "пакетный менеджер не найден — поставьте вручную:$pkgs"
      fi
    fi
    local still=""
    for m in $missing; do
      case $m in
        sha256) have sha256sum || have shasum && ok=1 || ok=0 ;;
        ca-certificates) ca_ok && ok=1 || ok=0 ;;
        python3) find_system_python && ok=1 || ok=0 ;;
        *) have "$m" && ok=1 || ok=0 ;;
      esac
      if [[ $ok == 1 ]]; then
        if [[ $m == python3 ]]; then report "$m" "установлено: $PY"; else report "$m" "установлено"; fi
      else still="$still $m"; fi
    done
    missing=$still
  fi

  # Python на Windows: единственный путь — winget (uv-фолбэк не подходит)
  if [[ $OS == windows && $missing == *python3* && $CHECK_ONLY -eq 0 && $NO_DEPS -eq 0 ]]; then
    win_install_python
    report python3 "установлено: $PY"
    missing="${missing/python3/}"
  fi

  # Python: системный -> пакетный менеджер (выше) -> uv
  if [[ $PY_MODE == uv || ( $missing == *python3* && $PY_MODE == auto ) ]]; then
    if [[ $CHECK_ONLY -eq 0 && $NO_DEPS -eq 0 ]] && have curl; then
      find_uv_python || install_uv_python
      report python3 "uv: $PY"
      missing="${missing/python3/}"
    elif find_uv_python; then
      report python3 "uv: $PY"
      missing="${missing/python3/}"
    fi
  fi
  for m in $missing; do report "$m" "ОТСУТСТВУЕТ"; fatal=1; done

  # системные возможности (не ставятся пакетами)
  if [[ $OS == linux ]]; then
    if have systemctl && [[ -d /run/systemd/system ]]; then report systemd "найдено"
    elif [[ -n $D ]]; then report systemd "нет (не важно для DESTDIR)"
    else report systemd "ОТСУТСТВУЕТ — нужна система на systemd"; fatal=1; fi
    if [[ ! -c /dev/net/tun && $CHECK_ONLY -eq 0 && $EUID -eq 0 ]]; then modprobe tun 2>/dev/null || true; fi
    if [[ -c /dev/net/tun ]]; then report tun "найдено"
    elif [[ -n $D ]]; then report tun "нет (не важно для DESTDIR)"
    else report tun "ОТСУТСТВУЕТ — /dev/net/tun (modprobe tun)"; fatal=1; fi
  elif [[ $OS == darwin ]]; then
    for m in launchctl route ipconfig; do
      if have $m; then report $m "найдено"; else report $m "ОТСУТСТВУЕТ"; fatal=1; fi
    done
  else
    for m in powershell schtasks net; do
      if have $m; then report $m "найдено"; else report $m "ОТСУТСТВУЕТ"; fatal=1; fi
    done
    report wintun "входит в архив sing-box (ставится вместе с ним)"
    report services "WinSW + Планировщик заданий (ставит install.sh)"
  fi
  printf '%s' "$REPORT"
  REPORT=""
  if [[ $fatal -ne 0 ]]; then
    [[ $CHECK_ONLY -eq 1 ]] && return 1
    die "не все зависимости удовлетворены (см. выше)"
  fi
  [[ $CHECK_ONLY -eq 1 ]] || ensure_python_deps
  return 0
}

# =========================================================== установка ===
render_template() {  # render_template SRC DST MODE [KEY=VALUE...]
  local src=$1 dst=$2 mode=$3 content kv
  shift 3
  content="$(cat "$src"; printf x)"; content=${content%x}
  for kv in "PREFIX=$PREFIX" "SYSCONFDIR=$SYSCONFDIR" "STATEDIR=$STATEDIR" "LOGDIR=$LOGDIR" \
            "PYTHON=$PYTHON" "UNIT_PREFIX=$UNIT_PREFIX" "LABEL_PREFIX=$LABEL_PREFIX" ${1+"$@"}; do
    content=${content//@${kv%%=*}@/${kv#*=}}
  done
  printf '%s' "$content" > "$dst.tmp"
  chmod "$mode" "$dst.tmp"
  mv -f "$dst.tmp" "$dst"
}

download_verified() {  # URL SHA256 OUT
  [[ -n $2 ]] || die "нет sha256 для $1 в versions.env (tools/update-versions.sh)"
  # локальный кэш пакетов (VPN_SPLIT_PKG_CACHE): повторные установки не качают заново
  local cached="" got
  if [[ -n ${VPN_SPLIT_PKG_CACHE:-} ]]; then
    cached="$VPN_SPLIT_PKG_CACHE/$(basename "$1")"
    if [[ -f $cached ]] && { got="$(sha256_of "$cached")"; [[ $got == "$2" ]]; }; then
      info "из кэша: $cached"
      cp -f "$cached" "$3"
      return 0
    fi
  fi
  info "скачиваю $1"
  curl -fsSL --retry 3 --connect-timeout 20 -o "$3" "$1" || die "не удалось скачать $1"
  got="$(sha256_of "$3")"
  [[ $got == "$2" ]] || die "sha256 не совпал для $1: $got (ожидался $2)"
  if [[ -n ${VPN_SPLIT_PKG_CACHE:-} ]]; then
    mkdir -p "$VPN_SPLIT_PKG_CACHE" && cp -f "$3" "$cached" 2>/dev/null || true
  fi
}

install_binaries() {
  log "бинарники sing-box $SINGBOX_VERSION и xray $XRAY_VERSION -> $PREFIX/bin"
  local bin="$D$PREFIX/bin" v
  install -d -m 755 "$bin" "$D$PREFIX/share/xray"

  if [[ $OS == windows ]]; then
    if [[ -x $bin/sing-box.exe ]] && "$bin/sing-box.exe" version 2>/dev/null | head -1 | grep -q "version $SINGBOX_VERSION\$"; then
      info "sing-box $SINGBOX_VERSION уже установлен"
    else
      v="SHA256_singbox_${OS}_${ARCH}"
      download_verified "$(singbox_url "$OS" "$ARCH")" "${!v:-}" "$TMP/sing-box.zip"
      "$PY" -m zipfile -e "$TMP/sing-box.zip" "$TMP/sing-box"
      install -m 755 "$TMP/sing-box/sing-box-$SINGBOX_VERSION-$OS-$ARCH/sing-box.exe" "$bin/sing-box.exe"
      if [[ -f $TMP/sing-box/sing-box-$SINGBOX_VERSION-$OS-$ARCH/wintun.dll ]]; then
        install -m 644 "$TMP/sing-box/sing-box-$SINGBOX_VERSION-$OS-$ARCH/wintun.dll" "$bin/wintun.dll"
      fi
      # начиная с sing-box 1.10 wintun встроен в бинарник — отдельный dll не нужен
    fi
    if [[ -x $bin/xray.exe && -f $D$PREFIX/share/xray/geoip.dat ]] \
       && "$bin/xray.exe" version 2>/dev/null | head -1 | grep -q "^Xray $XRAY_VERSION "; then
      info "xray $XRAY_VERSION уже установлен"
    else
      v="SHA256_xray_${OS}_${ARCH}"
      download_verified "$(xray_url "$OS" "$ARCH")" "${!v:-}" "$TMP/xray.zip"
      "$PY" -m zipfile -e "$TMP/xray.zip" "$TMP/xray"
      install -m 755 "$TMP/xray/xray.exe" "$bin/xray.exe"
      install -m 644 "$TMP/xray/geoip.dat" "$TMP/xray/geosite.dat" "$D$PREFIX/share/xray/"
    fi
    # WinSW — хост служб Windows: один exe, копия с именем службы читает xml с тем же именем
    if [[ ! -x $bin/WinSW-x64.exe ]] || [[ "$(sha256_of "$bin/WinSW-x64.exe")" != "${SHA256_winsw_windows_amd64:-}" ]]; then
      download_verified "$(winsw_url)" "${SHA256_winsw_windows_amd64:-}" "$TMP/WinSW-x64.exe"
      install -m 755 "$TMP/WinSW-x64.exe" "$bin/WinSW-x64.exe"
    fi
    cp -f "$bin/WinSW-x64.exe" "$bin/vpn-split-tun.exe"
    cp -f "$bin/WinSW-x64.exe" "$bin/vpn-split-xray.exe"
    return 0
  fi

  if [[ -x $bin/sing-box ]] && "$bin/sing-box" version 2>/dev/null | head -1 | grep -q "version $SINGBOX_VERSION\$"; then
    info "sing-box $SINGBOX_VERSION уже установлен"
  else
    v="SHA256_singbox_${OS}_${ARCH}"
    download_verified "$(singbox_url "$OS" "$ARCH")" "${!v:-}" "$TMP/sing-box.tar.gz"
    tar -xzf "$TMP/sing-box.tar.gz" -C "$TMP"
    install -m 755 "$TMP/sing-box-$SINGBOX_VERSION-$OS-$ARCH/sing-box" "$bin/sing-box"
  fi

  if [[ -x $bin/xray && -f $D$PREFIX/share/xray/geoip.dat ]] \
     && "$bin/xray" version 2>/dev/null | head -1 | grep -q "^Xray $XRAY_VERSION "; then
    info "xray $XRAY_VERSION уже установлен"
  else
    v="SHA256_xray_${OS}_${ARCH}"
    download_verified "$(xray_url "$OS" "$ARCH")" "${!v:-}" "$TMP/xray.zip"
    "$PY" -m zipfile -e "$TMP/xray.zip" "$TMP/xray"   # без зависимости от unzip
    install -m 755 "$TMP/xray/xray" "$bin/xray"
    install -m 644 "$TMP/xray/geoip.dat" "$TMP/xray/geosite.dat" "$D$PREFIX/share/xray/"
  fi
}

install_files() {
  log "файлы проекта -> $PREFIX"
  local p="$D$PREFIX" f
  install -d -m 755 "$p/bin" "$p/lib" "$p/libexec" "$p/share/rules"
  if [[ $OS == windows ]]; then
    install -m 644 "$REPO/bin/vpn-urls" "$p/bin/vpn-urls.py"
    render_template "$REPO/init/windows/vpn-urls.cmd.in" "$p/bin/vpn-urls.cmd" 755 \
      "PYTHON=$(winpath "$PYTHON")" "PREFIX=$(winpath "$PREFIX")"
  else
    install -m 755 "$REPO/bin/vpn-urls" "$p/bin/vpn-urls"
  fi
  install -m 644 "$REPO/lib/vpnsplit.py" "$p/lib/vpnsplit.py"
  for f in vpn-autoselect render-config migrate-legacy vpn-split-update; do
    install -m 755 "$REPO/libexec/$f" "$p/libexec/$f"
  done
  install -m 644 "$REPO/share/singbox.json.tmpl" "$REPO/etc/vpn-split.conf.example" "$p/share/"
  install -m 644 "$REPO"/share/rules/*.srs "$p/share/rules/"
  printf '%s\n' "$VPN_SPLIT_VERSION" > "$p/VERSION"
  # единственный источник раскладки для всех скриптов (см. lib/vpnsplit.py)
  cat > "$p/share/layout.env" <<EOF
# vpn-split $VPN_SPLIT_VERSION — раскладка установки (генерирует install.sh)
PREFIX=$PREFIX
SYSCONFDIR=$SYSCONFDIR
STATEDIR=$STATEDIR
LOGDIR=$LOGDIR
UNIT_PREFIX=$UNIT_PREFIX
LABEL_PREFIX=$LABEL_PREFIX
PYTHON=$PYTHON
SRC_DIR=$REPO
EOF
  chmod 644 "$p/share/layout.env"
}

# окружение для запуска установленных скриптов относительно DESTDIR.
# На Windows нативному Python нужны пути в форме C:\… — конвертируем MSYS-пути.
run_py() {
  local a args=() pre="$D$PREFIX" sysd="$D$SYSCONFDIR" std="$D$STATEDIR" conf="$D$SYSCONFDIR/vpn-split.conf"
  if [[ $OS == windows ]]; then
    pre="$(cygpath -w "$pre")"; sysd="$(cygpath -w "$sysd")"
    std="$(cygpath -w "$std")"; conf="$(cygpath -w "$conf")"
    for a in "$@"; do
      if [[ $a == /* ]]; then a="$(cygpath -w "$a")"; fi
      args+=("$a")
    done
  else
    args=("$@")
  fi
  VPN_SPLIT_SYSCONFDIR="$sysd" VPN_SPLIT_STATEDIR="$std" \
    VPN_SPLIT_CONF="$conf" "$PY" "${args[@]}"
}
conf_get() { run_py "$D$PREFIX/lib/vpnsplit.py" get "$D$SYSCONFDIR/vpn-split.conf" "$1"; }

NEW_CONF=0
setup_config() {
  log "настройки -> $SYSCONFDIR, состояние -> $STATEDIR"
  install -d -m 755 "$D$SYSCONFDIR" "$D$STATEDIR"
  [[ $OS == darwin ]] && install -d -m 755 "$D$LOGDIR"
  local conf="$D$SYSCONFDIR/vpn-split.conf" kind
  if [[ ! -f $conf ]]; then
    install -m 600 "$REPO/etc/vpn-split.conf.example" "$conf"
    NEW_CONF=1
    info "создан $SYSCONFDIR/vpn-split.conf"
  else
    chmod 600 "$conf"
    info "$SYSCONFDIR/vpn-split.conf уже есть — не трогаю"
  fi
  for kind in proxy direct; do
    [[ -f $D$SYSCONFDIR/domains.$kind ]] && continue
    run_py "$D$PREFIX/lib/vpnsplit.py" write-domains "$kind"
  done
}

set_sub_url() {
  local url="${VPN_SPLIT_SUB_URL:-}"
  [[ -n $(conf_get SUB_URL) || -n $(conf_get NODES_FILE) ]] && [[ -z $url ]] && return 0
  if [[ -z $url ]] && interactive; then
    read -r -p "URL подписки (Enter — пропустить, вписать позже в $SYSCONFDIR/vpn-split.conf): " url
  fi
  [[ -n $url ]] || return 0
  run_py "$D$PREFIX/lib/vpnsplit.py" set-conf "$D$SYSCONFDIR/vpn-split.conf" "SUB_URL=$url"
  info "SUB_URL записан в $SYSCONFDIR/vpn-split.conf"
}

# ------------------------------------------------ миграция старой схемы ---
# Старая раскладка: /usr/local/etc/singbox-tun, singbox-tun.service / com.singbox.tun,
# xray + vpn-autoselect (Linux: отдельная установка, macOS: local.xray / local.vpn-autoselect).
XRAY_CONFLICT=0
legacy_units_linux() {  # юниты старого vpn-autoselect/xray, найденные по содержимому
  local f
  [[ -d $D$SYSTEMD_DIR ]] || return 0
  for f in "$D$SYSTEMD_DIR"/*.service "$D$SYSTEMD_DIR"/*.timer; do
    [[ -f $f ]] || continue
    case "$(basename "$f")" in "$UNIT_PREFIX"-*) continue ;; esac
    grep -qE '/usr/local/bin/vpn-autoselect|/usr/local/etc/xray/config.json' "$f" || continue
    # на живой системе считаем только включённые/работающие (отключённые при миграции — уже не мешают)
    if [[ -z $D ]] && ! systemctl -q is-enabled "$(basename "$f")" 2>/dev/null \
       && ! systemctl -q is-active "$(basename "$f")" 2>/dev/null; then
      continue
    fi
    basename "$f"
  done
}

migrate_legacy() {
  [[ $OS == windows ]] && return 0   # на Windows старых установок не было
  local old_sb="/usr/local/etc/singbox-tun/config.json" old_as units="" remove="" keep="" p
  if [[ $OS == darwin ]]; then old_as=/usr/local/etc/vpn-autoselect.conf; else old_as=/etc/vpn-autoselect.conf; fi
  [[ $OS == linux ]] && units="$(legacy_units_linux | tr '\n' ' ')"
  if [[ ! -e $D$old_sb && ! -e $D$old_as && ! -e $D$SYSTEMD_DIR/singbox-tun.service \
        && ! -e $D$LAUNCHD_DIR/com.singbox.tun.plist && -z ${units// /} ]]; then
    return 0
  fi
  log "найдена старая установка — миграция"

  if [[ $NEW_CONF -eq 1 ]]; then
    run_py "$D$PREFIX/libexec/migrate-legacy" --singbox "$D$old_sb" --autoselect "$D$old_as"
  else
    info "vpn-split.conf уже существовал — импорт настроек пропущен"
  fi

  remove="/usr/local/etc/singbox-tun $BINDIR/vpn-urls"
  if [[ $OS == darwin ]]; then
    remove="$remove $LAUNCHD_DIR/com.singbox.tun.plist $LAUNCHD_DIR/com.local.xray.plist
            $LAUNCHD_DIR/com.local.vpn-autoselect.plist /usr/local/etc/xray $old_as
            /usr/local/var/vpn-autoselect /usr/local/bin/vpn-autoselect /var/log/singbox-tun.log"
    if [[ $NO_START -eq 0 ]]; then
      for p in com.singbox.tun local.xray local.vpn-autoselect; do
        launchctl bootout "system/$p" 2>/dev/null || true
      done
    fi
  else
    remove="$remove $SYSTEMD_DIR/singbox-tun.service"
    [[ $NO_START -eq 0 ]] && systemctl disable --now singbox-tun.service 2>/dev/null || true
    if [[ -n ${units// /} ]]; then
      if [[ $MIGRATE_XRAY -eq 0 ]] && confirm "Отключить старые службы ($units) — они держат порт xray?"; then
        MIGRATE_XRAY=1
      fi
      if [[ $MIGRATE_XRAY -eq 1 ]]; then
        # shellcheck disable=SC2086
        [[ $NO_START -eq 0 ]] && systemctl disable --now $units 2>/dev/null || true
        remove="$remove /usr/local/bin/vpn-autoselect $old_as /var/lib/vpn-autoselect"
        for p in $units; do
          case $p in xray.service) keep="$keep $SYSTEMD_DIR/$p" ;; *) remove="$remove $SYSTEMD_DIR/$p" ;; esac
        done
        keep="$keep /usr/local/etc/xray"
      else
        XRAY_CONFLICT=1
        warn "старые службы ($units) оставлены; повторите с --migrate-xray, иначе конфликт порта 20808"
      fi
    fi
  fi

  # резервная копия всего, что затрагиваем, затем удаление только своего
  local list="" rel
  for p in $remove $keep; do
    [[ -e $D$p ]] && { rel=${p#/}; list="$list $rel"; }
  done
  if [[ -n ${list// /} ]]; then
    mkd "$D$BACKUP_DIR"
    local bak
    bak="$BACKUP_DIR/vpn-split-legacy-$(date +%Y%m%d-%H%M%S).tar.gz"
    # shellcheck disable=SC2086
    tar -czf "$D$bak" -C "$D/" $list
    chmod 600 "$D$bak"
    info "резервная копия: $bak"
    for p in $remove; do [[ -e $D$p ]] && safe_rm "$D$p"; done
    [[ $NO_START -eq 0 && $OS == linux ]] && systemctl daemon-reload || true
  fi
  info "старые sing-box/xray из /usr/local/bin и brew не удалялись — при ненадобности удалите сами"
}

install_wrappers() {
  if [[ $OS == windows ]]; then
    info "команды: $PREFIX\\bin\\vpn-urls.cmd (запуск из консоли с правами администратора)"
    return 0
  fi
  log "команды: $BINDIR/vpn-urls, $SBINDIR/vpn-autoselect"
  mkd "$D$BINDIR" "$D$SBINDIR"
  render_template "$REPO/init/wrapper.in" "$D$BINDIR/vpn-urls" 755 "TARGET=$PREFIX/bin/vpn-urls"
  render_template "$REPO/init/wrapper.in" "$D$SBINDIR/vpn-autoselect" 755 "TARGET=$PREFIX/libexec/vpn-autoselect"
  # sinkhole-guard: отравленные корпоративным DNS IP -> table 2022 (см. шапку скрипта)
  install -m 755 "$REPO/tools/vpn-split-sinkhole-guard.sh" "$D$BINDIR/vpn-split-sinkhole-guard.sh"
  if [[ $OS == linux && -d $D/etc/NetworkManager/dispatcher.d ]]; then
    log "NetworkManager dispatcher -> /etc/NetworkManager/dispatcher.d/70-vpn-split-sinkhole"
    install -m 755 "$REPO/init/dispatcher/70-vpn-split-sinkhole" \
      "$D/etc/NetworkManager/dispatcher.d/70-vpn-split-sinkhole"
  fi
}

install_units() {
  local s
  if [[ $OS == windows ]]; then
    log "службы Windows (WinSW) и задачи планировщика -> $PREFIX"
    render_template "$REPO/init/windows/tun.cmd.in" "$D$PREFIX/bin/tun.cmd" 755 \
      "PYTHON=$(winpath "$PYTHON")" "PREFIX=$(winpath "$PREFIX")" "STATEDIR=$(winpath "$STATEDIR")"
    render_template "$REPO/init/windows/tun.xml.in" "$D$PREFIX/bin/vpn-split-tun.xml" 644 \
      "PREFIX=$(winpath "$PREFIX")" "LOGDIR=$(winpath "$LOGDIR")"
    render_template "$REPO/init/windows/xray.xml.in" "$D$PREFIX/bin/vpn-split-xray.xml" 644 \
      "PREFIX=$(winpath "$PREFIX")" "STATEDIR=$(winpath "$STATEDIR")" "LOGDIR=$(winpath "$LOGDIR")"
    [[ -n $D ]] && { info "DESTDIR: службы и задачи не ставятся"; return 0; }
    # WinSW: пересоздать службы (install падает, если служба уже есть; uninstall —
    # если служба запущена: сначала stopwait, как systemctl restart)
    local svc
    for svc in tun xray; do
      "$PREFIX/bin/vpn-split-$svc.exe" stopwait >/dev/null 2>&1 || true
      "$PREFIX/bin/vpn-split-$svc.exe" uninstall >/dev/null 2>&1 || true
      "$PREFIX/bin/vpn-split-$svc.exe" install >/dev/null \
        || die "не удалось создать службу vpn-split-$svc (нужны права администратора)"
    done
    info "службы созданы: $UNIT_PREFIX-tun, $UNIT_PREFIX-xray (автостарт)"
    # задачи: autoselect — всегда; update — только для git-клона
    local ps1="$PREFIX/share/register-tasks.ps1"
    if auto_update; then
      render_template "$REPO/init/windows/register-tasks.ps1.in" "$ps1" 644 \
        "PYTHON=$(winpath "$PYTHON")" "PREFIX=$(winpath "$PREFIX")" \
        "OWNER=$(whoami)" \
        "SRC_DIR=$(winpath "$REPO")" "GITBASH=$(winpath "$(command -v bash)")"
    else
      render_template "$REPO/init/windows/register-tasks.ps1.in" "$ps1" 644 \
        "PYTHON=$(winpath "$PYTHON")" "PREFIX=$(winpath "$PREFIX")" \
        "OWNER=" "SRC_DIR=" "GITBASH="
      native schtasks /Delete /TN "$UNIT_PREFIX-update" /F >/dev/null 2>&1 || true
    fi
    powershell -NoProfile -ExecutionPolicy Bypass -File "$(winpath "$ps1")"
    return 0
  fi
  if [[ $OS == linux ]]; then
    log "systemd-юниты -> $SYSTEMD_DIR"
    mkd "$D$SYSTEMD_DIR"
    # LoadCredential/DynamicUser — systemd ≥ 247; на старых xray работает от root
    local sdv=999 sandbox conf_path
    have systemctl && sdv="$(systemctl --version 2>/dev/null | awk 'NR==1{print $2+0}')"
    if [[ ${sdv:-0} -ge 247 ]]; then
      sandbox="DynamicUser=true
# xray.json (0600 root) передаётся как credential — читать его может только эта служба
LoadCredential=xray.json:$STATEDIR/xray.json"
      # shellcheck disable=SC2016  # раскрывает systemd, не shell
      conf_path='${CREDENTIALS_DIRECTORY}/xray.json'
    else
      sandbox="# systemd $sdv < 247: без DynamicUser/LoadCredential"
      conf_path="$STATEDIR/xray.json"
    fi
    render_template "$REPO/init/systemd/xray.service.in" "$D$SYSTEMD_DIR/$UNIT_PREFIX-xray.service" 644 \
      "XRAY_SANDBOX=$sandbox" "XRAY_CONF_PATH=$conf_path"
    for s in autoselect.service autoselect.timer tun.service; do
      render_template "$REPO/init/systemd/$s.in" "$D$SYSTEMD_DIR/$UNIT_PREFIX-$s" 644
    done
    for s in update.service update.timer; do
      if auto_update; then
        render_template "$REPO/init/systemd/$s.in" "$D$SYSTEMD_DIR/$UNIT_PREFIX-$s" 644
      elif [[ -f $D$SYSTEMD_DIR/$UNIT_PREFIX-$s ]]; then
        [[ $NO_START -eq 0 ]] && systemctl disable --now "$UNIT_PREFIX-$s" 2>/dev/null || true
        rm -f "$D$SYSTEMD_DIR/$UNIT_PREFIX-$s"
      fi
    done
  else
    log "LaunchDaemons -> $LAUNCHD_DIR"
    mkd "$D$LAUNCHD_DIR" "$D$NEWSYSLOG_DIR"
    for s in $SERVICES; do
      render_template "$REPO/init/launchd/$s.plist.in" "$D$LAUNCHD_DIR/$LABEL_PREFIX.$s.plist" 644
      [[ $EUID -eq 0 ]] && chown root:wheel "$D$LAUNCHD_DIR/$LABEL_PREFIX.$s.plist"
    done
    render_template "$REPO/init/launchd/newsyslog.conf.in" "$D$NEWSYSLOG_DIR/$UNIT_PREFIX.conf" 644
    if auto_update; then
      render_template "$REPO/init/launchd/update.plist.in" "$D$LAUNCHD_DIR/$LABEL_PREFIX.update.plist" 644
      if [[ $EUID -eq 0 ]]; then chown root:wheel "$D$LAUNCHD_DIR/$LABEL_PREFIX.update.plist"; fi
    elif [[ -f $D$LAUNCHD_DIR/$LABEL_PREFIX.update.plist ]]; then
      [[ $NO_START -eq 0 ]] && launchctl bootout "system/$LABEL_PREFIX.update" 2>/dev/null || true
      rm -f "$D$LAUNCHD_DIR/$LABEL_PREFIX.update.plist"
    fi
  fi
}

# автообновление: только из git-клона и если не выключено AUTO_UPDATE=0
auto_update() {
  [[ -e $REPO/.git ]] && have git && [[ $(conf_get AUTO_UPDATE) != 0 ]]
}

# коммит клона, из которого установлено (сравнивает vpn-split-update);
# пишется последним, чтобы неудачная установка повторилась при следующей проверке
record_source_rev() {
  local rev=""
  [[ -e $REPO/.git ]] && have git && rev="$(git -c safe.directory="$REPO" -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n $rev ]]; then
    printf '%s\n' "$rev" > "$D$PREFIX/share/source-rev"
  else
    rm -f "$D$PREFIX/share/source-rev"
  fi
}

launchd_load() {  # перезагрузка LaunchDaemon: bootout асинхронный, поэтому bootstrap с повтором
  local label="$LABEL_PREFIX.$1" _
  launchctl bootout "system/$label" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    launchctl bootstrap system "$LAUNCHD_DIR/$label.plist" 2>/dev/null && return 0
    sleep 1
  done
  die "launchctl bootstrap $label не удался"
}

start_services() {
  if [[ $NO_START -eq 1 ]]; then info "службы не запускаются (--no-start/DESTDIR)"; return 0; fi
  [[ $OS == linux ]] && systemctl daemon-reload
  if [[ $XRAY_CONFLICT -eq 1 ]]; then
    warn "службы vpn-split не запущены из-за старого xray — повторите: sudo $0 --migrate-xray"
    return 0
  fi
  if [[ -z $(conf_get SUB_URL) && -z $(conf_get NODES_FILE) ]]; then
    warn "SUB_URL не задан — впишите его в $SYSCONFDIR/vpn-split.conf и повторите sudo $0"
    return 0
  fi

  log "первый прогон vpn-autoselect (конфиг xray)"
  "$PY" "$PREFIX/libexec/vpn-autoselect" --force --no-restart \
    || warn "vpn-autoselect завершился с ошибкой — xray стартует после успешного прогона по таймеру"

  log "запуск служб"
  local s
  if [[ $OS == linux ]]; then
    systemctl enable --quiet "$UNIT_PREFIX-xray.service" "$UNIT_PREFIX-autoselect.timer" "$UNIT_PREFIX-tun.service"
    systemctl restart "$UNIT_PREFIX-xray.service" "$UNIT_PREFIX-autoselect.timer"
    systemctl restart "$UNIT_PREFIX-tun.service"
    if auto_update; then
      systemctl enable --quiet "$UNIT_PREFIX-update.timer"
      systemctl restart "$UNIT_PREFIX-update.timer"
    fi
    sleep 3
    for s in xray.service autoselect.timer tun.service update.timer; do
      [[ -f $SYSTEMD_DIR/$UNIT_PREFIX-$s ]] || continue
      info "$(printf '%-28s %s' "$UNIT_PREFIX-$s" "$(systemctl is-active "$UNIT_PREFIX-$s" || true)")"
    done
  elif [[ $OS == darwin ]]; then
    for s in $SERVICES; do launchd_load "$s"; done
    # из самого vpn-split-update не перезагружаем: bootout убил бы текущий запуск
    if auto_update && [[ -z ${VPN_SPLIT_SELF_UPDATE:-} ]]; then launchd_load update; fi
    sleep 3
    for s in $SERVICES update; do
      [[ -f $LAUNCHD_DIR/$LABEL_PREFIX.$s.plist ]] || continue
      info "$LABEL_PREFIX.$s: $(launchctl print "system/$LABEL_PREFIX.$s" 2>/dev/null | awk '/^\tstate =/{print $3; exit}')"
    done
  else
    "$PREFIX/bin/vpn-split-xray.exe" start >/dev/null || warn "vpn-split-xray не запустился"
    "$PREFIX/bin/vpn-split-tun.exe" start >/dev/null || warn "vpn-split-tun не запустился"
    sleep 3
    powershell -NoProfile -Command 'Get-Service vpn-split-xray, vpn-split-tun | Format-Table Name, Status -AutoSize'
  fi
}

cmd_install() {
  need_root install
  [[ -n $D ]] && info "поэтапная установка в DESTDIR=$D"
  if [[ $NO_DEPS -eq 1 ]]; then
    if [[ $OS == windows ]]; then
      find_system_python || die "Python ≥ 3.8 не найден (уберите --no-deps)"
    else
      find_system_python || find_uv_python || die "Python ≥ 3.8 не найден (уберите --no-deps)"
    fi
  else
    cmd_deps
  fi
  [[ -n $PY ]] || die "Python ≥ 3.8 не найден"
  # в файлы Windows (юниты, задачи) путь идёт в форме C:\…; для скриптов самого
  # установщика остаётся $PY в POSIX-форме
  PYTHON="$(winpath "$PY")"
  install_files
  install_binaries
  setup_config
  migrate_legacy
  set_sub_url
  install_wrappers
  install_units
  start_services
  record_source_rev
  if [[ $OS == windows ]]; then
    cat <<EOF

Готово: vpn-split $VPN_SPLIT_VERSION ($OS/$ARCH, Python: $PYTHON)
  настройки:   $SYSCONFDIR/vpn-split.conf, domains.proxy, domains.direct
  состояние:   $STATEDIR/status.json (текущие узлы)
  службы:      vpn-split-tun, vpn-split-xray (автостарт); задачи vpn-split-autoselect (10 мин)
  свои домены: vpn-urls.cmd add example.com  (консоль от имени администратора)
               список: vpn-urls.cmd list; добавить $PREFIX\\bin в PATH при желании
  статус:      $0 status   логи: $LOGDIR\\vpn-split-tun.err.log, $LOGDIR\\vpn-split-xray.out.log (WinSW)
  обновления:  $(auto_update && echo "автоматически из $REPO (задача vpn-split-update, раз в час)" || echo "вручную: git pull && $0")
  проверка:    curl --noproxy '*' -s https://api.ipify.org          # RU IP = остальное напрямую
               curl --noproxy '*' -sI https://www.instagram.com/    # 200 = заблокированное через VPN
EOF
  else
    cat <<EOF

Готово: vpn-split $VPN_SPLIT_VERSION ($OS/$ARCH, Python: $PYTHON)
  настройки:   $SYSCONFDIR/vpn-split.conf, domains.proxy, domains.direct
  состояние:   $STATEDIR/status.json (текущие узлы)
  свои домены: sudo vpn-urls add example.com | vpn-urls list
  статус:      sudo $0 status
  обновления:  $(auto_update && echo "автоматически из $REPO (vpn-split-update, раз в час)" || echo "вручную: git pull && sudo $0")
  проверка:    curl --noproxy '*' -s https://api.ipify.org          # RU IP = остальное напрямую
               curl --noproxy '*' -sI https://www.instagram.com/    # 200 = заблокированное через VPN
EOF
  fi
}

cmd_uninstall() {
  need_root uninstall
  log "удаление vpn-split"
  local s f
  if [[ $OS == windows ]]; then
    for s in tun xray; do
      if [[ -x $D$PREFIX/bin/vpn-split-$s.exe ]]; then
        "$D$PREFIX/bin/vpn-split-$s.exe" stop >/dev/null 2>&1 || true
        "$D$PREFIX/bin/vpn-split-$s.exe" uninstall >/dev/null 2>&1 || true
      fi
    done
    for s in autoselect update; do
      native schtasks /Delete /TN "$UNIT_PREFIX-$s" /F >/dev/null 2>&1 || true
    done
    info "службы и задачи удалены"
  elif [[ $OS == linux ]]; then
    if [[ $NO_START -eq 0 ]]; then
      systemctl disable --now "$UNIT_PREFIX-tun.service" "$UNIT_PREFIX-autoselect.timer" \
        "$UNIT_PREFIX-autoselect.service" "$UNIT_PREFIX-xray.service" \
        "$UNIT_PREFIX-update.timer" "$UNIT_PREFIX-update.service" 2>/dev/null || true
    fi
    for s in xray.service autoselect.service autoselect.timer tun.service update.service update.timer; do
      rm -f "$D$SYSTEMD_DIR/$UNIT_PREFIX-$s"
    done
    [[ $NO_START -eq 0 ]] && systemctl daemon-reload
  else
    for s in update tun autoselect xray; do
      [[ $NO_START -eq 0 ]] && launchctl bootout "system/$LABEL_PREFIX.$s" 2>/dev/null || true
      rm -f "$D$LAUNCHD_DIR/$LABEL_PREFIX.$s.plist"
    done
    rm -f "$D$NEWSYSLOG_DIR/$UNIT_PREFIX.conf"
  fi
  for f in "$D$BINDIR/vpn-urls" "$D$SBINDIR/vpn-autoselect"; do
    # удаляем только собственные обёртки
    [[ -f $f ]] && grep -q 'vpn-split: обёртка' "$f" && rm -f "$f"
  done
  [[ -d $D$PREFIX ]] && safe_rm "$D$PREFIX"
  if [[ $PURGE -eq 1 ]]; then
    for f in "$D$SYSCONFDIR" "$D$STATEDIR" "$D$LOGDIR"; do [[ -e $f ]] && safe_rm "$f"; done
    info "удалено вместе с настройками и состоянием"
  else
    info "оставлены: $SYSCONFDIR (настройки, подписка), $STATEDIR — удалить: $0 uninstall --purge"
  fi
}

cmd_status() {
  local s
  if [[ $OS == windows ]]; then
    powershell -NoProfile -Command 'Get-Service vpn-split-tun, vpn-split-xray | Format-Table Name, Status -AutoSize'
    MSYS_NO_PATHCONV=1 schtasks /Query /FO CSV 2>/dev/null | grep -i "vpn-split" || true
    info "логи: $LOGDIR\\vpn-split-tun.err.log, $LOGDIR\\vpn-split-xray.out.log"
  elif [[ $OS == linux ]]; then
    for s in xray.service autoselect.timer tun.service update.timer; do
      printf '%-28s %s\n' "$UNIT_PREFIX-$s" "$(systemctl is-active "$UNIT_PREFIX-$s" 2>/dev/null || true)"
    done
    info "логи: journalctl -u $UNIT_PREFIX-tun -u $UNIT_PREFIX-xray -u $UNIT_PREFIX-autoselect -u $UNIT_PREFIX-update"
  else
    for s in $SERVICES update; do
      printf '%-44s %s\n' "$LABEL_PREFIX.$s" \
        "$(launchctl print "system/$LABEL_PREFIX.$s" 2>/dev/null | awk '/^\tstate =/{print $3; exit}')"
    done
    info "логи: $LOGDIR/*.log"
  fi
  [[ -r $STATEDIR/status.json ]] && cat "$STATEDIR/status.json"
  return 0
}

case "$CMD" in
  install)   cmd_install ;;
  deps)      cmd_deps ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
esac
