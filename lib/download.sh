# shellcheck shell=bash
# vpn-split: адреса релизов sing-box и xray (используют install.sh и tools/update-versions.sh).
# Ожидает SINGBOX_VERSION и XRAY_VERSION; os: linux|darwin|windows, arch: amd64|arm64.

singbox_url() {
  local ext=tar.gz
  [[ $1 == windows ]] && ext=zip
  echo "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-$1-$2.$ext"
}

xray_url() {
  local os=$1 arch=$2
  [[ $os == darwin ]] && os=macos
  case $arch in amd64) arch=64 ;; arm64) arch=arm64-v8a ;; esac
  echo "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-${os}-${arch}.zip"
}

winsw_url() {
  echo "https://github.com/winsw/winsw/releases/download/v${WINSW_VERSION}/WinSW-x64.exe"
}
