#!/usr/bin/env bash

# shellcheck source=scripts/core/common.sh
source "${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/scripts/core/common.sh"

config_tmp_dir() {
  echo "$RUNTIME_DIR/tmp"
}

compile_error_file() {
  echo "$(config_tmp_dir)/compile-error.txt"
}

clear_compile_error() {
  rm -f "$(compile_error_file)" 2>/dev/null || true
}

write_compile_error() {
  local message="$1"
  printf '%s\n' "$message" > "$(compile_error_file)"
}

append_compile_error() {
  local message="$1"
  printf '%s\n' "$message" >> "$(compile_error_file)"
}

read_compile_error() {
  local file
  file="$(compile_error_file)"
  [ -f "$file" ] || return 1
  cat "$file"
}

single_line_text() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

record_build_error_detail() {
  local stage="$1"
  local detail="${2:-}"
  local summary=""

  detail="$(printf '%s' "$detail" | sed 's/\r$//')"

  if [ -n "${detail:-}" ]; then
    summary="$(printf '%s\n' "$detail" | head -n 1)"
  fi

  write_build_value "BUILD_LAST_ERROR_STAGE" "$stage"
  write_build_value "BUILD_LAST_ERROR_SUMMARY" "$(single_line_text "$summary")"
  write_build_value "BUILD_LAST_ERROR_DETAIL" "$detail"
}

clear_build_error_detail() {
  clear_build_error_meta
}

subscriptions_file() {
  echo "$RUNTIME_DIR/subscriptions.yaml"
}

migrate_subscriptions_legacy_fields() {
  local file="$1"
  [ -f "$file" ] || return 0

  if [ -x "$(yq_bin 2>/dev/null || true)" ]; then
    if "$(yq_bin)" eval '(.mode != null) or (.selected != null) or (.policy != null)' "$file" 2>/dev/null | grep -qx 'true'; then
      "$(yq_bin)" eval -i 'del(.mode) | del(.selected) | del(.policy)' "$file" 2>/dev/null || true
    fi
    return 0
  fi

  # 无 yq 时做最小兜底：仅移除顶层旧字段，避免旧语义继续扩散
  awk '
    $0 ~ /^[[:space:]]*mode:[[:space:]]*/ { next }
    $0 ~ /^[[:space:]]*selected:[[:space:]]*/ { next }
    $0 ~ /^[[:space:]]*policy:[[:space:]]*/ { next }
    { print }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

ensure_subscriptions_file() {
  local file legacy_file
  file="$(subscriptions_file)"
  legacy_file="$CONFIG_DIR/subscriptions.yaml"

  if [ -f "$file" ]; then
    migrate_subscriptions_legacy_fields "$file"
    return 0
  fi

  mkdir -p "$RUNTIME_DIR"

  if [ -f "$legacy_file" ]; then
    mv -f "$legacy_file" "$file" 2>/dev/null || {
      cp -f "$legacy_file" "$file"
      rm -f "$legacy_file" 2>/dev/null || true
    }
    migrate_subscriptions_legacy_fields "$file"
    return 0
  fi

  cat > "$file" <<'EOF'
active: default

sources:
  default:
    type: clash
    url: ""
    enabled: true
EOF

  migrate_subscriptions_legacy_fields "$file"
}

csv_count() {
  local csv="$1"

  if [ -z "${csv:-}" ]; then
    echo "0"
    return 0
  fi

  printf '%s' "$csv" | awk -F',' '{print ($1==""?0:NF)}'
}

active_subscription_name() {
  local file
  file="$(subscriptions_file)"
  ensure_subscriptions_file

  "$(yq_bin)" eval '.active // "default"' "$file" 2>/dev/null | head -n 1
}

first_subscription_name() {
  local file
  file="$(subscriptions_file)"
  ensure_subscriptions_file

  "$(yq_bin)" eval '.sources | keys | .[0] // ""' "$file" 2>/dev/null | head -n 1
}

active_profile_name() {
  local profiles_file="$CONFIG_DIR/profiles.yaml"

  [ -f "$profiles_file" ] || return 0

  "$(yq_bin)" eval '.active // ""' "$profiles_file" 2>/dev/null | head -n 1
}

tun_enabled() {
  local value

  value="$(read_tun_value "TUN_ENABLED" 2>/dev/null || true)"
  case "${value:-false}" in
    true|1|yes|on) echo "true" ;;
    *) echo "false" ;;
  esac
}

set_tun_enabled() {
  local enabled="$1"

  case "$enabled" in
    true|false) ;;
    *) die "Tun 开关只允许 true 或 false" ;;
  esac

  write_tun_value "TUN_ENABLED" "$enabled"
}

tun_stack() {
  local value

  value="$(read_tun_value "TUN_STACK" 2>/dev/null || true)"
  case "${value:-system}" in
    system|gvisor|mixed)
      echo "${value:-system}"
      ;;
    *)
      echo "system"
      ;;
  esac
}

config_bool_env_value() {
  local key="$1"
  local default_value="$2"
  local value

  value="${!key:-}"
  [ -n "${value:-}" ] || value="$(read_env_value "$key" 2>/dev/null || true)"
  [ -n "${value:-}" ] || value="$default_value"

  case "$value" in
    true|1|yes|on)
      echo "true"
      ;;
    false|0|no|off)
      echo "false"
      ;;
    *)
      echo "$default_value"
      ;;
  esac
}

tun_auto_route() {
  config_bool_env_value "CLASH_TUN_AUTO_ROUTE" "true"
}

tun_auto_redirect_default() {
  if [ "$(get_os 2>/dev/null || echo unknown)" = "linux" ] \
    && [ "$(container_env_type 2>/dev/null || echo unknown)" = "host" ] \
    && [ "$(runtime_kernel_type 2>/dev/null || echo mihomo)" = "mihomo" ]; then
    echo "true"
    return 0
  fi

  echo "false"
}

tun_auto_redirect() {
  config_bool_env_value "CLASH_TUN_AUTO_REDIRECT" "$(tun_auto_redirect_default)"
}

tun_strict_route() {
  config_bool_env_value "CLASH_TUN_STRICT_ROUTE" "false"
}

tun_dns_hijack() {
  local value
  value="${CLASH_TUN_DNS_HIJACK:-}"
  [ -n "${value:-}" ] || value="$(read_env_value "CLASH_TUN_DNS_HIJACK" 2>/dev/null || true)"
  [ -n "${value:-}" ] || value="any:53,tcp://any:53"
  echo "$value"
}

ensure_config_files() {
  mkdir -p "$CONFIG_DIR" "$(config_tmp_dir)"

  [ -f "$CONFIG_DIR/template.yaml" ] || cat > "$CONFIG_DIR/template.yaml" <<'EOF'
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
external-controller: 0.0.0.0:9090
secret: ""

tun:
  enable: false
  stack: system
  auto-route: true
  auto-detect-interface: true
  auto-redirect: false
  strict-route: false
  dns-hijack:
    - any:53
    - tcp://any:53

dns:
  enable: true
  enhanced-mode: fake-ip
  listen: 0.0.0.0:1053

proxies: []
proxy-groups: []
rules: []
EOF

  [ -f "$CONFIG_DIR/mixin.yaml" ] || cat > "$CONFIG_DIR/mixin.yaml" <<'EOF'
override: {}
prepend:
  proxies: []
  proxy-groups: []
  rules: []
append:
  proxies: []
  proxy-groups: []
  rules: []
EOF

  [ -f "$CONFIG_DIR/profiles.yaml" ] || cat > "$CONFIG_DIR/profiles.yaml" <<'EOF'
active: default
profiles:
  default: {}
EOF
}

render_base_config() {
  local template_file="$CONFIG_DIR/template.yaml"
  local profiles_file="$CONFIG_DIR/profiles.yaml"
  local out_file="$1"
  local active_profile

  ensure_config_files
  active_profile="$(active_profile_name)"

  if [ -n "${active_profile:-}" ] && [ "$active_profile" != "null" ]; then
    TEMPLATE_FILE="$template_file" \
    PROFILES_FILE="$profiles_file" \
    ACTIVE_PROFILE="$active_profile" \
    "$(yq_bin)" eval-all --null-input '
      (
        load(strenv(TEMPLATE_FILE)) // {}
      ) * (
        (load(strenv(PROFILES_FILE)).profiles[strenv(ACTIVE_PROFILE)]) // {}
      )
    ' > "$out_file"
  else
    TEMPLATE_FILE="$template_file" \
    PROFILES_FILE="$profiles_file" \
    "$(yq_bin)" eval-all --null-input '
      (
        load(strenv(TEMPLATE_FILE)) // {}
      ) * (
        load(strenv(PROFILES_FILE)) // {}
      )
    ' > "$out_file"
  fi
}

subscription_url_scheme() {
  local url="$1"

  case "$url" in
    http://*)  echo "http" ;;
    https://*) echo "https" ;;
    file://*)  echo "file" ;;
    *)         echo "unknown" ;;
  esac
}

subscription_url_is_supported() {
  local url="$1"

  case "$(subscription_url_scheme "$url")" in
    http|https|file)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

subscription_file_path_from_url() {
  local url="$1"
  local path

  case "$url" in
    file://*)
      path="${url#file://}"
      ;;
    *)
      die "不是 file:// 订阅地址：$url"
      ;;
  esac

  [ -n "${path:-}" ] || die "file:// 订阅地址不能为空"

  echo "$path"
}

copy_local_subscription_yaml() {
  local url="$1"
  local out_file="$2"
  local _fetch_reason="${3:-auto}"
  local local_path

  local_path="$(subscription_file_path_from_url "$url")"

  [ -f "$local_path" ] || die "本地订阅文件不存在：$local_path"
  [ -r "$local_path" ] || die "本地订阅文件不可读：$local_path"

  info "正在读取本地订阅：$local_path"
  cp -f "$local_path" "$out_file"

  [ -s "$out_file" ] || die "本地订阅文件为空：$local_path"
}

local_subscription_share_links_to_subconverter_url() {
  local file="$1"

  awk '
    {
      gsub(/\r/, "")
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
    }
    $0 == "" || $0 ~ /^#/ { next }
    $0 ~ /^(vmess|vless|trojan|tuic):\/\// {
      if (out != "") {
        out = out "|"
      }
      out = out $0
    }
    END {
      if (out == "") {
        exit 1
      }
      print out
    }
  ' "$file"
}

decode_local_subscription_base64() {
  local src="$1"
  local out="$2"
  local compact len mod

  compact="$(mktemp)"
  rm -f "$compact" 2>/dev/null || true

  tr -d '\r\n\t ' < "$src" | tr '_-' '/+' > "$compact"
  [ -s "$compact" ] || {
    rm -f "$compact" 2>/dev/null || true
    return 1
  }

  if grep -Eq '[^A-Za-z0-9+/=]' "$compact"; then
    rm -f "$compact" 2>/dev/null || true
    return 1
  fi

  len="$(wc -c < "$compact" | tr -d '[:space:]')"
  case "$len" in
    ''|*[!0-9]*)
      rm -f "$compact" 2>/dev/null || true
      return 1
      ;;
  esac

  mod=$((len % 4))
  case "$mod" in
    0) ;;
    2) printf '==' >> "$compact" ;;
    3) printf '=' >> "$compact" ;;
    *)
      rm -f "$compact" 2>/dev/null || true
      return 1
      ;;
  esac

  if base64 --decode "$compact" > "$out" 2>/dev/null || base64 -d "$compact" > "$out" 2>/dev/null; then
    rm -f "$compact" 2>/dev/null || true
    [ -s "$out" ]
    return
  fi

  rm -f "$compact" 2>/dev/null || true
  return 1
}

local_subscription_convert_url_from_url() {
  local url="$1"
  local local_path decoded_file convert_url

  LOCAL_SUBSCRIPTION_CONVERT_URL=""
  local_path="$(subscription_file_path_from_url "$url")"

  [ -f "$local_path" ] || die "本地订阅文件不存在：$local_path"
  [ -r "$local_path" ] || die "本地订阅文件不可读：$local_path"
  [ -s "$local_path" ] || die "本地订阅文件为空：$local_path"

  if convert_url="$(local_subscription_share_links_to_subconverter_url "$local_path")"; then
    info "本地订阅识别为分享链接，将通过 subconverter 转换"
    LOCAL_SUBSCRIPTION_CONVERT_URL="$convert_url"
    return 0
  fi

  decoded_file="$(mktemp)"
  rm -f "$decoded_file" 2>/dev/null || true

  if decode_local_subscription_base64 "$local_path" "$decoded_file"; then
    if convert_url="$(local_subscription_share_links_to_subconverter_url "$decoded_file")"; then
      rm -f "$decoded_file" 2>/dev/null || true
      info "本地订阅识别为 Base64 分享链接，将通过 subconverter 转换"
      LOCAL_SUBSCRIPTION_CONVERT_URL="$convert_url"
      return 0
    fi

    rm -f "$decoded_file" 2>/dev/null || true
    die "本地订阅不是 Clash YAML，Base64 解码后未发现支持的分享链接：$local_path"
  fi

  rm -f "$decoded_file" 2>/dev/null || true
  die "本地订阅不是 Clash YAML，且无法识别为 Base64 或 vmess/vless/trojan/tuic 分享链接：$local_path"
}

download_subscription_yaml() {
  local url="$1"
  local out_file="$2"
  local fetch_reason="${3:-auto}"
  local scheme fmt

  [ -n "${url:-}" ] || return 1

  scheme="$(subscription_url_scheme "$url")"
  fmt="clash"

  case "$scheme" in
    http|https)
      if subscription_cache_restore "$url" "$fmt" "$out_file"; then
        return 0
      fi

      require_subscription_fetch_allowed "$fetch_reason" "$url"

      download_file \
        "$url" \
        "$out_file" \
        "subscription"

      subscription_cache_store "$url" "$fmt" "$out_file" "$url"
      ;;
    file)
      copy_local_subscription_yaml "$url" "$out_file" "$fetch_reason"
      ;;
    *)
      die "不支持的订阅协议：$url"
      ;;
  esac
}

subscription_cache_identity() {
  local url="$1"
  local fmt="${2:-clash}"
  printf '%s|%s' "$fmt" "$url"
}

subscription_cache_key() {
  local url="$1"
  local fmt="${2:-clash}"
  download_cache_key "$(subscription_cache_identity "$url" "$fmt")"
}

subscription_cache_file() {
  local url="$1"
  local fmt="${2:-clash}"
  echo "$(download_cache_dir)/$(subscription_cache_key "$url" "$fmt").bin"
}

subscription_cache_meta_file() {
  local url="$1"
  local fmt="${2:-clash}"
  echo "$(download_cache_dir)/$(subscription_cache_key "$url" "$fmt").meta"
}

subscription_cache_restore() {
  local url="$1"
  local fmt="${2:-clash}"
  local out="$3"
  local cache_file

  cache_file="$(subscription_cache_file "$url" "$fmt")"
  [ -s "$cache_file" ] || return 1

  mkdir -p "$(dirname "$out")"
  cp -f "$cache_file" "$out"
  return 0
}

subscription_cache_store() {
  local url="$1"
  local fmt="${2:-clash}"
  local src="$3"
  local source_url="${4:-}"
  local cache_file meta_file

  [ -s "$src" ] || return 0

  cache_file="$(subscription_cache_file "$url" "$fmt")"
  meta_file="$(subscription_cache_meta_file "$url" "$fmt")"

  mkdir -p "$(download_cache_dir)"
  cp -f "$src" "$cache_file"

  cat > "$meta_file" <<EOF
CACHE_URL="$url"
CACHE_FORMAT="$fmt"
CACHE_SOURCE_URL="$source_url"
CACHE_TIME="$(now_datetime)"
EOF
}

clear_subscription_cache() {
  local url="$1"
  local fmt="${2:-}"

  [ -n "${url:-}" ] || return 0

  if [ -n "${fmt:-}" ]; then
    rm -f "$(subscription_cache_file "$url" "$fmt")" 2>/dev/null || true
    rm -f "$(subscription_cache_meta_file "$url" "$fmt")" 2>/dev/null || true
    return 0
  fi

  rm -f "$(subscription_cache_file "$url" "clash")" 2>/dev/null || true
  rm -f "$(subscription_cache_meta_file "$url" "clash")" 2>/dev/null || true
  rm -f "$(subscription_cache_file "$url" "convert")" 2>/dev/null || true
  rm -f "$(subscription_cache_meta_file "$url" "convert")" 2>/dev/null || true
}

normalize_runtime_config() {
  local file="$1"
  local mixed_port controller tun_enable_value tun_stack_value dns_port_value controller_secret_value
  local tun_auto_route_value tun_auto_redirect_value tun_strict_route_value tun_dns_hijack_value
  local dashboard_dir_value
  local resolved_ports

  [ -s "$file" ] || die "待规范化的配置文件不存在：$file"

  resolved_ports="$(resolve_runtime_ports)"
  load_resolved_runtime_ports "$resolved_ports"

  mixed_port="$MIXED_PORT_RESOLVED"
  controller="$EXTERNAL_CONTROLLER_RESOLVED"
  tun_enable_value="$(tun_enabled)"
  tun_stack_value="$(tun_stack)"
  tun_auto_route_value="$(tun_auto_route)"
  tun_auto_redirect_value="$(tun_auto_redirect)"
  tun_strict_route_value="$(tun_strict_route)"
  tun_dns_hijack_value="$(tun_dns_hijack)"
  dns_port_value="$CLASH_DNS_PORT_RESOLVED"
  controller_secret_value="$(ensure_controller_secret)"
  dashboard_dir_value="$(runtime_dashboard_dir)"

  mixed_port="$mixed_port" \
  controller="$controller" \
  tun_enable_value="$tun_enable_value" \
  tun_stack_value="$tun_stack_value" \
  tun_auto_route_value="$tun_auto_route_value" \
  tun_auto_redirect_value="$tun_auto_redirect_value" \
  tun_strict_route_value="$tun_strict_route_value" \
  tun_dns_hijack_value="$tun_dns_hijack_value" \
  controller_secret_value="$controller_secret_value" \
  dashboard_dir_value="$dashboard_dir_value" \
  dns_listen_value="0.0.0.0:${dns_port_value}" \
  "$(yq_bin)" eval -i '
    .["mixed-port"] = (env(mixed_port) | tonumber) |
    .["external-controller"] = env(controller) |
    .secret = env(controller_secret_value) |
    .["external-ui"] = env(dashboard_dir_value) |
    .["external-ui-url"] = "/ui" |
    .["allow-lan"] = (.["allow-lan"] // true) |
    .mode = "rule" |
    .["log-level"] = (.["log-level"] // "info") |

    .tun.enable = (env(tun_enable_value) == "true") |
    .tun.stack = env(tun_stack_value) |
    .tun["auto-route"] = (env(tun_auto_route_value) == "true") |
    .tun["auto-detect-interface"] = (.tun["auto-detect-interface"] // true) |
    .tun["auto-redirect"] = (env(tun_auto_redirect_value) == "true") |
    .tun["strict-route"] = (env(tun_strict_route_value) == "true") |
    .tun["dns-hijack"] = (env(tun_dns_hijack_value) | split(",") | map(select(. != ""))) |

    .dns.enable = (.dns.enable // true) |
    .dns["enhanced-mode"] = (.dns["enhanced-mode"] // "fake-ip") |
    .dns.ipv6 = false |
    .dns.listen = env(dns_listen_value) |

    .proxies = (.proxies // []) |
    .["proxy-groups"] = (.["proxy-groups"] // []) |
    .rules = (.rules // [])
  ' "$file"
}

generate_secure_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8 2>/dev/null | head -n 1
    return 0
  fi

  head -c 8 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

is_valid_controller_secret() {
  local value="${1:-}"
  case "${value}" in
    ""|null|NULL|undefined|UNDEFINED|\"\"|\'\')
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

ensure_controller_secret() {
  local value

  value="${CLASH_CONTROLLER_SECRET:-}"
  if ! is_valid_controller_secret "$value"; then
    value="$(read_env_value "CLASH_CONTROLLER_SECRET" 2>/dev/null || true)"
  fi

  if ! is_valid_controller_secret "$value"; then
    value="$(generate_secure_secret)"
    [ -n "${value:-}" ] || die "无法生成控制器密钥"
    write_env_value "CLASH_CONTROLLER_SECRET" "$value"
  fi

  echo "$value"
}

clear_controller_secret() {
  unset_env_value "CLASH_CONTROLLER_SECRET" || true
  unset CLASH_CONTROLLER_SECRET || true
}

first_available_proxy_name() {
  local file="$1"

  [ -s "$file" ] || return 1

  "$(yq_bin)" eval '.proxies[0].name // ""' "$file" 2>/dev/null | head -n 1
}

group_type_requires_members() {
  case "$1" in
    select|url-test|fallback|load-balance)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

builtin_policy_name() {
  case "$1" in
    DIRECT|REJECT|REJECT-DROP|PASS)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

record_build_failure() {
  local mode="$1"
  local policy="$2"
  local active="$3"
  local selected="$4"
  local included="$5"
  local failed="$6"

  # active-only 元数据：只记录当前实际参与编译的 active 订阅集合
  # 为避免旧状态文件混淆，同时清空旧 key
  write_build_value "BUILD_ACTIVE_SOURCE" "$active"
  write_build_value "BUILD_ACTIVE_SOURCES" "$included"
  write_build_value "BUILD_FAILED_ACTIVE_SOURCES" "$failed"
  write_build_value "BUILD_SELECTED_SOURCES" ""
  write_build_value "BUILD_INCLUDED_SOURCES" ""
  write_build_value "BUILD_FAILED_SOURCES" ""
  write_build_value "BUILD_LAST_STATUS" "failed"
  write_build_value "BUILD_LAST_TIME" "$(now_datetime)"
}

record_build_success() {
  local mode="$1"
  local policy="$2"
  local active="$3"
  local selected="$4"
  local included="$5"
  local failed="$6"

  write_build_value "BUILD_ACTIVE_SOURCE" "$active"
  write_build_value "BUILD_ACTIVE_SOURCES" "$included"
  write_build_value "BUILD_FAILED_ACTIVE_SOURCES" "$failed"
  write_build_value "BUILD_SELECTED_SOURCES" ""
  write_build_value "BUILD_INCLUDED_SOURCES" ""
  write_build_value "BUILD_FAILED_SOURCES" ""
  write_build_value "BUILD_LAST_STATUS" "success"
  write_build_value "BUILD_LAST_TIME" "$(now_datetime)"
  clear_build_error_detail
  write_runtime_event_value "RUNTIME_LAST_BUILD_BLOCK_REASON" ""
  write_runtime_event_value "RUNTIME_LAST_BUILD_BLOCK_TIME" ""
  mark_runtime_build_applied "build-success"
}

fail_build_with_detail() {
  local stage="$1"
  local mode="$2"
  local policy="$3"
  local active="$4"
  local selected="$5"
  local included="$6"
  local failed="$7"
  local fallback_message="$8"
  local detail

  detail="$(read_compile_error 2>/dev/null || true)"
  [ -n "${detail:-}" ] || detail="$fallback_message"

  record_build_error_detail "$stage" "$detail"
  record_build_failure "$mode" "$policy" "$active" "$selected" "$included" "$failed"
  mark_runtime_build_not_applied "$stage"
  die "$detail"
}

health_key_prefix() {
  local name="$1"
  printf '%s' "$name" | tr '[:lower:]-.' '[:upper:]__'
}

read_subscription_health_value() {
  local name="$1"
  local field="$2"
  local file key prefix

  file="$(subscription_health_file)"
  [ -f "$file" ] || return 1

  prefix="$(health_key_prefix "$name")"
  key="SUB_HEALTH_${prefix}_${field}"

  sed -nE "s/^[[:space:]]*${key}=['\"]?([^'\"]*)['\"]?$/\1/p" "$file" | head -n 1
}

write_subscription_health_value() {
  local name="$1"
  local field="$2"
  local value="$3"
  local file key prefix

  file="$(subscription_health_file)"
  mkdir -p "$(dirname "$file")"
  touch "$file"

  prefix="$(health_key_prefix "$name")"
  key="SUB_HEALTH_${prefix}_${field}"

  if grep -qE "^[[:space:]]*${key}=" "$file"; then
    awk -v k="$key" -v v="$value" '
      $0 ~ "^[[:space:]]*" k "=" {
        print k "=\"" v "\""
        next
      }
      { print }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  else
    printf '%s="%s"\n' "$key" "$value" >> "$file"
  fi
}

clear_subscription_health_all_fields() {
  local name="$1"
  local fields field

  fields="STATUS LAST_SUCCESS LAST_FAILURE LAST_ERROR FAIL_COUNT AUTO_DISABLED AUTO_DISABLED_AT"

  for field in $fields; do
    write_subscription_health_value "$name" "$field" ""
  done
}

mark_subscription_health_success() {
  local name="$1"
  local now

  now="$(now_datetime)"

  write_subscription_health_value "$name" "STATUS" "success"
  write_subscription_health_value "$name" "LAST_SUCCESS" "$now"
  write_subscription_health_value "$name" "LAST_ERROR" ""
  write_subscription_health_value "$name" "FAIL_COUNT" "0"

  clear_subscription_auto_disabled_mark "$name"
}

mark_subscription_health_failure() {
  local name="$1"
  local reason="$2"
  local now fail_count

  now="$(now_datetime)"
  fail_count="$(read_subscription_health_value "$name" "FAIL_COUNT" 2>/dev/null || echo "0")"
  fail_count="${fail_count:-0}"

  case "$fail_count" in
    ''|*[!0-9]*)
      fail_count="0"
      ;;
  esac

  fail_count=$((fail_count + 1))

  write_subscription_health_value "$name" "STATUS" "failed"
  write_subscription_health_value "$name" "LAST_FAILURE" "$now"
  write_subscription_health_value "$name" "LAST_ERROR" "$reason"
  write_subscription_health_value "$name" "FAIL_COUNT" "$fail_count"

  maybe_auto_disable_subscription "$name"
}

print_subscription_health_summary() {
  local file name status fail_count last_success last_failure risk_marker active enabled_text found="false"

  file="$(subscriptions_file)"
  ensure_subscriptions_file
  active="$(active_subscription_name 2>/dev/null || true)"

  echo "  名称             启用状态   健康状态   失败次数   最近成功             最近失败"
  while IFS= read -r name; do
    [ -n "${name:-}" ] || continue
    found="true"

    status="$(read_subscription_health_value "$name" "STATUS" 2>/dev/null || echo "unknown")"
    fail_count="$(read_subscription_health_value "$name" "FAIL_COUNT" 2>/dev/null || echo "0")"
    last_success="$(read_subscription_health_value "$name" "LAST_SUCCESS" 2>/dev/null || true)"
    last_failure="$(read_subscription_health_value "$name" "LAST_FAILURE" 2>/dev/null || true)"

    if subscription_enabled "$name"; then
      enabled_text="enabled"
    else
      enabled_text="disabled"
    fi

    risk_marker=""
    if subscription_auto_disabled "$name"; then
      risk_marker="🚨"
    fi

    if [ "$name" = "$active" ]; then
      printf '  * %-16s %-9s %-8s fail=%-3s %-20s %-20s %s\n' \
        "$name" \
        "$enabled_text" \
        "$status" \
        "$fail_count" \
        "${last_success:--}" \
        "${last_failure:--}" \
        "$risk_marker"
    else
      printf '    %-16s %-9s %-8s fail=%-3s %-20s %-20s %s\n' \
        "$name" \
        "$enabled_text" \
        "$status" \
        "$fail_count" \
        "${last_success:--}" \
        "${last_failure:--}" \
        "$risk_marker"
    fi
  done < <("$(yq_bin)" eval '.sources | keys | .[]' "$file")

  [ "$found" = "true" ] || echo "  📭 暂无订阅健康数据"
}

print_subscription_health_one() {
  local name="$1"
  local status fail_count last_success last_failure last_error auto_disabled auto_disabled_at enabled_text type_text url_text

  [ -n "${name:-}" ] || die_usage "订阅名称不能为空" "clashctl health <订阅名称>"
  subscription_exists "$name" || die_missing "订阅 $name" "clashctl ls"

  status="$(read_subscription_health_value "$name" "STATUS" 2>/dev/null || echo "unknown")"
  fail_count="$(read_subscription_health_value "$name" "FAIL_COUNT" 2>/dev/null || echo "0")"
  last_success="$(read_subscription_health_value "$name" "LAST_SUCCESS" 2>/dev/null || true)"
  last_failure="$(read_subscription_health_value "$name" "LAST_FAILURE" 2>/dev/null || true)"
  last_error="$(read_subscription_health_value "$name" "LAST_ERROR" 2>/dev/null || true)"
  auto_disabled="$(read_subscription_health_value "$name" "AUTO_DISABLED" 2>/dev/null || true)"
  auto_disabled_at="$(read_subscription_health_value "$name" "AUTO_DISABLED_AT" 2>/dev/null || true)"

  if subscription_enabled "$name"; then
    enabled_text="enabled"
  else
    enabled_text="disabled"
  fi

  type_text="$(subscription_format_by_name "$name" 2>/dev/null || echo "clash")"
  url_text="$(subscription_url_by_name "$name" 2>/dev/null || true)"

  echo "📡 订阅名称：$name"
  echo "🔧 订阅类型：$type_text"
  echo "🐱 启用状态：$enabled_text"
  echo "❤️ 健康状态：${status:-unknown}"
  echo "🚨 失败次数：${fail_count:-0}"
  [ -n "${last_success:-}" ] && echo "🕒 最近成功：$last_success"
  [ -n "${last_failure:-}" ] && echo "🕒 最近失败：$last_failure"
  [ -n "${last_error:-}" ] && echo "❌ 最近错误：$last_error"
  [ -n "${auto_disabled:-}" ] && echo "🚨 风险标记：$auto_disabled"
  [ -n "${auto_disabled_at:-}" ] && echo "🕒 风险时间：$auto_disabled_at"
  [ -n "${url_text:-}" ] && echo "🔗 订阅地址：$url_text"
}

print_subscription_health_verbose() {
  local file active name enabled fmt url

  file="$(subscriptions_file)"
  ensure_subscriptions_file
  active="$(active_subscription_name 2>/dev/null || true)"

  while IFS= read -r name; do
    [ -n "${name:-}" ] || continue

    enabled="$("$(yq_bin)" eval ".sources.${name}.enabled // false" "$file" 2>/dev/null)"
    fmt="$("$(yq_bin)" eval ".sources.${name}.type // \"clash\"" "$file" 2>/dev/null)"
    url="$("$(yq_bin)" eval ".sources.${name}.url // \"\"" "$file" 2>/dev/null)"

    if [ "$name" = "$active" ]; then
      echo "* $name"
    else
      echo "  $name"
    fi

    echo "  enabled       : $enabled"
    echo "  type          : $fmt"
    echo "  health        : $(subscription_health_status "$name" 2>/dev/null || echo "unknown")"
    echo "  fail_count    : $(subscription_fail_count "$name" 2>/dev/null || echo "0")"
    echo "  auto_disabled : $(if subscription_auto_disabled "$name"; then echo true; else echo false; fi)"

    if [ -n "$(subscription_last_success "$name" 2>/dev/null || true)" ]; then
      echo "  last_success  : $(subscription_last_success "$name" 2>/dev/null || true)"
    fi

    if [ -n "$(subscription_last_failure "$name" 2>/dev/null || true)" ]; then
      echo "  last_failure  : $(subscription_last_failure "$name" 2>/dev/null || true)"
    fi

    if [ -n "$(subscription_last_error "$name" 2>/dev/null || true)" ]; then
      echo "  last_error    : $(subscription_last_error "$name" 2>/dev/null || true)"
    fi

    [ -n "${url:-}" ] && echo "  url           : $url"
    echo
  done < <("$(yq_bin)" eval '.sources | keys | .[]' "$file")
}

health_verbose_explanation_lines() {
  local file name total_count failed_count risky_count active active_health

  file="$(subscriptions_file)"
  ensure_subscriptions_file
  active="$(active_subscription_name 2>/dev/null || true)"
  active_health="$(subscription_health_status "$active" 2>/dev/null || echo "unknown")"

  total_count=0
  failed_count=0
  risky_count=0

  while IFS= read -r name; do
    [ -n "${name:-}" ] || continue
    total_count=$((total_count + 1))

    if [ "$(subscription_health_status "$name" 2>/dev/null || echo "unknown")" = "failed" ]; then
      failed_count=$((failed_count + 1))
    fi

    if subscription_auto_disabled "$name"; then
      risky_count=$((risky_count + 1))
    fi
  done < <("$(yq_bin)" eval '.sources | keys | .[]' "$file")

  if [ -n "${active:-}" ]; then
    if [ "${active_health:-unknown}" = "success" ]; then
      echo "- 当前主订阅健康正常"
    else
      echo "- 当前主订阅健康异常：${active_health:-unknown}"
    fi
  else
    echo "- 当前还没有主订阅"
  fi

  echo "- 当前共有 ${total_count} 个订阅"

  if [ "$failed_count" -gt 0 ]; then
    echo "- 发现 ${failed_count} 个失败订阅"
  else
    echo "- 当前没有失败订阅"
  fi

  if [ "$risky_count" -gt 0 ]; then
    echo "- 发现 ${risky_count} 个达到风险阈值的订阅"
  else
    echo "- 当前没有达到风险阈值的订阅"
  fi
}

subscription_auto_disable_threshold() {
  echo "${SUBSCRIPTION_AUTO_DISABLE_THRESHOLD:-3}"
}

subscription_is_auto_disable_enabled() {
  case "${SUBSCRIPTION_AUTO_DISABLE_ENABLED:-true}" in
    true|1|yes|on) return 0 ;;
    false|0|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

set_subscription_enabled() {
  local name="$1"
  local enabled="$2"
  local file

  file="$(subscriptions_file)"
  ensure_subscriptions_file
  subscription_exists "$name" || die_missing "订阅 $name" "clashctl ls"

  case "$enabled" in
    true|false) ;;
    *) die "enabled 只允许 true 或 false" ;;
  esac

  NAME="$name" ENABLED="$enabled" "$(yq_bin)" eval -i '
    .sources[env(NAME)].enabled = (env(ENABLED) == "true")
  ' "$file"
}

mark_subscription_auto_disabled() {
  local name="$1"
  local now="$2"

  write_subscription_health_value "$name" "AUTO_DISABLED" "true"
  write_subscription_health_value "$name" "AUTO_DISABLED_AT" "$now"
}

clear_subscription_auto_disabled_mark() {
  local name="$1"

  write_subscription_health_value "$name" "AUTO_DISABLED" ""
  write_subscription_health_value "$name" "AUTO_DISABLED_AT" ""

  if [ "$(read_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_NAME" 2>/dev/null || true)" = "$name" ]; then
    write_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_NAME" ""
    write_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_TIME" ""
    write_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_REASON" ""
    write_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_FAIL_COUNT" ""
    write_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_THRESHOLD" ""
  fi
}

maybe_auto_disable_subscription() {
  local name="$1"
  local fail_count threshold now

  subscription_is_auto_disable_enabled || return 0

  fail_count="$(read_subscription_health_value "$name" "FAIL_COUNT" 2>/dev/null || echo "0")"
  threshold="$(subscription_auto_disable_threshold)"

  case "$fail_count" in
    ''|*[!0-9]*) fail_count="0" ;;
  esac

  case "$threshold" in
    ''|*[!0-9]*) threshold="3" ;;
  esac

  [ "$threshold" -gt 0 ] || threshold="3"

  if [ "$fail_count" -lt "$threshold" ]; then
    return 0
  fi

  now="$(now_datetime)"

  # 只记录风险，不自动禁用
  write_subscription_health_value "$name" "AUTO_DISABLED" "threshold-reached"
  write_subscription_health_value "$name" "AUTO_DISABLED_AT" "$now"

  write_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_NAME" "$name"
  write_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_TIME" "$now"
  write_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_REASON" "fail-threshold-reached"
  write_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_FAIL_COUNT" "$fail_count"
  write_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_THRESHOLD" "$threshold"

  warn "订阅源连续失败达到阈值，但不会自动禁用：$name"
}

print_build_explain() {
  local active last_status last_time error_stage error_summary error_detail

  prepare

  active="$(active_subscription_name 2>/dev/null || true)"
  last_status="$(status_build_last_status 2>/dev/null || true)"
  last_time="$(status_build_last_time 2>/dev/null || true)"
  error_stage="$(status_build_last_error_stage 2>/dev/null || true)"
  error_summary="$(status_build_last_error_summary 2>/dev/null || true)"
  error_detail="$(status_build_last_error_detail 2>/dev/null || true)"

  ui_title "🧩 编译说明"
  echo "- 当前编译链只处理 active 主订阅"
  echo "- 当前主订阅：${active:-未设置}"

  case "${last_status:-unknown}" in
    success)
      echo "- 最近一次构建成功${last_time:+：${last_time}}"
      echo "- 处理顺序：下载 / 校验 / 必要时 convert / 运行校验 / 输出 runtime/config.yaml"
      ;;
    failed)
      echo "- 最近一次构建失败${last_time:+：${last_time}}"
      [ -n "${error_stage:-}" ] && echo "- 失败阶段：${error_stage}"
      [ -n "${error_summary:-}" ] && echo "- 失败摘要：${error_summary}"
      [ -n "${error_detail:-}" ] && echo
      [ -n "${error_detail:-}" ] && printf '%s\n' "$error_detail"
      ;;
    *)
      echo "- 当前还没有可解释的构建记录"
      ;;
  esac

  echo
  ui_next "clashctl status --verbose"
  ui_blank
}

build_active_sources_csv() {
  local value
  value="$(read_build_value "BUILD_ACTIVE_SOURCES" 2>/dev/null || true)"
  if [ -n "${value:-}" ]; then
    echo "$value"
    return 0
  fi

  # 兼容历史 build.env
  value="$(read_build_value "BUILD_INCLUDED_SOURCES" 2>/dev/null || true)"
  [ -n "${value:-}" ] && echo "$value"
}

build_failed_active_sources_csv() {
  local value
  value="$(read_build_value "BUILD_FAILED_ACTIVE_SOURCES" 2>/dev/null || true)"
  if [ -n "${value:-}" ]; then
    echo "$value"
    return 0
  fi

  # 兼容历史 build.env
  value="$(read_build_value "BUILD_FAILED_SOURCES" 2>/dev/null || true)"
  [ -n "${value:-}" ] && echo "$value"
}

build_last_status() {
  read_build_value "BUILD_LAST_STATUS" 2>/dev/null || true
}

build_last_time() {
  read_build_value "BUILD_LAST_TIME" 2>/dev/null || true
}

build_last_error_stage() {
  read_build_value "BUILD_LAST_ERROR_STAGE" 2>/dev/null || true
}

build_last_error_summary() {
  read_build_value "BUILD_LAST_ERROR_SUMMARY" 2>/dev/null || true
}

build_last_error_detail() {
  read_build_value "BUILD_LAST_ERROR_DETAIL" 2>/dev/null || true
}

build_success_explanation_lines() {
  local included_csv included_count

  included_csv="$(build_active_sources_csv)"
  included_count="$(csv_count "$included_csv")"

  echo "- active-only 编译链仅处理当前主订阅"
  echo "- 当前成功源数量：${included_count}"
}

build_failure_explanation_lines() {
  local included_csv included_count error_stage

  included_csv="$(build_active_sources_csv)"
  failed_csv="$(build_failed_active_sources_csv)"
  included_count="$(csv_count "$included_csv")"
  error_stage="$(build_last_error_stage)"

  echo "- active-only 编译链仅处理当前主订阅"
  if [ "$error_stage" = "resolve-active-source" ]; then
    echo "- 当前未找到可用的 active 主订阅"
  elif [ -n "${failed_csv:-}" ]; then
    echo "- 当前 active 主订阅拉取或校验失败"
  fi
  echo "- 当前成功源数量：${included_count}"
}

print_build_failed_source_lines() {
  local failed_csv name last_error

  failed_csv="$(build_failed_active_sources_csv)"
  [ -n "${failed_csv:-}" ] || return 0

  IFS=',' read -r -a _failed_names <<< "$failed_csv"
  for name in "${_failed_names[@]}"; do
    [ -n "${name:-}" ] || continue
    last_error="$(subscription_last_error "$name" 2>/dev/null || true)"
    if [ -n "${last_error:-}" ]; then
      echo "- ${name}：${last_error}"
    else
      echo "- ${name}：未知错误"
    fi
  done
}

build_explain_next_steps() {
  local last_status failed_csv

  last_status="$(build_last_status)"
  failed_csv="$(build_failed_active_sources_csv)"

  if [ "${last_status:-}" = "success" ]; then
    echo "👉 clashctl health"
    echo "👉 clashctl select"
    return 0
  fi

  if [ -n "${failed_csv:-}" ]; then
    echo "👉 clashctl health"
  fi

  echo "👉 clashctl doctor"
}

runtime_config_file() {
  echo "$RUNTIME_DIR/config.yaml"
}

runtime_last_good_config_file() {
  echo "$RUNTIME_DIR/config.last.yaml"
}

save_last_known_good_config() {
  local source_file="${1:-}"
  local last_file

  last_file="$(runtime_last_good_config_file)"

  if [ -z "${source_file:-}" ]; then
    source_file="$(runtime_config_file)"
  fi

  [ -s "$source_file" ] || return 0

  cp -f "$source_file" "$last_file"
}

restore_last_known_good_config() {
  local current_file last_file

  current_file="$(runtime_config_file)"
  last_file="$(runtime_last_good_config_file)"

  [ -s "$last_file" ] || return 1

  cp -f "$last_file" "$current_file"
}

mihomo_country_mmdb_file() {
  echo "$RUNTIME_DIR/Country.mmdb"
}

mihomo_country_mmdb_url() {
  local url

  url="${MIHOMO_MMDB_DOWNLOAD_URL:-}"
  [ -n "${url:-}" ] || url="${MIHOMO_MMDB_URL:-}"
  [ -n "${url:-}" ] || url="$(read_env_value "MIHOMO_MMDB_DOWNLOAD_URL" 2>/dev/null || true)"
  [ -n "${url:-}" ] || url="$(read_env_value "MIHOMO_MMDB_URL" 2>/dev/null || true)"
  [ -n "${url:-}" ] || url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb"

  echo "$url"
}

runtime_config_uses_geoip() {
  local config_file="$1"

  [ -s "$config_file" ] || return 1

  if [ -x "$(yq_bin 2>/dev/null || true)" ]; then
    if "$(yq_bin)" eval '(.rules // [])[] | tostring' "$config_file" 2>/dev/null \
      | grep -Eiq '^GEOIP(,|:|$)'; then
      return 0
    fi
  fi

  grep -Eiq "^[[:space:]]*-[[:space:]]*['\"]?GEOIP([,:\"']|[[:space:]]*$)" "$config_file"
}

copy_existing_country_mmdb() {
  local target="$1"
  local candidate

  for candidate in "$RUNTIME_DIR/country.mmdb"; do
    [ -s "$candidate" ] || continue
    mkdir -p "$(dirname "$target")"
    cp -f "$candidate" "$target"
    [ -s "$target" ] && return 0
  done

  [ -n "${RESOURCE_DIR:-}" ] || return 1

  for candidate in "$RESOURCE_DIR/geo/Country.mmdb" "$RESOURCE_DIR/geo/country.mmdb"; do
    [ -s "$candidate" ] || continue
    mkdir -p "$(dirname "$target")"
    cp -f "$candidate" "$target"
    [ -s "$target" ] && return 0
  done

  return 1
}

ensure_mihomo_geodata_ready() {
  local config_file="${1:-$RUNTIME_DIR/config.yaml}"
  local target url tmp_file

  [ "$(runtime_kernel_type)" = "mihomo" ] || return 0
  runtime_config_uses_geoip "$config_file" || return 0

  # Mihomo resolves Country.mmdb under the home directory passed by -d.
  target="$(mihomo_country_mmdb_file)"
  [ -s "$target" ] && return 0

  if copy_existing_country_mmdb "$target"; then
    success "Country.mmdb 已准备：$target"
    return 0
  fi

  url="$(mihomo_country_mmdb_url)"

  if download_cache_restore "$url" "$target"; then
    success "Country.mmdb 已从缓存准备：$target"
    return 0
  fi

  tmp_file="$(mktemp)"
  rm -f "$tmp_file" 2>/dev/null || true

  info "当前配置使用 GEOIP，正在准备 Country.mmdb：$target"
  if ! ( download_file "$url" "$tmp_file" "Country.mmdb（GEOIP 依赖，可在 .env 中设置 MIHOMO_MMDB_URL / MIHOMO_MMDB_DOWNLOAD_URL）" ); then
    rm -f "$tmp_file" 2>/dev/null || true
    error "GEOIP 依赖未就绪：缺少 Country.mmdb，且 MMDB 下载失败"
    error "当前配置无法启动：$config_file"
    return 1
  fi

  if [ ! -s "$tmp_file" ]; then
    rm -f "$tmp_file" 2>/dev/null || true
    error "GEOIP 依赖未就绪：Country.mmdb 下载结果为空"
    error "当前配置无法启动：$config_file"
    return 1
  fi

  mkdir -p "$(dirname "$target")"
  mv -f "$tmp_file" "$target"
  success "Country.mmdb 已准备：$target"
}

test_runtime_config() {
  local config_file="${1:-$RUNTIME_DIR/config.yaml}"

  [ -s "$config_file" ] || die "配置文件不存在：$config_file"

  ensure_mihomo_geodata_ready "$config_file" || return 1

  if ! "$(runtime_kernel_bin)" -t -f "$config_file" -d "$RUNTIME_DIR" >/dev/null; then
    return 1
  fi

  success "配置校验通过"
}

list_profiles() {
  local profiles_file="$CONFIG_DIR/profiles.yaml"

  ensure_config_files

  "$(yq_bin)" eval '.profiles | keys | .[]' "$profiles_file" 2>/dev/null
}

profile_exists() {
  local profile_name="$1"
  local profiles_file="$CONFIG_DIR/profiles.yaml"

  ensure_config_files

  [ -n "${profile_name:-}" ] || return 1

  [ "$(
    "$(yq_bin)" eval ".profiles | has(\"$profile_name\")" "$profiles_file" 2>/dev/null
  )" = "true" ]
}

set_active_profile() {
  local profile_name="$1"
  local profiles_file="$CONFIG_DIR/profiles.yaml"

  [ -n "${profile_name:-}" ] || die "Profile 名称不能为空"

  ensure_config_files

  profile_exists "$profile_name" || die "Profile 不存在：$profile_name"

  PROFILE_NAME="$profile_name" "$(yq_bin)" eval -i '
    .active = env(PROFILE_NAME)
  ' "$profiles_file"

  success "当前 Profile 已切换为：$profile_name"
}

show_active_profile() {
  local name
  name="$(active_profile_name)"

  if [ -n "${name:-}" ] && [ "$name" != "null" ]; then
    echo "$name"
  else
    echo "default"
  fi
}

print_profile_list() {
  local active name found="false"

  active="$(show_active_profile)"

  while IFS= read -r name; do
    [ -n "${name:-}" ] || continue
    found="true"
    if [ "$name" = "$active" ]; then
      echo "* $name"
    else
      echo "  $name"
    fi
  done < <(list_profiles)

  [ "$found" = "true" ] || echo "未找到任何 Profile"
}

subscription_url() {
  local file active
  file="$(subscriptions_file)"
  ensure_subscriptions_file

  active="$(active_subscription_name)"
  "$(yq_bin)" eval ".sources.${active}.url // \"\"" "$file" 2>/dev/null | head -n 1
}

subscription_format() {
  local file active
  file="$(subscriptions_file)"
  ensure_subscriptions_file

  active="$(active_subscription_name)"
  "$(yq_bin)" eval ".sources.${active}.type // \"clash\"" "$file" 2>/dev/null | head -n 1
}

subscription_exists() {
  local name="$1"
  local file
  file="$(subscriptions_file)"
  ensure_subscriptions_file

  [ "$("$(yq_bin)" eval ".sources | has(\"$name\")" "$file" 2>/dev/null)" = "true" ]
}

subscription_enabled() {
  local name="$1"
  local file
  file="$(subscriptions_file)"
  ensure_subscriptions_file

  [ "$("$(yq_bin)" eval ".sources.${name}.enabled // false" "$file" 2>/dev/null)" = "true" ]
}

subscription_auto_disabled() {
  local name="$1"
  local value

  value="$(read_subscription_health_value "$name" "AUTO_DISABLED" 2>/dev/null || true)"
  [ "${value:-}" = "true" ]
}

subscription_fail_count() {
  local name="$1"
  read_subscription_health_value "$name" "FAIL_COUNT" 2>/dev/null || echo "0"
}

subscription_last_error() {
  local name="$1"
  read_subscription_health_value "$name" "LAST_ERROR" 2>/dev/null || true
}

subscription_last_success() {
  local name="$1"
  read_subscription_health_value "$name" "LAST_SUCCESS" 2>/dev/null || true
}

subscription_last_failure() {
  local name="$1"
  read_subscription_health_value "$name" "LAST_FAILURE" 2>/dev/null || true
}

subscription_health_status() {
  local name="$1"
  read_subscription_health_value "$name" "STATUS" 2>/dev/null || echo "unknown"
}

subscription_url_by_name() {
  local name="$1"
  local file
  file="$(subscriptions_file)"
  ensure_subscriptions_file

  "$(yq_bin)" eval ".sources.${name}.url // \"\"" "$file" 2>/dev/null | head -n 1
}

subscription_format_by_name() {
  local name="$1"
  local file
  file="$(subscriptions_file)"
  ensure_subscriptions_file

  "$(yq_bin)" eval ".sources.${name}.type // \"clash\"" "$file" 2>/dev/null | head -n 1
}

is_valid_port_number() {
  local port="$1"

  printf '%s' "$port" | grep -Eq '^[0-9]+$' || return 1
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

csv_has_value() {
  local csv="$1"
  local value="$2"

  [ -n "${csv:-}" ] || return 1
  printf ',%s,\n' "$csv" | grep -Fq ",$value,"
}

csv_append_value() {
  local csv="$1"
  local value="$2"

  [ -n "${value:-}" ] || {
    echo "$csv"
    return 0
  }

  if csv_has_value "$csv" "$value"; then
    echo "$csv"
    return 0
  fi

  if [ -n "${csv:-}" ]; then
    echo "${csv},${value}"
  else
    echo "$value"
  fi
}

current_runtime_mixed_port() {
  local file="${1:-$RUNTIME_DIR/config.yaml}"
  local port

  [ -s "$file" ] || return 1
  port="$("$(yq_bin)" eval '.["mixed-port"] // .port // ""' "$file" 2>/dev/null | head -n 1)"
  is_valid_port_number "$port" || return 1
  echo "$port"
}

current_runtime_controller_port() {
  local file="${1:-$RUNTIME_DIR/config.yaml}"
  local addr
  local port

  [ -s "$file" ] || return 1
  addr="$("$(yq_bin)" eval '.["external-controller"] // ""' "$file" 2>/dev/null | head -n 1)"
  [ -n "${addr:-}" ] || return 1
  [ "$addr" != "null" ] || return 1

  port="${addr##*:}"
  is_valid_port_number "$port" || return 1
  echo "$port"
}

current_runtime_dns_port() {
  local file="${1:-$RUNTIME_DIR/config.yaml}"
  local listen
  local port

  [ -s "$file" ] || return 1
  listen="$("$(yq_bin)" eval '.dns.listen // ""' "$file" 2>/dev/null | head -n 1)"
  [ -n "${listen:-}" ] || return 1
  [ "$listen" != "null" ] || return 1

  port="${listen##*:}"
  is_valid_port_number "$port" || return 1
  echo "$port"
}

port_reserved_by_current_runtime() {
  local port="$1"
  local current_port

  for current_port in \
    "$(current_runtime_mixed_port 2>/dev/null || true)" \
    "$(current_runtime_controller_port 2>/dev/null || true)" \
    "$(current_runtime_dns_port 2>/dev/null || true)"; do
    [ -n "${current_port:-}" ] || continue
    [ "$port" = "$current_port" ] && return 0
  done

  return 1
}

port_available_for_runtime() {
  local port="$1"
  local excludes_csv="${2:-}"

  is_valid_port_number "$port" || return 1

  if csv_has_value "$excludes_csv" "$port"; then
    return 1
  fi

  if port_reserved_by_current_runtime "$port"; then
    return 0
  fi

  if is_port_in_use "$port"; then
    return 1
  fi

  return 0
}

resolve_free_port_excluding() {
  local start="${1:-7890}"
  local end="${2:-7999}"
  local excludes_csv="${3:-}"
  local p

  for p in $(seq "$start" "$end"); do
    if port_available_for_runtime "$p" "$excludes_csv"; then
      echo "$p"
      return 0
    fi
  done

  die "指定端口范围内没有可用端口：${start}-${end}"
}

resolve_runtime_port() {
  local preferred="$1"
  local start="$2"
  local end="$3"
  local excludes_csv="${4:-}"
  local label="${5:-端口}"
  local resolved

  if port_available_for_runtime "$preferred" "$excludes_csv"; then
    echo "$preferred"
    return 0
  fi

  resolved="$(resolve_free_port_excluding "$start" "$end" "$excludes_csv")"

  echo "$resolved"
}

parse_controller_host() {
  local controller="$1"

  [ -n "${controller:-}" ] || die "external-controller 不能为空"
  printf '%s' "$controller" | grep -q ':' || die "external-controller 格式不合法：$controller"

  echo "${controller%:*}"
}

parse_controller_port() {
  local controller="$1"
  local port

  [ -n "${controller:-}" ] || die "external-controller 不能为空"
  printf '%s' "$controller" | grep -q ':' || die "external-controller 格式不合法：$controller"

  port="${controller##*:}"
  is_valid_port_number "$port" || die "external-controller 端口不合法：$controller"

  echo "$port"
}

is_clean_controller_addr() {
  local controller="$1"
  local port

  [ -n "${controller:-}" ] || return 1
  [ "$controller" != "null" ] || return 1
  printf '%s' "$controller" | grep -Eq '^[^[:space:][:cntrl:]]+:[0-9]+$' || return 1

  port="${controller##*:}"
  is_valid_port_number "$port"
}

load_resolved_runtime_ports() {
  local resolved="$1"
  local unexpected_lines
  local mixed controller dns

  unexpected_lines="$(
    printf '%s\n' "$resolved" \
      | grep -Ev '^(MIXED_PORT_RESOLVED=[0-9]+|EXTERNAL_CONTROLLER_RESOLVED=[^[:space:][:cntrl:]]+:[0-9]+|CLASH_DNS_PORT_RESOLVED=[0-9]+)$' \
      | grep -v '^$' || true
  )"
  [ -z "${unexpected_lines:-}" ] || die "runtime port resolution output is polluted"

  mixed="$(printf '%s\n' "$resolved" | sed -n 's/^MIXED_PORT_RESOLVED=//p' | head -n 1)"
  controller="$(printf '%s\n' "$resolved" | sed -n 's/^EXTERNAL_CONTROLLER_RESOLVED=//p' | head -n 1)"
  dns="$(printf '%s\n' "$resolved" | sed -n 's/^CLASH_DNS_PORT_RESOLVED=//p' | head -n 1)"

  is_valid_port_number "$mixed" || die "invalid MIXED_PORT_RESOLVED: $mixed"
  is_clean_controller_addr "$controller" || die "invalid EXTERNAL_CONTROLLER_RESOLVED: $controller"
  is_valid_port_number "$dns" || die "invalid CLASH_DNS_PORT_RESOLVED: $dns"

  MIXED_PORT_RESOLVED="$mixed"
  EXTERNAL_CONTROLLER_RESOLVED="$controller"
  CLASH_DNS_PORT_RESOLVED="$dns"
}

resolve_runtime_ports() {
  local preferred_mixed preferred_controller preferred_dns
  local controller_host preferred_controller_port
  local mixed_port controller_port dns_port
  local used_ports=""

  preferred_mixed="${MIXED_PORT:-7890}"
  preferred_controller="${EXTERNAL_CONTROLLER:-0.0.0.0:9090}"
  preferred_dns="${CLASH_DNS_PORT:-1053}"

  is_valid_port_number "$preferred_mixed" || die "MIXED_PORT 不合法：$preferred_mixed"
  is_valid_port_number "$preferred_dns" || die "CLASH_DNS_PORT 不合法：$preferred_dns"

  controller_host="$(parse_controller_host "$preferred_controller")"
  preferred_controller_port="$(parse_controller_port "$preferred_controller")"

  mixed_port="$(resolve_runtime_port "$preferred_mixed" 7890 7999 "$used_ports" "mixed-port")"
  is_valid_port_number "$mixed_port" || die "invalid mixed-port resolution: $mixed_port"
  used_ports="$(csv_append_value "$used_ports" "$mixed_port")"

  controller_port="$(resolve_runtime_port "$preferred_controller_port" 9090 9199 "$used_ports" "external-controller")"
  is_valid_port_number "$controller_port" || die "invalid external-controller resolution: $controller_port"
  used_ports="$(csv_append_value "$used_ports" "$controller_port")"

  dns_port="$(resolve_runtime_port "$preferred_dns" 1053 1199 "$used_ports" "dns.listen")"
  is_valid_port_number "$dns_port" || die "invalid dns.listen resolution: $dns_port"
  used_ports="$(csv_append_value "$used_ports" "$dns_port")"

  printf 'MIXED_PORT_RESOLVED=%s\n' "$mixed_port"
  printf 'EXTERNAL_CONTROLLER_RESOLVED=%s:%s\n' "$controller_host" "$controller_port"
  printf 'CLASH_DNS_PORT_RESOLVED=%s\n' "$dns_port"
}

mark_install_port_plan() {
  local resolved
  local preferred_mixed preferred_controller preferred_dns
  local changed_mixed changed_controller changed_dns

  resolved="$(resolve_runtime_ports)"
  load_resolved_runtime_ports "$resolved"

  preferred_mixed="${MIXED_PORT:-7890}"
  preferred_controller="${EXTERNAL_CONTROLLER:-0.0.0.0:9090}"
  preferred_dns="${CLASH_DNS_PORT:-1053}"

  if [ "$MIXED_PORT_RESOLVED" = "$preferred_mixed" ]; then
    changed_mixed="false"
  else
    changed_mixed="true"
  fi

  if [ "$EXTERNAL_CONTROLLER_RESOLVED" = "$preferred_controller" ]; then
    changed_controller="false"
  else
    changed_controller="true"
  fi

  if [ "$CLASH_DNS_PORT_RESOLVED" = "$preferred_dns" ]; then
    changed_dns="false"
  else
    changed_dns="true"
  fi

  if [ "$changed_mixed" = "true" ]; then
    ui_target "端口冲突：[mixed-port] ${preferred_mixed} 🎲 随机分配：${MIXED_PORT_RESOLVED}"
  fi

  if [ "$changed_controller" = "true" ]; then
    ui_target "端口冲突：[external-controller] ${preferred_controller} 🎲 随机分配：${EXTERNAL_CONTROLLER_RESOLVED}"
  fi

  if [ "$changed_dns" = "true" ]; then
    ui_target "端口冲突：[dns.listen] ${preferred_dns} 🎲 随机分配：${CLASH_DNS_PORT_RESOLVED}"
  fi

  write_runtime_value "INSTALL_PLAN_MIXED_PORT" "$MIXED_PORT_RESOLVED"
  write_runtime_value "INSTALL_PLAN_CONTROLLER" "$EXTERNAL_CONTROLLER_RESOLVED"
  write_runtime_value "INSTALL_PLAN_DNS_PORT" "$CLASH_DNS_PORT_RESOLVED"

  write_runtime_value "INSTALL_PLAN_MIXED_PORT_AUTO_CHANGED" "$changed_mixed"
  write_runtime_value "INSTALL_PLAN_CONTROLLER_AUTO_CHANGED" "$changed_controller"
  write_runtime_value "INSTALL_PLAN_DNS_PORT_AUTO_CHANGED" "$changed_dns"
}

mixin_file() {
  echo "$CONFIG_DIR/mixin.yaml"
}

ensure_mixin_file() {
  ensure_config_files
}

apply_mixin_override() {
  local runtime_file="$1"
  local mixin_file_path
  mixin_file_path="$(mixin_file)"

  [ -s "$runtime_file" ] || die "运行配置不存在：$runtime_file"
  [ -f "$mixin_file_path" ] || return 0

  RUNTIME_FILE="$runtime_file" MIXIN_FILE="$mixin_file_path" "$(yq_bin)" eval-all -i '
    select(fileIndex == 0)
    * ((select(fileIndex == 1).override // {}))
  ' "$runtime_file" "$mixin_file_path"
}

apply_mixin_prepend_arrays() {
  local runtime_file="$1"
  local mixin_file_path
  mixin_file_path="$(mixin_file)"

  [ -s "$runtime_file" ] || die "运行配置不存在：$runtime_file"
  [ -f "$mixin_file_path" ] || return 0

  RUNTIME_FILE="$runtime_file" MIXIN_FILE="$mixin_file_path" "$(yq_bin)" eval-all -i '
    select(fileIndex == 0)
    | .proxies = (((select(fileIndex == 1).prepend.proxies // []) + (.proxies // [])) | unique_by(.name))
    | .["proxy-groups"] = (((select(fileIndex == 1).prepend["proxy-groups"] // []) + (.["proxy-groups"] // [])) | unique_by(.name))
    | .rules = (((select(fileIndex == 1).prepend.rules // []) + (.rules // [])) | unique)
  ' "$runtime_file" "$mixin_file_path"
}

apply_mixin_append_arrays() {
  local runtime_file="$1"
  local mixin_file_path
  mixin_file_path="$(mixin_file)"

  [ -s "$runtime_file" ] || die "运行配置不存在：$runtime_file"
  [ -f "$mixin_file_path" ] || return 0

  RUNTIME_FILE="$runtime_file" MIXIN_FILE="$mixin_file_path" "$(yq_bin)" eval-all -i '
    select(fileIndex == 0)
    | .proxies = (((.proxies // []) + (select(fileIndex == 1).append.proxies // [])) | unique_by(.name))
    | .["proxy-groups"] = (((.["proxy-groups"] // []) + (select(fileIndex == 1).append["proxy-groups"] // [])) | unique_by(.name))
    | .rules = (((.rules // []) + (select(fileIndex == 1).append.rules // [])) | unique)
  ' "$runtime_file" "$mixin_file_path"
}

apply_runtime_mixin() {
  local runtime_file="$1"

  [ -s "$runtime_file" ] || die "待应用 mixin 的配置文件不存在：$runtime_file"

  ensure_mixin_file

  build_debug "mixin: override"
  apply_mixin_override "$runtime_file"

  build_debug "mixin: prepend"
  apply_mixin_prepend_arrays "$runtime_file"

  build_debug "mixin: append"
  apply_mixin_append_arrays "$runtime_file"
}

show_subscription() {
  local url fmt

  url="$(subscription_url 2>/dev/null || true)"
  fmt="$(subscription_format)"

  if [ -n "${url:-}" ]; then
    echo "订阅地址：$url"
  else
    echo "订阅地址：未设置"
  fi

  echo "订阅格式：$fmt"
}

bootstrap_subscription_from_install_input() {
  local url="$1"
  local fmt="${2:-}"
  local name="${3:-default}"
  local file

  [ -n "${url:-}" ] || return 1

  subscription_url_is_supported "$url" || die "订阅地址格式不合法"
  [ -n "${fmt:-}" ] || fmt="$(detect_subscription_format "$url")"

  case "$fmt" in
    clash|convert) ;;
    *) die "不支持的订阅格式：$fmt" ;;
  esac

  if [ "$fmt" = "convert" ] && [ "$(subscription_url_scheme "$url")" = "file" ]; then
    die "convert 格式暂不支持 file:// 本地订阅，请改用 clash 格式"
  fi

  file="$(subscriptions_file)"
  ensure_subscriptions_file

  NAME="$name" URL="$url" TYPE="$fmt" \
  "$(yq_bin)" eval -i '
    .sources[env(NAME)] = {
      "type": env(TYPE),
      "url": env(URL),
      "enabled": true
    } |
    .active = env(NAME)
  ' "$file"
}

subscriptions_has_any_usable_source() {
  local file count

  file="$(subscriptions_file)"
  ensure_subscriptions_file

  count="$("$(yq_bin)" eval '.sources | keys | length' "$file" 2>/dev/null || echo 0)"
  case "$count" in
    ''|*[!0-9]*) count=0 ;;
  esac

  [ "$count" -gt 0 ]
}

subscription_name_exists() {
  local name="$1"
  local file exists

  [ -n "${name:-}" ] || return 1

  file="$(subscriptions_file)"
  ensure_subscriptions_file

  exists="$("$(yq_bin)" eval ".sources | has(\"$name\")" "$file" 2>/dev/null || echo false)"
  [ "$exists" = "true" ]
}

subscription_name_has_url() {
  local name="$1"
  local file url

  [ -n "${name:-}" ] || return 1

  file="$(subscriptions_file)"
  ensure_subscriptions_file

  url="$("$(yq_bin)" eval ".sources.\"$name\".url // \"\"" "$file" 2>/dev/null | head -n 1)"
  [ -n "${url:-}" ]
}

ensure_subscription_bootstrap_for_install() {
  local env_url active_name input_fmt current_url current_fmt

  env_url="${CLASH_SUBSCRIPTION_URL:-}"
  active_name="${1:-default}"

  ensure_subscriptions_file

  # Only initialize from .env when there is no subscription yet.
  if subscriptions_has_any_usable_source; then
    current_url="$(subscription_url_by_name "$active_name" 2>/dev/null || true)"
    current_fmt="$(subscription_format_by_name "$active_name" 2>/dev/null || true)"

    if [ -n "${current_url:-}" ]; then
      input_fmt="$(detect_subscription_format "$current_url")"
      if [ "$current_fmt" = "convert" ] && [ "$input_fmt" = "clash" ]; then
        info "安装订阅格式判定：$active_name -> $input_fmt"
        bootstrap_subscription_from_install_input "$current_url" "$input_fmt" "$active_name"
      fi

      return 0
    fi

    if [ -n "${env_url:-}" ]; then
      input_fmt="$(detect_subscription_format "$env_url")"
      info "安装订阅格式判定：$active_name -> $input_fmt"
      bootstrap_subscription_from_install_input "$env_url" "$input_fmt" "$active_name"
    fi

    return 0
  fi

  [ -n "${env_url:-}" ] || return 0

  input_fmt="$(detect_subscription_format "$env_url")"
  info "安装订阅格式判定：$active_name -> $input_fmt"
  bootstrap_subscription_from_install_input "$env_url" "$input_fmt" "$active_name"
}

set_subscription() {
  local url="$1"
  local fmt="${2:-}"
  local name="${3:-default}"
  local file

  [ -n "$url" ] || die "订阅地址不能为空"

  subscription_url_is_supported "$url" || die "订阅地址格式不合法"
  [ -n "${fmt:-}" ] || fmt="$(detect_subscription_format "$url")"

  case "$fmt" in
    clash|convert) ;;
    *) die "不支持的订阅格式：$fmt" ;;
  esac

  if [ "$fmt" = "convert" ] && [ "$(subscription_url_scheme "$url")" = "file" ]; then
    die "convert 格式暂不支持 file:// 本地订阅，请改用 clash 格式"
  fi

  file="$(subscriptions_file)"
  ensure_subscriptions_file

  NAME="$name" URL="$url" TYPE="$fmt" \
  "$(yq_bin)" eval -i '
    .sources[env(NAME)] = {
      "type": env(TYPE),
      "url": env(URL),
      "enabled": true
    }
  ' "$file"

  regenerate_config
}

set_active_subscription() {
  local name="$1"
  local file

  file="$(subscriptions_file)"
  ensure_subscriptions_file

  exists="$("$(yq_bin)" eval ".sources | has(\"$name\")" "$file")"

  [ "$exists" = "true" ] || die_missing "订阅 $name" "clashctl ls"

  NAME="$name" "$(yq_bin)" eval -i '
    .active = env(NAME)
  ' "$file"

  regenerate_config
}

remove_subscription() {
  local name="$1"
  local file active fallback

  file="$(subscriptions_file)"
  ensure_subscriptions_file

  [ -n "${name:-}" ] || die_usage "订阅名称不能为空" "clashctl health <订阅名称>"
  subscription_exists "$name" || die_missing "订阅 $name" "clashctl ls"

  if [ "$name" = "default" ]; then
    die "默认订阅不允许删除：default"
  fi

  active="$(active_subscription_name)"

  NAME="$name" "$(yq_bin)" eval -i '
    del(.sources[env(NAME)])
  ' "$file"

  if [ "$active" = "$name" ]; then
    if subscription_exists "default"; then
      fallback="default"
    else
      fallback="$(first_subscription_name)"
    fi

    if [ -n "${fallback:-}" ]; then
      NAME="$fallback" "$(yq_bin)" eval -i '.active = env(NAME)' "$file"
    fi
  fi

  clear_subscription_health_all_fields "$name"
  success "订阅已删除：$name"
}

rename_subscription() {
  local old_name="$1"
  local new_name="$2"
  local file active
  local old_prefix new_prefix fields value

  file="$(subscriptions_file)"
  ensure_subscriptions_file

  [ -n "${old_name:-}" ] || die "原订阅名称不能为空"
  [ -n "${new_name:-}" ] || die "新订阅名称不能为空"

  subscription_exists "$old_name" || die_missing "订阅 $old_name" "clashctl ls"
  subscription_exists "$new_name" && die_state "目标订阅已存在：$new_name" "clashctl ls"

  case "$new_name" in
    *[!A-Za-z0-9._-]*)
      die "订阅名称只允许字母、数字、点、下划线、中划线"
      ;;
  esac

  OLD_NAME="$old_name" NEW_NAME="$new_name" "$(yq_bin)" eval -i '
    .sources[env(NEW_NAME)] = .sources[env(OLD_NAME)] |
    del(.sources[env(OLD_NAME)]) |
    .active = (if .active == env(OLD_NAME) then env(NEW_NAME) else .active end)
  ' "$file"

  old_prefix="$(health_key_prefix "$old_name")"
  new_prefix="$(health_key_prefix "$new_name")"

  fields="STATUS LAST_SUCCESS LAST_FAILURE LAST_ERROR FAIL_COUNT AUTO_DISABLED AUTO_DISABLED_AT"

  for field in $fields; do
    value="$(read_subscription_health_value "$old_name" "$field" 2>/dev/null || true)"
    if [ -n "${value:-}" ]; then
      write_subscription_health_value "$new_name" "$field" "$value"
      write_subscription_health_value "$old_name" "$field" ""
    fi
  done

  success "订阅已重命名：$old_name -> $new_name"
}

active_subscription_enabled() {
  local active
  active="$(active_subscription_name)"
  subscription_exists "$active" && subscription_enabled "$active"
}

first_enabled_subscription_name() {
  local file name

  file="$(subscriptions_file)"
  ensure_subscriptions_file

  while IFS= read -r name; do
    [ -n "${name:-}" ] || continue
    if subscription_enabled "$name"; then
      echo "$name"
      return 0
    fi
  done < <("$(yq_bin)" eval '.sources | keys | .[]' "$file")

  return 1
}

subscription_health_rank() {
  local name="$1"
  local status

  status="$(subscription_health_status "$name" 2>/dev/null || echo "unknown")"

  case "$status" in
    success) echo "0" ;;
    unknown) echo "1" ;;
    failed)  echo "2" ;;
    *)       echo "3" ;;
  esac
}

subscription_risk_rank() {
  local name="$1"

  if subscription_auto_disabled "$name"; then
    echo "1"
  else
    echo "0"
  fi
}

recommended_subscription_name() {
  local active name
  local best_name=""
  local best_health_rank="" best_risk_rank="" best_fail=""
  local health_rank risk_rank fail_count

  active="$(active_subscription_name 2>/dev/null || true)"

  while IFS= read -r name; do
    [ -n "${name:-}" ] || continue

    subscription_enabled "$name" || continue
    [ "$name" = "$active" ] && continue

    health_rank="$(subscription_health_rank "$name" 2>/dev/null || echo "9")"
    risk_rank="$(subscription_risk_rank "$name" 2>/dev/null || echo "9")"
    fail_count="$(subscription_fail_count "$name" 2>/dev/null || echo "999")"

    case "$health_rank" in
      ''|*[!0-9]*) health_rank="9" ;;
    esac

    case "$risk_rank" in
      ''|*[!0-9]*) risk_rank="9" ;;
    esac

    case "$fail_count" in
      ''|*[!0-9]*) fail_count="999" ;;
    esac

    if [ -z "${best_name:-}" ]; then
      best_name="$name"
      best_health_rank="$health_rank"
      best_risk_rank="$risk_rank"
      best_fail="$fail_count"
      continue
    fi

    if [ "$health_rank" -lt "$best_health_rank" ]; then
      best_name="$name"
      best_health_rank="$health_rank"
      best_risk_rank="$risk_rank"
      best_fail="$fail_count"
      continue
    fi

    if [ "$health_rank" -gt "$best_health_rank" ]; then
      continue
    fi

    if [ "$risk_rank" -lt "$best_risk_rank" ]; then
      best_name="$name"
      best_health_rank="$health_rank"
      best_risk_rank="$risk_rank"
      best_fail="$fail_count"
      continue
    fi

    if [ "$risk_rank" -gt "$best_risk_rank" ]; then
      continue
    fi

    if [ "$fail_count" -lt "$best_fail" ]; then
      best_name="$name"
      best_health_rank="$health_rank"
      best_risk_rank="$risk_rank"
      best_fail="$fail_count"
      continue
    fi

    if [ "$fail_count" -gt "$best_fail" ]; then
      continue
    fi

    if [ "$name" \< "$best_name" ]; then
      best_name="$name"
      best_health_rank="$health_rank"
      best_risk_rank="$risk_rank"
      best_fail="$fail_count"
    fi
  done < <("$(yq_bin)" eval '.sources | keys | .[]' "$(subscriptions_file)" 2>/dev/null)

  [ -n "${best_name:-}" ] && echo "$best_name"
}

recommended_subscription_reason_lines() {
  local recommended active
  local rec_health rec_fail rec_risk
  local active_health active_fail active_risk

  recommended="$(recommended_subscription_name 2>/dev/null || true)"
  active="$(active_subscription_name 2>/dev/null || true)"

  [ -n "${recommended:-}" ] || return 0

  rec_health="$(subscription_health_status "$recommended" 2>/dev/null || echo "unknown")"
  rec_fail="$(subscription_fail_count "$recommended" 2>/dev/null || echo "0")"

  if subscription_auto_disabled "$recommended"; then
    rec_risk="yes"
  else
    rec_risk="no"
  fi

  if [ -n "${active:-}" ] && [ "${active:-}" != "${recommended:-}" ]; then
    active_health="$(subscription_health_status "$active" 2>/dev/null || echo "unknown")"
    active_fail="$(subscription_fail_count "$active" 2>/dev/null || echo "0")"

    if subscription_auto_disabled "$active"; then
      active_risk="yes"
    else
      active_risk="no"
    fi

    if [ "$rec_health" != "$active_health" ]; then
      echo "- 健康状态更优：${rec_health}（当前为 ${active_health}）"
    fi

    if [ "$rec_risk" = "no" ] && [ "$active_risk" = "yes" ]; then
      echo "- 未命中风险阈值（当前订阅已命中）"
    elif [ "$rec_risk" = "no" ]; then
      echo "- 未命中风险阈值"
    fi

    if [ "$rec_fail" != "$active_fail" ]; then
      echo "- 失败次数更少：${rec_fail}（当前为 ${active_fail}）"
    else
      echo "- 当前失败次数：${rec_fail}"
    fi

    return 0
  fi

  if [ "$rec_risk" = "no" ]; then
    echo "- 未命中风险阈值"
  fi
  echo "- 当前健康状态：${rec_health}"
  echo "- 当前失败次数：${rec_fail}"
}

next_enabled_subscription_name_excluding() {
  local exclude_name="$1"
  local file name

  file="$(subscriptions_file)"
  ensure_subscriptions_file

  while IFS= read -r name; do
    [ -n "${name:-}" ] || continue
    [ "$name" = "$exclude_name" ] && continue

    if subscription_enabled "$name"; then
      echo "$name"
      return 0
    fi
  done < <("$(yq_bin)" eval '.sources | keys | .[]' "$file")

  return 1
}

switch_active_subscription_silently() {
  local name="$1"
  local file

  [ -n "${name:-}" ] || return 1

  file="$(subscriptions_file)"
  ensure_subscriptions_file
  subscription_exists "$name" || return 1

  NAME="$name" "$(yq_bin)" eval -i '
    .active = env(NAME)
  ' "$file"
}

clear_active_switch_runtime_event() {
  write_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_FROM" ""
  write_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_TO" ""
  write_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_TIME" ""
  write_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_REASON" ""
}

ensure_active_subscription_usable() {
  local active recommended reason

  active="$(active_subscription_name 2>/dev/null || true)"

  [ -n "${active:-}" ] || {
    clear_active_switch_runtime_event
    return 0
  }

  if subscription_exists "$active" && subscription_enabled "$active"; then
    clear_active_switch_runtime_event
    return 0
  fi

  reason="active subscription unavailable"

  recommended="$(next_enabled_subscription_name_excluding "$active" 2>/dev/null || true)"
  if [ -z "${recommended:-}" ]; then
    recommended="$(first_enabled_subscription_name 2>/dev/null || true)"
  fi

  write_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_FROM" "$active"
  write_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_TO" ""
  write_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_TIME" "$(now_datetime)"
  write_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_REASON" "$reason"
  write_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_RECOMMENDATION" "${recommended:-}"

  warn "当前主订阅不可用，已记录风险，不会自动切换：$active"
  return 1
}

active_subscription_auto_disabled() {
  local active
  active="$(active_subscription_name)"
  subscription_auto_disabled "$active"
}

has_any_enabled_subscription() {
  local file count

  file="$(subscriptions_file)"
  ensure_subscriptions_file

  count="$("$(yq_bin)" eval '[.sources[] | select(.enabled == true)] | length' "$file" 2>/dev/null || echo 0)"
  [ "${count:-0}" -gt 0 ]
}

has_any_auto_disabled_subscription() {
  local file name

  file="$(subscriptions_file)"
  ensure_subscriptions_file

  while IFS= read -r name; do
    [ -n "${name:-}" ] || continue
    if subscription_auto_disabled "$name"; then
      return 0
    fi
  done < <("$(yq_bin)" eval '.sources | keys | .[]' "$file")

  return 1
}

runtime_last_fallback_used() {
  read_runtime_event_value "RUNTIME_LAST_FALLBACK_USED" 2>/dev/null || true
}

runtime_last_fallback_time() {
  read_runtime_event_value "RUNTIME_LAST_FALLBACK_TIME" 2>/dev/null || true
}

runtime_last_fallback_reason() {
  read_runtime_event_value "RUNTIME_LAST_FALLBACK_REASON" 2>/dev/null || true
}

runtime_last_risk_level() {
  read_runtime_event_value "RUNTIME_LAST_RISK_LEVEL" 2>/dev/null || true
}

calculate_runtime_risk_level() {
  local build_status active enabled

  build_status="$(read_build_value "BUILD_LAST_STATUS" 2>/dev/null || true)"
  active="$(active_subscription_name 2>/dev/null || true)"

  if ! has_any_enabled_subscription; then
    echo "critical"
    return 0
  fi

  if [ "${build_status:-}" = "failed" ]; then
    echo "high"
    return 0
  fi

  if [ -n "${active:-}" ] && ! active_subscription_enabled; then
    echo "high"
    return 0
  fi

  if has_any_auto_disabled_subscription; then
    echo "medium"
    return 0
  fi

  echo "low"
}

print_subscription_table_header() {
  local show_index="${1:-false}"

  if [ "$show_index" = "true" ]; then
    echo "  编号 名称             类型     URL"
  else
    echo "  名称             类型     URL"
  fi
}

print_subscription_pick_line() {
  local index="$1"
  local name="$2"
  local _url_mode="${3:-full}"
  local show_index="${4:-true}"
  local active type_text marker url_text

  [ -n "${name:-}" ] || return 0

  active="$(active_subscription_name 2>/dev/null || true)"

  if [ "$name" = "$active" ]; then
    marker="$(printf '\033[32m*\033[0m')"
  else
    marker=" "
  fi

  type_text="$(subscription_format_by_name "$name" 2>/dev/null || echo "clash")"
  url_text="$(subscription_url_by_name "$name" 2>/dev/null || true)"
  [ -n "${url_text:-}" ] || url_text="-"

  if [ "$show_index" = "true" ]; then
    printf '%b %-2s) %-16s %-8s %s\n' \
      "$marker" "$index" "$name" "$type_text" "$url_text"
  else
    printf '%b %-16s %-8s %s\n' \
      "$marker" "$name" "$type_text" "$url_text"
  fi
}

print_subscription_summary_line() {
  local name="$1"
  local active enabled_text health_text fail_count marker notes type_text

  [ -n "${name:-}" ] || return 0

  active="$(active_subscription_name 2>/dev/null || true)"

  if [ "$name" = "$active" ]; then
    marker="*"
  else
    marker=" "
  fi

  if subscription_enabled "$name"; then
    enabled_text="enabled"
  else
    enabled_text="disabled"
  fi

  health_text="$(subscription_health_status "$name" 2>/dev/null || echo "unknown")"
  fail_count="$(subscription_fail_count "$name" 2>/dev/null || echo "0")"
  type_text="$(subscription_format_by_name "$name" 2>/dev/null || echo "clash")"

  notes=""
  if subscription_auto_disabled "$name"; then
    notes="risk"
  fi

  if [ -n "${notes:-}" ]; then
    printf '%s %-16s %-8s %-9s %-8s fail=%-3s %s\n' \
      "$marker" "$name" "$type_text" "$enabled_text" "$health_text" "$fail_count" "$notes"
  else
    printf '%s %-16s %-8s %-9s %-8s fail=%-3s\n' \
      "$marker" "$name" "$type_text" "$enabled_text" "$health_text" "$fail_count"
  fi
}

list_subscriptions() {
  local file name found="false" idx=1

  file="$(subscriptions_file)"
  ensure_subscriptions_file

  print_subscription_table_header "false"
  while IFS= read -r name; do
    [ -n "${name:-}" ] || continue
    found="true"
    print_subscription_pick_line "$idx" "$name" "full" "false"
    idx=$((idx + 1))
  done < <("$(yq_bin)" eval '.sources | keys | .[]' "$file" 2>/dev/null)

  [ "$found" = "true" ] || echo "  暂无订阅"
}

enable_subscription() {
  local name="$1"
  set_subscription_enabled "$name" "true"
}

disable_subscription() {
  local name="$1"
  set_subscription_enabled "$name" "false"
}

subscription_list_overview_lines() {
  local active recommended

  active="$(active_subscription_name 2>/dev/null || true)"
  recommended="$(recommended_subscription_name 2>/dev/null || true)"

  if [ -n "${active:-}" ]; then
    echo "🚩 当前主订阅：$active"
  else
    echo "🚩 当前主订阅：未设置"
  fi

  if [ -n "${recommended:-}" ] && [ "${recommended:-}" != "${active:-}" ]; then
    echo "💡 推荐订阅：$recommended"
  elif [ -n "${active:-}" ]; then
    echo "💡 推荐订阅：保持当前"
  else
    echo "💡 推荐订阅：暂无"
  fi

  echo "🧩 编译模式：active-only"
}

subscription_list_recommendation_lines() {
  echo "👉 clashctl use  切换当前使用的订阅"
}

detect_subscription_format() {
  local url="$1"

  case "$url" in
    *.yaml|*.yml|*".yaml?"*|*".yml?"*)
      echo "clash"
      ;;
    *)
      echo "clash"
      ;;
  esac
}

prompt_subscription_if_needed() {
  local current_url input_url input_fmt

  current_url="$(subscription_url 2>/dev/null || true)"
  if [ -n "${current_url:-}" ]; then
    return 0
  fi

  echo
  echo "🚀 请输入订阅链接"
  printf "> "
  IFS= read -r input_url || true

  input_url="$(printf '%s' "${input_url:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [ -z "${input_url:-}" ]; then
    return 0
  fi

  if ! subscription_url_is_supported "$input_url"; then
    ui_warn "订阅链接格式不合法，已跳过"
    ui_next "稍后执行：clashctl add <订阅链接>"
    return 0
  fi

  input_fmt="$(detect_subscription_format "$input_url")"
  write_env_value "CLASH_SUBSCRIPTION_URL" "$input_url"
  bootstrap_subscription_from_install_input "$input_url" "$input_fmt" "default"
}

clear_subscription() {
  local file="$PROJECT_DIR/.env"

  [ -f "$file" ] || {
    warn ".env 不存在，无需清理订阅地址"
    return 0
  }

  awk '
    $0 ~ /^[[:space:]]*(export[[:space:]]+)?CLASH_SUBSCRIPTION_URL=/ { next }
    $0 ~ /^[[:space:]]*(export[[:space:]]+)?CLASH_URL=/ { next }
    { print }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"

  success "订阅地址已清理"
}

subconverter_pid_file() {
  echo "$RUNTIME_DIR/subconverter.pid"
}

subconverter_log_file() {
  echo "$LOG_DIR/subconverter.log"
}

subconverter_port() {
  echo "${SUBCONVERTER_PORT:-25500}"
}

subconverter_url() {
  echo "http://127.0.0.1:$(subconverter_port)"
}

subconverter_running() {
  local pid_file pid

  pid_file="$(subconverter_pid_file)"
  [ -f "$pid_file" ] || return 1

  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [ -n "${pid:-}" ] || return 1

  kill -0 "$pid" 2>/dev/null
}

start_subconverter() {
  local home bin log_file pid_file pid i old_pwd exit_status

  home="$(subconverter_home)"
  bin="$(subconverter_bin)"
  log_file="$(subconverter_log_file)"
  pid_file="$(subconverter_pid_file)"
  exit_status="unknown"

  [ -f "$bin" ] || die "subconverter 未安装：$bin"
  if [ ! -x "$bin" ]; then
    chmod +x "$bin" 2>/dev/null || die "subconverter 无法修正执行权限：$bin"
  fi
  [ -x "$bin" ] || die "subconverter 文件不可执行：$bin"
  mkdir -p "$LOG_DIR"

  if subconverter_running; then
    if is_port_in_use "$(subconverter_port)"; then
      return 0
    fi
    warn "检测到旧 subconverter 进程存在但端口未监听，正在重启"
    stop_subconverter || true
  fi

  old_pwd="$(pwd)"
  rm -f "$pid_file" 2>/dev/null || true
  cd "$home" || die "subconverter 工作目录不可用：$home"
  nohup "$bin" > "$log_file" 2>&1 &
  pid=$!
  cd "$old_pwd" || true
  echo "$pid" > "$pid_file"

  for i in 1 2 3 4 5; do
    if subconverter_running && is_port_in_use "$(subconverter_port)"; then
      return 0
    fi
    sleep 1
  done

  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [ -n "${pid:-}" ] && ! kill -0 "$pid" 2>/dev/null; then
    if wait "$pid" 2>/dev/null; then
      exit_status="0"
    else
      exit_status="$?"
    fi
  fi
  {
    error "subconverter 启动失败"
    warn "启动命令：cd \"$home\" && \"$bin\""
    warn "监听端口：$(subconverter_port)"
    warn "pid 文件：$pid_file"
    warn "pid：${pid:-unknown}"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      warn "进程状态：仍在运行，但未监听预期端口"
    else
      warn "进程状态：已退出或未成功启动"
      warn "退出状态：$exit_status"
    fi
    warn "日志文件：$log_file"
    if [ -f "$log_file" ]; then
      tail -n 20 "$log_file" 2>/dev/null | sed 's/^/  /' >&2 || true
    fi
  } >&2
  return 1
}

stop_subconverter() {
  local pid_file pid

  pid_file="$(subconverter_pid_file)"
  [ -f "$pid_file" ] || return 0

  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi

  rm -f "$pid_file"
}

subscription_yaml_validate() {
  local file="$1"

  [ -s "$file" ] || return 1

  # 先做一次最小 YAML 解析校验
  if ! "$(yq_bin)" eval '.' "$file" >/dev/null 2>&1; then
    return 1
  fi

  # 再做一次 Clash/Mihomo 订阅的基本结构校验
  # 允许是完整配置，也允许是仅包含 proxies / proxy-groups / rules / rule-providers 的订阅
  if ! "$(yq_bin)" eval '
    (
      (.proxies != null) or
      (.["proxy-groups"] != null) or
      (.rules != null) or
      (.["rule-providers"] != null) or
      (.["mixed-port"] != null) or
      (.port != null) or
      (.mode != null)
    )
  ' "$file" 2>/dev/null | grep -qx 'true'; then
    return 1
  fi

  return 0
}

write_subscription_invalid_debug_snapshot() {
  local bad_file="$1"
  local snapshot_file
  local max_lines="30"

  snapshot_file="$(config_tmp_dir)/subscription-invalid-preview.txt"
  mkdir -p "$(config_tmp_dir)"

  {
    echo "===== invalid subscription preview ====="
    echo "time: $(now_datetime)"
    echo "file: $bad_file"
    echo
    sed -n "1,${max_lines}p" "$bad_file" 2>/dev/null || true
    echo
    echo "===== end ====="
  } > "$snapshot_file"
}

save_build_stage_snapshot() {
  local stage="$1"
  local file="$2"
  local snapshot_file

  [ -n "${stage:-}" ] || return 0
  [ -s "${file:-}" ] || return 0

  snapshot_file="$(config_tmp_dir)/snapshot-${stage}.yaml"
  cp -f "$file" "$snapshot_file" 2>/dev/null || true
}

fail_if_yaml_invalid() {
  local stage="$1"
  local file="$2"
  local mode="$3"
  local policy="$4"
  local active="$5"
  local selected="$6"
  local included="$7"
  local failed="$8"

  if subscription_yaml_validate "$file"; then
    save_build_stage_snapshot "$stage" "$file"
    return 0
  fi

  save_build_stage_snapshot "$stage" "$file"
  write_subscription_invalid_debug_snapshot "$file"

  write_compile_error "配置在阶段 ${stage} 后变成了非法 YAML"
  append_compile_error "stage        : $stage"
  append_compile_error "file         : $file"
  append_compile_error "snapshot     : $(config_tmp_dir)/snapshot-${stage}.yaml"
  append_compile_error "preview_file : $(config_tmp_dir)/subscription-invalid-preview.txt"

  fail_build_with_detail \
    "invalid-yaml-${stage}" \
    "$mode" \
    "$policy" \
    "$active" \
    "$selected" \
    "$included" \
    "$failed" \
    "配置在阶段 ${stage} 后变成了非法 YAML"
}

build_stage_guard() {
  local stage="$1"
  local file="$2"
  local mode="$3"
  local policy="$4"
  local active="$5"
  local selected="$6"
  local included="$7"
  local failed="$8"

  fail_if_yaml_invalid "$stage" "$file" "$mode" "$policy" "$active" "$selected" "$included" "$failed"
}

build_debug_enabled() {
  case "${CLASH_BUILD_DEBUG:-false}" in
    true|1|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

build_debug() {
  build_debug_enabled || return 0
  printf '🧩 [build] %s\n' "$*"
}

build_stage_run() {
  local stage="$1"
  local file="$2"
  local mode="$3"
  local policy="$4"
  local active="$5"
  local selected="$6"
  local included="$7"
  local failed="$8"
  shift 8

  build_debug "enter stage=${stage}"

  "$@"

  build_stage_guard "$stage" "$file" "$mode" "$policy" "$active" "$selected" "$included" "$failed"
  build_debug "ok    stage=${stage}"
}

build_stage_run_with_snapshot() {
  local stage="$1"
  local file="$2"
  local mode="$3"
  local policy="$4"
  local active="$5"
  local selected="$6"
  local included="$7"
  local failed="$8"
  shift 8

  build_stage_run \
    "$stage" \
    "$file" \
    "$mode" \
    "$policy" \
    "$active" \
    "$selected" \
    "$included" \
    "$failed" \
    "$@"

  save_build_stage_snapshot "$stage" "$file"
}

convert_subscription_via_subconverter() {
  local url="$1"
  local out_file="$2"
  local fetch_reason="${3:-auto}"
  local convert_reason="${4:-subscription-type-convert}"
  local api tmp_file curl_error_file
  local curl_meta curl_rc http_code effective_url errexit_was_set
  local log_file
  local scheme convert_url
  local validate_ok="false"

  [ -n "${url:-}" ] || return 1

  scheme="$(subscription_url_scheme "$url")"
  convert_url="$url"

  case "$scheme" in
    http|https)
      ;;
    file)
      local_subscription_convert_url_from_url "$url"
      convert_url="$LOCAL_SUBSCRIPTION_CONVERT_URL"
      ;;
    *)
      die "不支持的订阅协议：$url"
      ;;
  esac

  case "$fetch_reason" in
    auto|install|bootstrap|"")
      if [ "$scheme" != "file" ] && subscription_cache_restore "$url" "convert" "$out_file"; then
        if subscription_yaml_validate "$out_file"; then
          return 0
        fi
        clear_subscription_cache "$url" "convert"
        rm -f "$out_file" 2>/dev/null || true
      fi
      ;;
  esac

  start_subconverter || return 1
  api="$(subconverter_url)/sub"
  log_file="$(subconverter_log_file)"
  tmp_file="$(mktemp)"
  curl_error_file="$(mktemp)"
  rm -f "$tmp_file" 2>/dev/null || true

  info "正在通过 subconverter 转换订阅"
  case "$convert_reason" in
    direct-clash-invalid)
      if [ "$scheme" = "file" ]; then
        info "转换原因：本地订阅不是可直接运行的 Clash YAML"
      else
        info "转换原因：直连订阅已下载，但不是可直接运行的 Clash YAML"
      fi
      ;;
    subscription-type-convert)
      info "转换原因：订阅类型为 convert"
      ;;
    *)
      info "转换原因：$convert_reason"
      ;;
  esac
  info "subconverter 请求：GET $api"
  info "subconverter 参数：target=clash"
  if [ "$scheme" = "file" ]; then
    info "subconverter 参数：url=<本地订阅分享链接内容>"
  else
    info "subconverter 参数：url=$convert_url"
  fi
  info "subconverter 未发送参数：insert/config/emoji/list（使用 subconverter 默认值）"

  errexit_was_set="false"
  case "$-" in
    *e*)
      errexit_was_set="true"
      set +e
      ;;
  esac

  curl_meta="$(curl -sS -L -G "$api" \
    --data-urlencode "target=clash" \
    --data-urlencode "url=$convert_url" \
    -o "$tmp_file" \
    -w '%{http_code}\n%{url_effective}' 2>"$curl_error_file")"
  curl_rc=$?

  [ "$errexit_was_set" = "true" ] && set -e

  http_code="$(printf '%s\n' "$curl_meta" | head -n 1)"
  effective_url="$(printf '%s\n' "$curl_meta" | sed -n '2p')"

  if [ -n "${effective_url:-}" ]; then
    if [ "$scheme" = "file" ]; then
      info "subconverter 实际请求 URL：<已省略本地订阅分享链接内容>"
    else
      info "subconverter 实际请求 URL：$effective_url"
    fi
  fi
  [ -n "${http_code:-}" ] && info "subconverter HTTP 状态码：$http_code"

  if [ "$curl_rc" -ne 0 ] || [ -z "${http_code:-}" ] || [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    warn "subconverter 转换请求失败：curl_rc=$curl_rc http_code=${http_code:-unknown}"
    [ -s "$curl_error_file" ] && {
      warn "curl 错误输出："
      head -n 20 "$curl_error_file" >&2
    }
    [ -s "$tmp_file" ] && {
      warn "subconverter 响应体预览："
      head -n 20 "$tmp_file" >&2
    }
    rm -f "$tmp_file" "$curl_error_file" 2>/dev/null || true
    return 1
  fi

  rm -f "$curl_error_file" 2>/dev/null || true

  [ -s "$tmp_file" ] || {
    rm -f "$tmp_file" 2>/dev/null || true
    return 1
  }

  if subscription_yaml_validate "$tmp_file"; then
    validate_ok="true"
  fi

  if [ "$validate_ok" != "true" ]; then
    write_subscription_invalid_debug_snapshot "$tmp_file"

    warn "subconverter 返回内容不是合法 Clash YAML"
    warn "调试预览已写入：$(config_tmp_dir)/subscription-invalid-preview.txt"
    [ -f "$log_file" ] && warn "subconverter 日志：$log_file"

    rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi

  mv -f "$tmp_file" "$out_file"
  [ "$scheme" = "file" ] || subscription_cache_store "$url" "convert" "$out_file" "$api"
  return 0
}

set_subscription_format() {
  ui_info "当前版本订阅格式已固定为 convert，无需设置"
  return 0
}

show_subscription_format_help() {
  echo "可用订阅格式："
  echo "  clash    先直接下载 Clash YAML；若返回内容不是合法 YAML，则自动尝试转换"
  echo "  convert  直接通过 subconverter 转换通用订阅"
}

add_profile() {
  local profile_name="$1"
  local profiles_file="$CONFIG_DIR/profiles.yaml"

  [ -n "${profile_name:-}" ] || die "Profile 名称不能为空"

  ensure_config_files

  if profile_exists "$profile_name"; then
    die "Profile 已存在：$profile_name"
  fi

  PROFILE_NAME="$profile_name" "$(yq_bin)" eval -i '
    .profiles[env(PROFILE_NAME)] = {}
  ' "$profiles_file"

  success "Profile 已添加：$profile_name"
}

delete_profile() {
  local profile_name="$1"
  local profiles_file="$CONFIG_DIR/profiles.yaml"
  local active_name

  [ -n "${profile_name:-}" ] || die "Profile 名称不能为空"

  ensure_config_files

  profile_exists "$profile_name" || die "Profile 不存在：$profile_name"

  active_name="$(show_active_profile)"

  if [ "$profile_name" = "default" ]; then
    die "默认 Profile 不允许删除：default"
  fi

  if [ "$profile_name" = "$active_name" ]; then
    die "当前激活的 Profile 不允许直接删除，请先切换到其他 Profile"
  fi

  PROFILE_NAME="$profile_name" "$(yq_bin)" eval -i '
    del(.profiles[env(PROFILE_NAME)])
  ' "$profiles_file"

  success "Profile 已删除：$profile_name"
}

profile_set_allowed_key() {
  case "$1" in
    mixed-port|allow-lan|external-controller|mode|log-level)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

profile_normalize_value() {
  local key="$1"
  local value="$2"

  case "$key" in
    mixed-port)
      echo "$value" | grep -Eq '^[0-9]+$' || die "mixed-port 必须是数字"
      echo "$value"
      ;;
    allow-lan)
      case "$value" in
        true|false)
          echo "$value"
          ;;
        *)
          die "allow-lan 只允许 true 或 false"
          ;;
      esac
      ;;
    external-controller)
      [ -n "${value:-}" ] || die "external-controller 不能为空"
      echo "$value"
      ;;
    mode)
      case "$value" in
        rule|global|direct)
          echo "$value"
          ;;
        *)
          die "mode 只允许 rule / global / direct"
          ;;
      esac
      ;;
    log-level)
      case "$value" in
        trace|debug|info|warning|error|silent)
          echo "$value"
          ;;
        *)
          die "log-level 只允许 trace / debug / info / warning / error / silent"
          ;;
      esac
      ;;
    *)
      die "不支持的 Profile 键：$key"
      ;;
  esac
}

set_profile_value() {
  local profile_name="$1"
  local key="$2"
  local raw_value="$3"
  local value="$4"
  local profiles_file="$CONFIG_DIR/profiles.yaml"

  [ -n "${profile_name:-}" ] || die "Profile 名称不能为空"
  [ -n "${key:-}" ] || die "配置键不能为空"
  [ -n "${raw_value:-}" ] || die "配置值不能为空"

  ensure_config_files
  profile_exists "$profile_name" || die "Profile 不存在：$profile_name"
  profile_set_allowed_key "$key" || die "不支持的 Profile 键：$key"

  case "$key" in
    mixed-port|allow-lan)
      PROFILE_NAME="$profile_name" PROFILE_KEY="$key" PROFILE_VALUE="$value" "$(yq_bin)" eval -i '
        .profiles[env(PROFILE_NAME)][env(PROFILE_KEY)] = env(PROFILE_VALUE)
      ' "$profiles_file"
      ;;
    external-controller|mode|log-level)
      PROFILE_NAME="$profile_name" PROFILE_KEY="$key" PROFILE_VALUE="$value" "$(yq_bin)" eval -i '
        .profiles[env(PROFILE_NAME)][env(PROFILE_KEY)] = strenv(PROFILE_VALUE)
      ' "$profiles_file"
      ;;
    *)
      die "不支持的 Profile 键：$key"
      ;;
  esac

  success "Profile 配置已更新：$profile_name.$key = $value"
}

profile_set_value() {
  local profile_name="$1"
  local key="$2"
  local raw_value="$3"
  local value

  value="$(profile_normalize_value "$key" "$raw_value")"
  set_profile_value "$profile_name" "$key" "$raw_value" "$value"
}

# ===== FINAL OVERRIDE: active-only runtime pipeline =====

resolve_build_sources() {
  local active

  active="$(active_subscription_name 2>/dev/null || true)"

  if [ -n "${active:-}" ] && subscription_exists "$active" && subscription_enabled "$active"; then
    echo "$active"
    return 0
  fi

  return 1
}

build_runtime_candidate_from_payload() {
  local payload_file="$1"
  local out_file="$2"

  [ -s "$payload_file" ] || return 1
  subscription_yaml_validate "$payload_file" || return 1

  cp -f "$payload_file" "$out_file"
  normalize_runtime_config "$out_file"
  test_runtime_config "$out_file" >/dev/null 2>&1
}

fetch_subscription_source() {
  local name="$1"
  local out_file="$2"
  local fetch_reason="${3:-auto}"
  local url fmt reason scheme
  local raw_file candidate_file

  url="$(subscription_url_by_name "$name")"
  fmt="$(subscription_format_by_name "$name")"
  scheme="$(subscription_url_scheme "$url")"

  raw_file="$(mktemp)"
  candidate_file="$(mktemp)"
  rm -f "$raw_file" "$candidate_file" 2>/dev/null || true

  if [ -z "${url:-}" ]; then
    mark_subscription_health_failure "$name" "订阅源地址为空"
    rm -f "$raw_file" "$candidate_file" 2>/dev/null || true
    return 1
  fi

  case "$fmt" in
    ""|clash)
      case "$fetch_reason" in
        explicit-add|manual-add|manual-use|manual-refresh)
          clear_subscription_cache "$url" "clash"
          clear_subscription_cache "$url" "convert"
          ;;
      esac

      if download_subscription_yaml "$url" "$raw_file" "$fetch_reason"; then
        if build_runtime_candidate_from_payload "$raw_file" "$candidate_file"; then
          mv -f "$candidate_file" "$out_file"
          rm -f "$raw_file" 2>/dev/null || true
          mark_subscription_health_success "$name"
          return 0
        fi

        write_subscription_invalid_debug_snapshot "$raw_file"

        rm -f "$candidate_file" 2>/dev/null || true
        candidate_file="$(mktemp)"
        rm -f "$candidate_file" 2>/dev/null || true

        if convert_subscription_via_subconverter "$url" "$raw_file" "$fetch_reason" "direct-clash-invalid"; then
          if build_runtime_candidate_from_payload "$raw_file" "$candidate_file"; then
            mv -f "$candidate_file" "$out_file"
            rm -f "$raw_file" 2>/dev/null || true
            mark_subscription_health_success "$name"
            return 0
          fi

          write_subscription_invalid_debug_snapshot "$raw_file"
          if [ "$scheme" = "file" ]; then
            reason="本地订阅转换成功，但 config 校验失败"
          else
            reason="订阅下载成功，但原始配置与转换结果都不能直接运行"
          fi
        else
          if [ "$scheme" = "file" ]; then
            reason="本地订阅不是 Clash YAML，且 subconverter 转换失败"
          else
            reason="订阅下载成功，但原始配置不能直接运行，且转换失败"
          fi
        fi
      else
        reason="订阅下载失败"
      fi
      ;;
    convert)
      case "$fetch_reason" in
        explicit-add|manual-add|manual-use|manual-refresh)
          clear_subscription_cache "$url" "convert"
          ;;
      esac

      if convert_subscription_via_subconverter "$url" "$raw_file" "$fetch_reason" "subscription-type-convert"; then
        if build_runtime_candidate_from_payload "$raw_file" "$candidate_file"; then
          mv -f "$candidate_file" "$out_file"
          rm -f "$raw_file" 2>/dev/null || true
          mark_subscription_health_success "$name"
          return 0
        fi

        write_subscription_invalid_debug_snapshot "$raw_file"
        reason="订阅转换成功，但转换结果不能直接运行"
      else
        reason="订阅转换失败"
      fi
      ;;
    *)
      reason="不支持的订阅格式：$fmt"
      ;;
  esac

  rm -f "$raw_file" "$candidate_file" 2>/dev/null || true
  mark_subscription_health_failure "$name" "$reason"
  return 1
}

generate_config() {
  local active_source
  local out_file="$RUNTIME_DIR/config.yaml"
  local tmp_dir source_file
  local selected_csv="" included_csv="" failed_csv=""

  ensure_active_subscription_usable || true

  active_source="$(active_subscription_name 2>/dev/null || true)"

  mkdir -p "$RUNTIME_DIR" "$(config_tmp_dir)"
  tmp_dir="$(config_tmp_dir)"
  source_file="$tmp_dir/source-${active_source}.yaml"

  if [ -z "${active_source:-}" ] || ! subscription_exists "$active_source" || ! subscription_enabled "$active_source"; then
    write_compile_error "当前没有可用主订阅"
    fail_build_with_detail \
      "resolve-active-source" \
      "single" \
      "active-only" \
      "${active_source:-}" \
      "" \
      "" \
      "" \
      "当前没有可用主订阅"
  fi

  selected_csv="$active_source"

  if ! fetch_subscription_source "$active_source" "$source_file" "auto"; then
    failed_csv="$active_source"
    write_compile_error "当前主订阅不可用"
    append_compile_error "source : $active_source"
    fail_build_with_detail \
      "fetch-source" \
      "single" \
      "active-only" \
      "$active_source" \
      "$selected_csv" \
      "$included_csv" \
      "$failed_csv" \
      "当前主订阅不可用：$active_source"
  fi

  included_csv="$active_source"

  cp -f "$source_file" "$out_file"
  apply_runtime_mixin "$out_file"
  cp -f "$out_file" "$RUNTIME_DIR/config.last.yaml"
  save_build_stage_snapshot "active-source-ready" "$source_file"

  record_build_success \
    "single" \
    "active-only" \
    "$active_source" \
    "$selected_csv" \
    "$included_csv" \
    "$failed_csv"

  mark_runtime_config_source "build-active"
  # success "配置文件已生成：$out_file"
  return 0
}

regenerate_config() {
  generate_config
}
