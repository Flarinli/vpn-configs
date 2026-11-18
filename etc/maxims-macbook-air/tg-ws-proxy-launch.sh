#!/bin/bash
set -a
# shellcheck disable=SC1091
source "$HOME/.config/tg-ws-proxy/env"
set +a
exec "$HOME/.local/bin/tg-ws-proxy" \
  --dc-ip 1:149.154.175.50 \
  --dc-ip 2:149.154.167.51 \
  --dc-ip 3:149.154.160.10 \
  --dc-ip 4:149.154.164.250 \
  --dc-ip 5:149.154.171.5
