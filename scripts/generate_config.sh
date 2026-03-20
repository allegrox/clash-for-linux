#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/runtime"
CONF_DIR="$PROJECT_DIR/conf"
TEMP_DIR="$PROJECT_DIR/temp"
LOG_DIR="$PROJECT_DIR/logs"

RUNTIME_CONFIG="$RUNTIME_DIR/config.yaml"
STATE_FILE="$RUNTIME_DIR/state.env"
TEMP_DOWNLOAD="$TEMP_DIR/clash.yaml"
TEMP_CONVERTED="$TEMP_DIR/clash_config.yaml"

mkdir -p "$RUNTIME_DIR" "$CONF_DIR" "$TEMP_DIR" "$LOG_DIR"

# shellcheck disable=SC1091
source "$PROJECT_DIR/.env"

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
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

SECRET="$(generate_secret)"

upsert_yaml_kv() {
  local file="$1" key="$2" value="$3"
  [ -f "$file" ] || touch "$file"

  if grep -qE "^[[:space:]]*${key}:" "$file"; then
    sed -i -E "s|^[[:space:]]*${key}:.*$|${key}: ${value}|g" "$file"
  else
    printf "%s: %s\n" "$key" "$value" >> "$file"
  fi
}

force_write_secret() {
  local file="$1"
  upsert_yaml_kv "$file" "secret" "$SECRET"
}

force_write_controller_and_ui() {
  local file="$1"

  if [ "$EXTERNAL_CONTROLLER_ENABLED" = "true" ]; then
    upsert_yaml_kv "$file" "external-controller" "$EXTERNAL_CONTROLLER"

    mkdir -p "$RUNTIME_DIR"
    ln -sfn "$PROJECT_DIR/dashboard/public" "$RUNTIME_DIR/ui"

    upsert_yaml_kv "$file" "external-ui" "$RUNTIME_DIR/ui"
  fi
}

download_subscription() {
  [ -n "$CLASH_URL" ] || return 1

  local curl_cmd=(curl -fL -S --retry 2 --connect-timeout 10 -m 30 -o "$TEMP_DOWNLOAD")
  [ "$ALLOW_INSECURE_TLS" = "true" ] && curl_cmd+=(-k)
  curl_cmd+=("$CLASH_URL")

  "${curl_cmd[@]}"
}

use_fallback() {
  [ -s "$CONF_DIR/fallback_config.yaml" ] || return 1
  cp -f "$CONF_DIR/fallback_config.yaml" "$RUNTIME_CONFIG"
  force_write_controller_and_ui "$RUNTIME_CONFIG"
  force_write_secret "$RUNTIME_CONFIG"
}

is_full_config() {
  local file="$1"
  grep -qE '^(proxies:|proxy-providers:|mixed-port:|port:)' "$file"
}

main() {
    if [ "$CLASH_AUTO_UPDATE" != "true" ]; then
        if [ -s "$RUNTIME_CONFIG" ]; then
        write_state "success" "auto_update_disabled_keep_runtime" "runtime_existing"
        exit 0
        fi
        use_fallback
        write_state "success" "auto_update_disabled_use_fallback" "fallback"
        exit 0
    fi

    if ! download_subscription; then
        if [ -s "$RUNTIME_CONFIG" ]; then
        write_state "success" "download_failed_keep_last_good" "runtime_existing"
        exit 0
        fi
        use_fallback
        write_state "success" "download_failed_use_fallback" "fallback"
        exit 0
    fi

    cp -f "$TEMP_DOWNLOAD" "$TEMP_CONVERTED"

    if is_full_config "$TEMP_CONVERTED"; then
        cp -f "$TEMP_CONVERTED" "$RUNTIME_CONFIG"
        force_write_controller_and_ui "$RUNTIME_CONFIG"
        force_write_secret "$RUNTIME_CONFIG"
        write_state "success" "subscription_full" "subscription_full"
        exit 0
    fi

    # 片段订阅：这里先保留模板拼接逻辑
    TEMPLATE_FILE=""

    if [ -s "$CONF_DIR/template_config.yaml" ]; then
    TEMPLATE_FILE="$CONF_DIR/template_config.yaml"
    elif [ -s "$TEMP_DIR/templete_config.yaml" ]; then
    TEMPLATE_FILE="$TEMP_DIR/templete_config.yaml"
    elif [ -s "$CONF_DIR/templete_config.yaml" ]; then
    TEMPLATE_FILE="$CONF_DIR/templete_config.yaml"
    elif [ -s "$PROJECT_DIR/temp/templete_config.yaml" ]; then
    TEMPLATE_FILE="$PROJECT_DIR/temp/templete_config.yaml"
    fi

    if [ -z "$TEMPLATE_FILE" ]; then
    echo "[ERROR] missing template config file (template_config.yaml / templete_config.yaml)" >&2
    write_state "failed" "missing_template" "none"
    exit 1
    fi

    sed -n '/^proxies:/,$p' "$TEMP_CONVERTED" > "$TEMP_DIR/proxy.txt"
    cat "$TEMPLATE_FILE" > "$RUNTIME_CONFIG"
    cat "$TEMP_DIR/proxy.txt" >> "$RUNTIME_CONFIG"

    sed -i "s/CLASH_HTTP_PORT_PLACEHOLDER/${CLASH_HTTP_PORT}/g" "$RUNTIME_CONFIG"
    sed -i "s/CLASH_SOCKS_PORT_PLACEHOLDER/${CLASH_SOCKS_PORT}/g" "$RUNTIME_CONFIG"
    sed -i "s/CLASH_REDIR_PORT_PLACEHOLDER/${CLASH_REDIR_PORT}/g" "$RUNTIME_CONFIG"
    sed -i "s/CLASH_LISTEN_IP_PLACEHOLDER/${CLASH_LISTEN_IP}/g" "$RUNTIME_CONFIG"
    sed -i "s/CLASH_ALLOW_LAN_PLACEHOLDER/${CLASH_ALLOW_LAN}/g" "$RUNTIME_CONFIG"

    force_write_controller_and_ui "$RUNTIME_CONFIG"
    force_write_secret "$RUNTIME_CONFIG"

    write_state "success" "subscription_fragment_merged" "subscription_fragment"
}

main "$@"