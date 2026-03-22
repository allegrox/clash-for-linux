# Clash shell helpers

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! declare -f ui_info >/dev/null 2>&1; then
  # shellcheck source=scripts/ui.sh
  source "$PROJECT_DIR/scripts/ui.sh"
fi

CLASH_INSTALL_DIR="${CLASH_INSTALL_DIR:-/root/clash-for-linux}"
ENV_FILE="${CLASH_INSTALL_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
  set +u
  . "$ENV_FILE" >/dev/null 2>&1 || true
  set -u
fi

CLASH_LISTEN_IP="${CLASH_LISTEN_IP:-127.0.0.1}"
CLASH_HTTP_PORT="${CLASH_HTTP_PORT:-7890}"
CLASH_SOCKS_PORT="${CLASH_SOCKS_PORT:-7891}"

proxy_on() {
  export http_proxy="http://${CLASH_LISTEN_IP}:${CLASH_HTTP_PORT}"
  export https_proxy="http://${CLASH_LISTEN_IP}:${CLASH_HTTP_PORT}"
  export HTTP_PROXY="http://${CLASH_LISTEN_IP}:${CLASH_HTTP_PORT}"
  export HTTPS_PROXY="http://${CLASH_LISTEN_IP}:${CLASH_HTTP_PORT}"
  export all_proxy="socks5://${CLASH_LISTEN_IP}:${CLASH_SOCKS_PORT}"
  export ALL_PROXY="socks5://${CLASH_LISTEN_IP}:${CLASH_SOCKS_PORT}"
  export no_proxy="127.0.0.1,localhost,::1"
  export NO_PROXY="127.0.0.1,localhost,::1"
  ui_ok "Proxy enabled: http://${CLASH_LISTEN_IP}:${CLASH_HTTP_PORT}"
}

proxy_off() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  unset all_proxy ALL_PROXY no_proxy NO_PROXY
  ui_ok "Proxy disabled"
}

proxy_status() {
  echo "http_proxy=${http_proxy:-<empty>}"
  echo "https_proxy=${https_proxy:-<empty>}"
  echo "all_proxy=${all_proxy:-<empty>}"
  echo "CLASH_LISTEN_IP=${CLASH_LISTEN_IP}"
  echo "CLASH_HTTP_PORT=${CLASH_HTTP_PORT}"
  echo "CLASH_SOCKS_PORT=${CLASH_SOCKS_PORT}"
}