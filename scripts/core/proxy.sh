#!/usr/bin/env bash

# shellcheck source=scripts/core/common.sh
source "${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/scripts/core/common.sh"

proxy_host() {
  echo "${CLASH_PROXY_HOST:-127.0.0.1}"
}

proxy_port() {
  local config_file="${1:-$RUNTIME_DIR/config.yaml}"
  local port

  [ -s "$config_file" ] || die "配置文件不存在：$config_file"

  port="$("$(yq_bin)" eval '.["mixed-port"] // .port // ""' "$config_file" 2>/dev/null | head -n 1)"
  [ -n "${port:-}" ] && [ "$port" != "null" ] || die "未在配置文件中找到代理端口"

  echo "$port"
}

proxy_http_url() {
  echo "http://$(proxy_host):$(proxy_port)"
}

proxy_socks_url() {
  echo "socks5://$(proxy_host):$(proxy_port)"
}

proxy_no_proxy_value() {
  echo "${NO_PROXY_DEFAULT:-127.0.0.1,localhost,::1}"
}

print_proxy_show() {
  echo
  echo "😼 当前代理环境"
  echo
  echo "🌐 HTTP：$(proxy_http_url)"
  echo "🧦 SOCKS5：$(proxy_socks_url)"
  echo "🚫 NO_PROXY：$(proxy_no_proxy_value)"
  echo
}

print_proxy_on_script() {
  local http_url socks_url no_proxy

  http_url="$(proxy_http_url)"
  socks_url="$(proxy_socks_url)"
  no_proxy="$(proxy_no_proxy_value)"

  cat <<EOF
export http_proxy="$http_url"
export https_proxy="$http_url"
export HTTP_PROXY="$http_url"
export HTTPS_PROXY="$http_url"
export all_proxy="$socks_url"
export ALL_PROXY="$socks_url"
export no_proxy="$no_proxy"
export NO_PROXY="$no_proxy"
EOF
}

print_proxy_off_script() {
  cat <<'EOF'
unset http_proxy
unset https_proxy
unset HTTP_PROXY
unset HTTPS_PROXY
unset all_proxy
unset ALL_PROXY
unset no_proxy
unset NO_PROXY
EOF
}

controller_addr() {
  local config_file="${1:-$RUNTIME_DIR/config.yaml}"

  [ -s "$config_file" ] || die "配置文件不存在：$config_file"

  "$(yq_bin)" eval '.["external-controller"] // ""' "$config_file" 2>/dev/null | head -n 1
}

controller_secret() {
  local config_file="${1:-$RUNTIME_DIR/config.yaml}"

  [ -s "$config_file" ] || die "配置文件不存在：$config_file"

  "$(yq_bin)" eval '.secret // ""' "$config_file" 2>/dev/null | head -n 1
}

controller_api_base() {
  local addr

  addr="$(controller_addr)"
  [ -n "${addr:-}" ] || die "未找到 external-controller"
  [ "$addr" != "null" ] || die "未找到 external-controller"

  echo "http://$addr"
}

controller_curl() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local base secret

  base="$(controller_api_base)"
  secret="$(controller_secret)"

  if [ -n "${data:-}" ]; then
    curl -fsSL -X "$method" \
      -H "Content-Type: application/json" \
      ${secret:+-H "Authorization: Bearer $secret"} \
      --data "$data" \
      "$base$path"
  else
    curl -fsSL -X "$method" \
      ${secret:+-H "Authorization: Bearer $secret"} \
      "$base$path"
  fi
}

proxy_controller_reachable() {
  controller_curl GET "/version" >/dev/null 2>&1
}

proxy_groups_json() {
  controller_curl GET "/proxies"
}

proxy_group_exists() {
  local group="$1"

  [ -n "${group:-}" ] || return 1

  [ "$(proxy_groups_json | "$(yq_bin)" -p=json eval ".proxies | has(\"$group\")" - 2>/dev/null)" = "true" ]
}

proxy_group_type() {
  local group="$1"

  [ -n "${group:-}" ] || die "策略组名称不能为空"
  proxy_group_exists "$group" || die "策略组不存在：$group"

  proxy_groups_json | "$(yq_bin)" -p=json eval ".proxies.\"$group\".type // \"\"" - 2>/dev/null
}

proxy_group_is_selector() {
  local type

  type="$(proxy_group_type "$1")"

  case "$type" in
    Selector|URLTest|Fallback|LoadBalance)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

proxy_group_list() {
  proxy_groups_json \
    | "$(yq_bin)" -p=json eval '
        .proxies
        | to_entries
        | map(select(.value.all != null))
        | .[].key
      ' - 2>/dev/null
}

proxy_group_current() {
  local group="$1"

  [ -n "${group:-}" ] || die "策略组名称不能为空"
  proxy_group_exists "$group" || die "策略组不存在：$group"

  proxy_groups_json \
    | "$(yq_bin)" -p=json eval ".proxies.\"$group\".now // \"\"" - 2>/dev/null
}

proxy_group_nodes() {
  local group="$1"

  [ -n "${group:-}" ] || die "策略组名称不能为空"
  proxy_group_exists "$group" || die "策略组不存在：$group"

  proxy_groups_json \
    | "$(yq_bin)" -p=json eval ".proxies.\"$group\".all[] // \"\"" - 2>/dev/null
}

proxy_group_select() {
  local group="$1"
  local node="$2"

  [ -n "${group:-}" ] || die "策略组名称不能为空"
  [ -n "${node:-}" ] || die "节点名称不能为空"

  proxy_group_exists "$group" || die "策略组不存在：$group"
  proxy_group_is_selector "$group" || die "该策略组不支持手动切换：$group"

  if ! proxy_group_nodes "$group" | grep -Fxq "$node"; then
    die "节点不存在于策略组中：$group -> $node"
  fi

  controller_curl PUT "/proxies/$group" "{\"name\":\"$node\"}" >/dev/null
}

proxy_group_count() {
  proxy_group_list 2>/dev/null | awk 'NF{c++} END{print c+0}'
}

default_proxy_group_name() {
  local config_file="${1:-$RUNTIME_DIR/config.yaml}"
  local group_name

  [ -s "$config_file" ] || return 1

  group_name="$("$(yq_bin)" eval '
    .["proxy-groups"][] |
    select(
      (.type == "select") or
      (.type == "url-test") or
      (.type == "fallback") or
      (.type == "load-balance")
    ) |
    .name
  ' "$config_file" 2>/dev/null | head -n 1)"

  [ -n "${group_name:-}" ] || return 1
  echo "$group_name"
}

default_proxy_group_current() {
  local group

  group="$(default_proxy_group_name 2>/dev/null || true)"
  [ -n "${group:-}" ] || return 1

  proxy_group_current "$group" 2>/dev/null || return 1
}

proxy_node_is_direct_like() {
  local node="$1"

  case "${node:-}" in
    DIRECT|REJECT|REJECT-DROP|PASS)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

proxy_group_first_relay_node() {
  local group="$1"
  local node

  [ -n "${group:-}" ] || return 1

  while IFS= read -r node; do
    [ -n "${node:-}" ] || continue
    if proxy_node_is_direct_like "$node"; then
      continue
    fi
    echo "$node"
    return 0
  done < <(proxy_group_nodes "$group")

  return 1
}

ensure_default_proxy_group_relay_selected() {
  local group current relay

  local switched=""

  while IFS= read -r group; do
    [ -n "${group:-}" ] || continue

    current="$(proxy_group_current "$group" 2>/dev/null || true)"
    [ -n "${current:-}" ] || continue

    if ! proxy_node_is_direct_like "$current"; then
      continue
    fi

    relay="$(proxy_group_first_relay_node "$group" 2>/dev/null || true)"
    [ -n "${relay:-}" ] || continue

    if [ "$relay" = "$current" ]; then
      continue
    fi

    proxy_group_select "$group" "$relay"

    if [ -n "${switched:-}" ]; then
      switched="${switched},${group}|${current}|${relay}"
    else
      switched="${group}|${current}|${relay}"
    fi
  done < <(proxy_group_list)

  [ -n "${switched:-}" ] && echo "$switched"
}

print_proxy_groups_status() {
  local group current

  while IFS= read -r group; do
    [ -n "${group:-}" ] || continue
    current="$(proxy_group_current "$group" 2>/dev/null || true)"

    if [ -n "${current:-}" ]; then
      echo "$group -> $current"
    else
      echo "$group -> <unknown>"
    fi
  done < <(proxy_group_list)
}

print_proxy_groups_summary() {
  local group current

  while IFS= read -r group; do
    [ -n "${group:-}" ] || continue
    current="$(proxy_group_current "$group" 2>/dev/null || true)"

    if [ -n "${current:-}" ]; then
      echo "$group -> $current"
    else
      echo "$group"
    fi
  done < <(proxy_group_list)
}