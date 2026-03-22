#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! declare -f ui_info >/dev/null 2>&1; then
  # shellcheck source=scripts/ui.sh
  source "$PROJECT_DIR/scripts/ui.sh"
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/runtime"
CONFIG_DIR="$PROJECT_DIR/config"
LOG_DIR="$PROJECT_DIR/logs"

RUNTIME_CONFIG="$RUNTIME_DIR/config.yaml"
STATE_FILE="$RUNTIME_DIR/state.env"

TMP_DOWNLOAD="$RUNTIME_DIR/subscription.raw.yaml"
TMP_NORMALIZED="$RUNTIME_DIR/subscription.normalized.yaml"
TMP_PROXY_FRAGMENT="$RUNTIME_DIR/proxy.fragment.yaml"
TMP_CONFIG="$RUNTIME_DIR/config.yaml.tmp"

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

trim_value() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

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

fail_with_state() {
  local reason="$1"
  local message="$2"
  local source="${3:-none}"

  write_state "failed" "$reason" "$source"
  ui_error "$message" >&2
  exit 1
}

write_env_value() {
  local key="$1"
  local value="$2"
  local env_file="$PROJECT_DIR/.env"
  local tmp_file

  [ -f "$env_file" ] || return 1

  tmp_file="$(mktemp)"

  awk -v k="$key" -v v="$value" '
    BEGIN { updated = 0 }
    $0 ~ "^[[:space:]]*(export[[:space:]]+)?" k "=" {
      print "export " k "='\''" v "'\''"
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) {
        print "export " k "='\''" v "'\''"
      }
    }
  ' "$env_file" > "$tmp_file" && mv "$tmp_file" "$env_file"
}

generate_secret() {
  if [ -n "${CLASH_SECRET:-}" ]; then
    echo "$CLASH_SECRET"
    return 0
  fi

  if [ -s "$RUNTIME_CONFIG" ]; then
    local old_secret
    old_secret="$(sed -nE 's/^[[:space:]]*secret:[[:space:]]*"?([^"#]+)"?.*$/\1/p' "$RUNTIME_CONFIG" | head -n 1)"
    if [ -n "${old_secret:-}" ]; then
      echo "$old_secret"
      return 0
    fi
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16
  fi
}

SECRET="$(generate_secret)"
write_env_value "CLASH_SECRET" "$SECRET" || true

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

remove_yaml_key_local() {
  local file="$1"
  local key="$2"

  [ -f "$file" ] || return 0
  sed -i -E "/^[[:space:]]*${key}:/d" "$file"
}

apply_secret_to_config() {
  local file="$1"
  upsert_yaml_kv_local "$file" "secret" "$SECRET"
}

apply_controller_to_config() {
  local file="$1"
  local ui_src="$PROJECT_DIR/ui/dist"
  local ui_dir="$RUNTIME_DIR/ui"

  if [ "$EXTERNAL_CONTROLLER_ENABLED" = "true" ]; then
    upsert_yaml_kv_local "$file" "external-controller" "$EXTERNAL_CONTROLLER"

    if [ ! -f "$ui_src/index.html" ]; then
      fail_with_state "ui_missing" "UI 未找到: $ui_src/index.html" "none"
    fi

    rm -rf "$ui_dir"
    mkdir -p "$ui_dir"
    cp -a "$ui_src/." "$ui_dir/"

    upsert_yaml_kv_local "$file" "external-ui" "$ui_dir"
  else
    remove_yaml_key_local "$file" "external-controller"
    remove_yaml_key_local "$file" "external-ui"
  fi
}

validate_clash_url() {
  local url="$1"

  url="$(trim_value "$url")"

  if [ -z "$url" ]; then
    write_state "failed" "url_empty" "none"
    ui_error "CLASH_URL 为空" >&2
    return 1
  fi

  case "$url" in
    http://*|https://*)
      ;;
    *)
      write_state "failed" "url_invalid" "none"
      ui_error "CLASH_URL 格式非法：必须以 http:// 或 https:// 开头" >&2
      return 1
      ;;
  esac

  if [[ "$url" =~ [[:space:]] ]]; then
    write_state "failed" "url_whitespace" "none"
    ui_error "CLASH_URL 含有空白字符" >&2
    return 1
  fi

  if [[ "$url" == "-"* ]]; then
    write_state "failed" "url_like_option" "none"
    ui_error "CLASH_URL 非法：看起来像 curl 参数而不是链接" >&2
    return 1
  fi

  return 0
}

download_subscription() {
  local url
  url="$(trim_value "${CLASH_URL:-}")"

  validate_clash_url "$url" || return 1

  local curl_cmd=(
    curl
    -fL
    -S
    --retry 2
    --connect-timeout 10
    -m 30
    -o "$TMP_DOWNLOAD"
    --
    "$url"
  )

  if [ "$ALLOW_INSECURE_TLS" = "true" ]; then
    curl_cmd=(
      curl
      -fL
      -S
      --retry 2
      --connect-timeout 10
      -m 30
      -k
      -o "$TMP_DOWNLOAD"
      --
      "$url"
    )
  fi

  if [ -n "${CLASH_HEADERS:-}" ]; then
    local header
    while IFS= read -r header; do
      header="$(trim_value "$header")"
      [ -n "$header" ] && curl_cmd=("${curl_cmd[@]:0:${#curl_cmd[@]}-2}" -H "$header" -- "$url")
    done < <(printf '%s\n' "$CLASH_HEADERS" | tr ';' '\n')
  fi

  "${curl_cmd[@]}"
}

is_complete_clash_config() {
  local file="$1"
  grep -qE '^[[:space:]]*(proxies:|proxy-providers:|mixed-port:|port:)' "$file"
}

cleanup_tmp_files() {
  rm -f "$TMP_DOWNLOAD" "$TMP_NORMALIZED" "$TMP_PROXY_FRAGMENT" "$TMP_CONFIG"
}

build_fragment_config() {
  local template_file="$1"
  local target_file="$2"

  sed -n '/^proxies:/,$p' "$TMP_NORMALIZED" > "$TMP_PROXY_FRAGMENT"

  cat "$template_file" > "$target_file"
  cat "$TMP_PROXY_FRAGMENT" >> "$target_file"

  sed -i "s/CLASH_HTTP_PORT_PLACEHOLDER/${CLASH_HTTP_PORT}/g" "$target_file"
  sed -i "s/CLASH_SOCKS_PORT_PLACEHOLDER/${CLASH_SOCKS_PORT}/g" "$target_file"
  sed -i "s/CLASH_REDIR_PORT_PLACEHOLDER/${CLASH_REDIR_PORT}/g" "$target_file"
  sed -i "s/CLASH_LISTEN_IP_PLACEHOLDER/${CLASH_LISTEN_IP}/g" "$target_file"
  sed -i "s/CLASH_ALLOW_LAN_PLACEHOLDER/${CLASH_ALLOW_LAN}/g" "$target_file"
}

finalize_config() {
  local file="$1"
  mv -f "$file" "$RUNTIME_CONFIG"
}

main() {
  local template_file="$CONFIG_DIR/template.yaml"

  if [ "$CLASH_AUTO_UPDATE" != "true" ]; then
    if [ -s "$RUNTIME_CONFIG" ]; then
      write_state "success" "auto_update_disabled_keep_runtime" "runtime_existing"
      exit 0
    fi

    fail_with_state "runtime_missing" "已关闭自动更新，且运行配置缺失: $RUNTIME_CONFIG" "none"
  fi

  CLASH_URL="$(trim_value "${CLASH_URL:-}")"

  if ! validate_clash_url "$CLASH_URL"; then
    exit 1
  fi

  if ! download_subscription; then
    write_state "failed" "download_failed" "none"
    ui_error "下载订阅失败" >&2
    exit 1
  fi

  if [ ! -s "$TMP_DOWNLOAD" ]; then
    fail_with_state "subscription_empty" "订阅下载成功但内容为空" "none"
  fi

  cp -f "$TMP_DOWNLOAD" "$TMP_NORMALIZED"

  if is_complete_clash_config "$TMP_NORMALIZED"; then
    cp -f "$TMP_NORMALIZED" "$TMP_CONFIG"
    apply_controller_to_config "$TMP_CONFIG"
    apply_secret_to_config "$TMP_CONFIG"
    finalize_config "$TMP_CONFIG"
    write_state "success" "subscription_full" "subscription_full"
    exit 0
  fi

  if ! grep -qE '^[[:space:]]*proxies:' "$TMP_NORMALIZED"; then
    fail_with_state "subscription_invalid" "订阅不可用或转换失败" "none"
  fi

  if [ ! -s "$template_file" ]; then
    fail_with_state "missing_template" "缺少模板配置文件: $template_file" "none"
  fi

  build_fragment_config "$template_file" "$TMP_CONFIG"
  apply_controller_to_config "$TMP_CONFIG"
  apply_secret_to_config "$TMP_CONFIG"
  finalize_config "$TMP_CONFIG"

  write_state "success" "subscription_fragment_merged" "subscription_fragment"
}

trap cleanup_tmp_files EXIT
main "$@"