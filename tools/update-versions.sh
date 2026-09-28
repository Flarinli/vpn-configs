#!/usr/bin/env bash
# Обновляет versions.env: закреплённые версии sing-box и xray и sha256 их
# релизных архивов для {linux,darwin}×{amd64,arm64}. install.sh ставит только
# то, что совпало с этими суммами.
#
#   tools/update-versions.sh                       # пересчитать суммы для текущих версий
#   tools/update-versions.sh 1.12.25 26.9.9        # сменить версии (sing-box, xray)
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/versions.env"
SINGBOX_VERSION="${1:-$SINGBOX_VERSION}"
XRAY_VERSION="${2:-$XRAY_VERSION}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# URL-ы и имена архивов — те же функции, что использует install.sh
. "$ROOT/lib/download.sh"

{
  echo "# Сгенерировано tools/update-versions.sh — не править вручную."
  echo "VPN_SPLIT_VERSION=$VPN_SPLIT_VERSION"
  echo "SINGBOX_VERSION=$SINGBOX_VERSION"
  echo "XRAY_VERSION=$XRAY_VERSION"
  echo "UV_PYTHON_VERSION=$UV_PYTHON_VERSION"
  for tool in singbox xray; do
    for os in linux darwin; do
      for arch in amd64 arm64; do
        url=$("${tool}_url" "$os" "$arch")
        echo "  $url" >&2
        curl -fsSL --retry 3 -o "$WORK/pkg" "$url"
        echo "SHA256_${tool}_${os}_${arch}=$(sha256_of "$WORK/pkg")"
      done
    done
  done
} > "$WORK/versions.env"
mv "$WORK/versions.env" "$ROOT/versions.env"
cat "$ROOT/versions.env"
