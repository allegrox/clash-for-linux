#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/runtime"
CONFIG_DIR="$PROJECT_DIR/config"
LOG_DIR="$PROJECT_DIR/logs"

RUNTIME_CONFIG="$RUNTIME_DIR/config.yaml"
STATE_FILE="$RUNTIME_DIR/state.env"

TMP_DOWNLOAD="$RUNTIME_DIR/subscription.raw.yaml"
TMP_NORMALIZED="$RUNTIME_DIR/subscription.normalized.yaml"
TMP_PROXY_FRAGMENT="$RUNTIME_DIR/proxy.fragment.yaml"

mkdir -p "$RUNTIME_DIR" "$CONFIG_DIR" "$LOG_DIR"

if [ -f "$PROJECT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$PROJECT_DIR/.env"
fi

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/get_cpu_arch.sh"
# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/resolve_clash.sh"
# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/config_utils.sh"
# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/port_utils.sh"

CLASH_HTTP_PORT="${CLASH_HTTP_PORT:-7890}"
CLASH_SOCKS_PORT="${CLASH_SOCKS_PORT:-7891}"
CLASH_REDIR_PORT="${CLASH_REDIR_PORT:-7892}"
CLASH_LISTEN_IP="${CLASH_LISTEN_IP:-0.0.0.0}"
CLASH_ALLOW_LAN="${CLASH_ALLOW_LAN:-false}"
EXTERNAL_CONTROLLER_ENABLED="${EXTERNAL_CONTROLLER_ENABLED:-true}"
EXTERNAL_CONTROLLER="${EXTERNAL_CONTROLLER:-127.0.0.1:9090}"
ALLOW_INSECURE_TLS="${ALLOW_INSECURE_TLS:-false}"
CLASH_AUTO_UPDATE="${CLASH_AUTO_UPDATE:-true}"
CLASH_URL="${CLASH_URL:-}"

CLASH_HTTP_PORT="$(resolve_port_value "HTTP" "$CLASH_HTTP_PORT")"
CLASH_SOCKS_PORT="$(resolve_port_value "SOCKS" "$CLASH_SOCKS_PORT")"
CLASH_REDIR_PORT="$(resolve_port_value "REDIR" "$CLASH_REDIR_PORT")"
EXTERNAL_CONTROLLER="$(resolve_host_port "External Controller" "$EXTERNAL_CONTROLLER" "127.0.0.1")"

write_state() {
  local status="$1"
  local reason="$2"
  local source="${3:-unknown}"

  cat > "$STATE_FILE" <<EOF
LAST_GENERATE_STATUS=$status
LAST_GENERATE_REASON=$reason
LAST_CONFIG_SOURCE=$source
LAST_GENERATE_AT=$(date -Iseconds)
EOF
}

generate_secret() {
  if [ -n "${CLASH_SECRET:-}" ]; then
    echo "$CLASH_SECRET"
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

SECRET="$(generate_secret)"

upsert_yaml_kv_local() {
  local file="$1"
  local key="$2"
  local value="$3"

  [ -f "$file" ] || touch "$file"

  if grep -qE "^[[:space:]]*${key}:" "$file"; then
    sed -i -E "s|^[[:space:]]*${key}:.*$|${key}: ${value}|g" "$file"
  else
    printf "%s: %s\n" "$key" "$value" >> "$file"
  fi
}

apply_secret_to_config() {
  local file="$1"
  upsert_yaml_kv_local "$file" "secret" "$SECRET"
}

apply_controller_to_config() {
  local file="$1"

  if [ "$EXTERNAL_CONTROLLER_ENABLED" = "true" ]; then
    upsert_yaml_kv_local "$file" "external-controller" "$EXTERNAL_CONTROLLER"

    local mihomo_home
    mihomo_home="${HOME:-/root}/.config/mihomo"

    mkdir -p "$mihomo_home"
    ln -sfn "$PROJECT_DIR/dashboard/public" "$mihomo_home/ui"

    upsert_yaml_kv_local "$file" "external-ui" "$mihomo_home/ui"
  fi
}

download_subscription() {
  [ -n "$CLASH_URL" ] || return 1

  local curl_cmd=(curl -fL -S --retry 2 --connect-timeout 10 -m 30 -o "$TMP_DOWNLOAD")
  [ "$ALLOW_INSECURE_TLS" = "true" ] && curl_cmd+=(-k)
  curl_cmd+=("$CLASH_URL")

  "${curl_cmd[@]}"
}

is_complete_clash_config() {
  local file="$1"
  grep -qE '^(proxies:|proxy-providers:|mixed-port:|port:)' "$file"
}

cleanup_tmp_files() {
  rm -f "$TMP_NORMALIZED" "$TMP_PROXY_FRAGMENT"
}

main() {
  local template_file="$CONFIG_DIR/template.yaml"

  if [ "$CLASH_AUTO_UPDATE" != "true" ]; then
    if [ -s "$RUNTIME_CONFIG" ]; then
      write_state "success" "auto_update_disabled_keep_runtime" "runtime_existing"
      exit 0
    fi

    echo "[ERROR] auto update disabled and runtime config missing: $RUNTIME_CONFIG" >&2
    write_state "failed" "runtime_missing" "none"
    exit 1
  fi

  if ! download_subscription; then
    if [ -s "$RUNTIME_CONFIG" ]; then
      write_state "success" "download_failed_keep_runtime" "runtime_existing"
      exit 0
    fi

    echo "[ERROR] failed to download subscription and runtime config missing" >&2
    write_state "failed" "download_failed" "none"
    exit 1
  fi

  cp -f "$TMP_DOWNLOAD" "$TMP_NORMALIZED"

  if is_complete_clash_config "$TMP_NORMALIZED"; then
    cp -f "$TMP_NORMALIZED" "$RUNTIME_CONFIG"
    apply_controller_to_config "$RUNTIME_CONFIG"
    apply_secret_to_config "$RUNTIME_CONFIG"
    write_state "success" "subscription_full" "subscription_full"
    cleanup_tmp_files
    exit 0
  fi

  if [ ! -s "$template_file" ]; then
    echo "[ERROR] missing template config file: $template_file" >&2
    write_state "failed" "missing_template" "none"
    cleanup_tmp_files
    exit 1
  fi

  sed -n '/^proxies:/,$p' "$TMP_NORMALIZED" > "$TMP_PROXY_FRAGMENT"

  cat "$template_file" > "$RUNTIME_CONFIG"
  cat "$TMP_PROXY_FRAGMENT" >> "$RUNTIME_CONFIG"

  sed -i "s/CLASH_HTTP_PORT_PLACEHOLDER/${CLASH_HTTP_PORT}/g" "$RUNTIME_CONFIG"
  sed -i "s/CLASH_SOCKS_PORT_PLACEHOLDER/${CLASH_SOCKS_PORT}/g" "$RUNTIME_CONFIG"
  sed -i "s/CLASH_REDIR_PORT_PLACEHOLDER/${CLASH_REDIR_PORT}/g" "$RUNTIME_CONFIG"
  sed -i "s/CLASH_LISTEN_IP_PLACEHOLDER/${CLASH_LISTEN_IP}/g" "$RUNTIME_CONFIG"
  sed -i "s/CLASH_ALLOW_LAN_PLACEHOLDER/${CLASH_ALLOW_LAN}/g" "$RUNTIME_CONFIG"

  apply_controller_to_config "$RUNTIME_CONFIG"
  apply_secret_to_config "$RUNTIME_CONFIG"

  write_state "success" "subscription_fragment_merged" "subscription_fragment"
  cleanup_tmp_files
}

main "$@"