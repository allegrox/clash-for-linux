#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
PROJECT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/../.." && pwd)"

source "$PROJECT_DIR/scripts/core/common.sh"
source "$PROJECT_DIR/scripts/core/runtime.sh"
source "$PROJECT_DIR/scripts/core/config.sh"
source "$PROJECT_DIR/scripts/core/proxy.sh"
source "$PROJECT_DIR/scripts/core/update.sh"
source "$PROJECT_DIR/scripts/init/systemd.sh"
source "$PROJECT_DIR/scripts/init/systemd-user.sh"
source "$PROJECT_DIR/scripts/init/script.sh"

usage() {
  cat <<EOF
😼 Clash 控制台

Usage:
  clashon                        🚀 开启代理
  clashoff                       ⛔ 关闭代理
  clashctl <command>

🚀 Main Path:
  add [url] [name]               ➕ 添加订阅
  use                            🔁 切换当前订阅
  select                         💫 切换节点
  status                         😼 查看状态总览

📦 Subscription:
  ls                             📡 查看订阅列表
  health                         🩷  查看订阅健康

🕹️  Control:
  ui                             🕹️  查看 Web 控制台
  secret                         🔑 查看或设置 Web 密钥

🧭 Diagnose:
  doctor                         🧭 诊断环境与运行状态
  log/logs                       📜 查看日志

💡 更多高级能力：clashctl help advanced
EOF
}

usage_advanced() {
  cat <<EOF
😼 Clash 高级命令

🧩 Config:
  config                         🧩 配置编译管理
  mixin                          🧩 Mixin 配置管理

📡 Subscription Advanced:
  sub                            📡 订阅高级管理（启用 / 禁用 / 重命名 / 删除）

🧪 Runtime & Diagnose:
  tun                            🧪 Tun 模式管理
  doctor                         🧭 诊断环境与运行状态
  log/logs                       📜 查看日志

🚀 Lifecycle:
  upgrade                        🚀 升级当前或指定内核
  update                         🔄 更新项目代码
  dev reset                      🧪 恢复到安装前状态（保留项目目录和已下载文件）

📌 Advanced Examples:
  clashctl sub list
  clashctl sub enable hk
  clashctl sub disable hk
  clashctl sub rename hk hk-bak
  clashctl sub remove hk

  clashctl config show
  clashctl config explain
  clashctl config regen
  clashctl config kernel mihomo

  clashctl tun doctor
  clashctl update --force
  clashctl dev reset

🚀 Main Path Reminder:
  clashctl add [订阅链接] [名称]
  clashctl use
  clashon
  clashctl select
  clashctl status

💡 Notes:
  当前编译链固定为 active-only
  只处理当前 active 主订阅
  Tun 模式属于高级能力，开启前建议先执行：clashctl tun doctor
EOF
}

prepare() {
  init_project_context "$PROJECT_DIR"
  load_env_if_exists
  detect_install_scope auto
}

ensure_add_use_prerequisites() {
  if [ ! -x "$(yq_bin)" ]; then
    die_state "依赖未就绪：缺少 yq（$(yq_bin)）" \
              "请先执行 bash install.sh，或运行 clashctl doctor 查看缺失项"
  fi

  if [ ! -d "$RUNTIME_DIR" ]; then
    die_state "运行环境未初始化：缺少 runtime 目录" \
              "请先执行 bash install.sh"
  fi

  if [ ! -d "$CONFIG_DIR" ]; then
    die_state "运行环境未初始化：缺少 config 目录" \
              "请先执行 bash install.sh"
  fi
}

ensure_runtime_ports_ready() {
  local mixed_port controller_port dns_port
  local new_mixed_port="" new_controller_port="" new_dns_port=""
  local changed="false"
  local repair_detail=""

  # 运行中不做端口改写，避免把当前已经跑起来的 runtime 搅乱
  if status_is_running 2>/dev/null; then
    return 0
  fi

  # 当前没有 runtime/config.yaml 时，不在这里修；后面 generate_config 会生成
  [ -s "$RUNTIME_DIR/config.yaml" ] || return 0

  mixed_port="$(runtime_config_mixed_port 2>/dev/null || true)"
  controller_port="$(runtime_config_controller_port 2>/dev/null || true)"
  dns_port="$(runtime_config_dns_port 2>/dev/null || true)"

  if [ -n "${mixed_port:-}" ] && [ "$mixed_port" != "null" ] && is_port_in_use "$mixed_port"; then
    new_mixed_port="$(resolve_free_port 7890 7999)"
    write_env_value "MIXED_PORT" "$new_mixed_port"
    write_runtime_value "INSTALL_PLAN_MIXED_PORT" "$new_mixed_port"
    write_runtime_value "INSTALL_PLAN_MIXED_PORT_AUTO_CHANGED" "true"
    changed="true"
    repair_detail="${repair_detail} mixed-port:${mixed_port}->${new_mixed_port};"
    info "检测到 mixed-port 冲突：${mixed_port} -> ${new_mixed_port}"
  fi

  if [ -n "${controller_port:-}" ] && [ "$controller_port" != "null" ] && is_port_in_use "$controller_port"; then
    new_controller_port="$(resolve_free_port 9000 9199)"
    write_env_value "EXTERNAL_CONTROLLER" "127.0.0.1:${new_controller_port}"
    write_runtime_value "INSTALL_PLAN_CONTROLLER" "127.0.0.1:${new_controller_port}"
    write_runtime_value "INSTALL_PLAN_CONTROLLER_AUTO_CHANGED" "true"
    changed="true"
    repair_detail="${repair_detail} external-controller:${controller_port}->${new_controller_port};"
    info "检测到 external-controller 冲突：${controller_port} -> ${new_controller_port}"
  fi

  if [ -n "${dns_port:-}" ] && [ "$dns_port" != "null" ] && is_port_in_use "$dns_port"; then
    new_dns_port="$(resolve_free_port 1053 1999)"
    write_env_value "CLASH_DNS_PORT" "$new_dns_port"
    write_runtime_value "INSTALL_PLAN_DNS_PORT" "$new_dns_port"
    write_runtime_value "INSTALL_PLAN_DNS_PORT_AUTO_CHANGED" "true"
    changed="true"
    repair_detail="${repair_detail} dns:${dns_port}->${new_dns_port};"
    info "检测到 DNS 端口冲突：${dns_port} -> ${new_dns_port}"
  fi

  if [ "$changed" = "true" ]; then
    mark_runtime_port_repair_result "true" "$repair_detail"
    info "检测到端口占用，正在自动重建运行配置"
    regenerate_config
    success "端口冲突已自动修复"
  else
    mark_runtime_port_repair_result "false" "no-change"
  fi
}

ensure_on_path_ready() {
  load_system_state

  if [ "$SUBSCRIPTION_STATE" = "missing" ]; then
    die_state "当前没有可用订阅" "clashctl add <订阅链接>"
  fi

  if [ ! -s "$RUNTIME_DIR/config.yaml" ]; then
    info "检测到运行配置缺失，正在自动生成"
    regenerate_config || true
    load_system_state
  fi

  if [ ! -s "$RUNTIME_DIR/config.yaml" ] && [ ! -s "$RUNTIME_DIR/config.last.yaml" ]; then
    die_state "当前没有可启动的运行配置" "clashctl doctor"
  fi

  ensure_runtime_ports_ready
}

print_on_feedback() {
  local mixed_port controller controller_lan controller_public next_action
  local controller_ready="false"

  mixed_port="$(status_read_mixed_port 2>/dev/null || true)"
  controller="$(status_read_controller 2>/dev/null || true)"
  if proxy_controller_reachable 2>/dev/null; then
    controller_ready="true"
    controller_lan="$(status_read_controller_lan 2>/dev/null || true)"
    controller_public="$(status_read_controller_public 2>/dev/null || true)"
  else
    controller_lan=""
    controller_public=""
  fi
  load_system_state
  next_action="$(system_state_default_action 2>/dev/null || echo 'clashctl status')"

  echo
  echo "🟢 已开启代理环境"
  echo

  if [ -n "${mixed_port:-}" ] && [ "$mixed_port" != "null" ]; then
    echo "🌐 本地代理：http://127.0.0.1:${mixed_port}"
  else
    echo "🌐 本地代理：未知"
  fi

  if [ "$controller_ready" = "true" ] && [ -n "${controller:-}" ] && [ "$controller" != "null" ]; then
    echo "� 控制台：http://${controller}/ui"
    [ -n "${controller_lan:-}" ] && echo "🏠 局域网：http://${controller_lan}/ui"
    if [ -n "${controller_public:-}" ]; then
      echo "🌍 公网：http://${controller_public}/ui"
    else
      if controller_externally_reachable 2>/dev/null; then
        echo "🌍 公网：未探测到本机公网地址"
      else
        echo "🌍 公网：当前 controller 未对外监听"
      fi
    fi
  elif [ -n "${controller:-}" ] && [ "$controller" != "null" ]; then
    echo "� 控制台：控制器暂不可访问"
    echo "🌍 公网：控制器暂不可访问"
  else
    echo "� 控制台：未知"
  fi

  echo "👉 下一步：$next_action"
  echo
}

cmd_on() {
  local relay_switch
  local relay_switch_file relay_rc
  local already_on="false"

  trap 'rc=$?; ui_error "开启代理失败：cmd_on 在第 ${LINENO} 行执行失败：${BASH_COMMAND}（返回码：${rc}）"; ui_next "clashctl logs service"; exit "$rc"' ERR

  prepare
  ensure_on_path_ready

  if status_is_running 2>/dev/null \
    && proxy_controller_reachable 2>/dev/null \
    && [ "$(system_proxy_status 2>/dev/null || echo off)" = "on" ] \
    && system_proxy_matches_runtime 2>/dev/null; then
    already_on="true"
  fi

  if [ "${CLASH_ALIAS_CALL:-0}" != "1" ]; then
    ui_info "正在开启代理"
  fi

  if status_is_running 2>/dev/null && ! proxy_controller_reachable 2>/dev/null; then
    ui_warn "检测到内核已运行但控制器不可访问，正在重启以加载当前配置"
    service_restart || die_state "控制器启动失败：内核重启未完成" "clashctl logs mihomo"
  else
    service_start || die_state "控制器启动失败：内核启动未完成" "clashctl logs mihomo"
  fi

  if ! wait_runtime_controller_ready 8; then
    ui_warn "控制器未在预期时间内可访问，正在重启内核重试"
    service_restart || die_state "控制器启动失败：内核重启未完成" "clashctl logs mihomo"
    if ! wait_runtime_controller_ready 8; then
      status_is_running 2>/dev/null || die_state "控制器启动失败：内核未运行" "clashctl logs mihomo"
      ui_warn "控制器暂不可访问，继续开启本地代理；请稍后执行 clashctl doctor"
    fi
  fi

  if proxy_controller_reachable 2>/dev/null; then
    relay_switch=""
    relay_switch_file="$RUNTIME_DIR/.relay-switch.$$"
    if ensure_default_proxy_group_relay_selected >"$relay_switch_file" 2>/dev/null; then
      if [ -s "$relay_switch_file" ]; then
        IFS= read -r relay_switch < "$relay_switch_file" || relay_switch=""
      fi
    else
      relay_rc=$?
      relay_switch=""
      if [ "$relay_rc" -ne 1 ]; then
        ui_warn "策略组默认代理节点自动切换失败，已跳过，不影响代理开启"
      fi
    fi
    rm -f "$relay_switch_file" 2>/dev/null || true
    if [ -n "${relay_switch:-}" ]; then
      ui_info "检测到策略组存在直连默认项，已自动切换到代理节点"
    fi
  fi

  if ! system_proxy_enable; then
    service_stop >/dev/null 2>&1 || true
    die_state "当前环境不支持系统代理接管（仅支持可写 /etc/environment）" "clashctl doctor"
  fi

  load_system_state
  if [ "$already_on" = "true" ]; then
    ui_info "代理已经是开启状态"
  fi
  print_on_feedback

  if [ "${CLASH_ALIAS_CALL:-0}" != "1" ]; then
    ui_warn "当前通过 clashctl 子进程执行，已开启系统代理，但不会修改当前 Shell 代理变量"
    ui_next "需要当前 Shell 立即生效：source shell 入口后执行 clashon，或重新打开终端"
    ui_blank
  fi

  if [ "$RUNTIME_STATE" = "degraded" ]; then
    ui_warn "代理内核已启动，但控制器暂不可访问"
    ui_next "clashctl doctor"
    ui_blank
  fi

  trap - ERR
  return 0
}

cmd_off() {
  prepare
  service_stop

  if ! system_proxy_disable; then
    die_state "当前环境不支持系统代理关闭（仅支持可写 /etc/environment）" "clashctl doctor"
  fi

  echo "🧹 系统代理已关闭"
  ui_blank
}

ui_internal_url() {
  local controller host port
  controller="${1:-}"
  [ -n "${controller:-}" ] || controller="$(status_read_controller_raw 2>/dev/null || true)"

  [ -n "${controller:-}" ] && [ "$controller" != "null" ] || return 1
  host="${controller%:*}"
  port="${controller##*:}"

  if [ "${host:-}" = "0.0.0.0" ]; then
    host="127.0.0.1"
  fi

  host="$(url_host_bracket_if_needed "$host")"
  echo "http://${host}:${port}/ui"
}

ui_public_url() {
  local ip port
  ip="$(ui_public_ip 2>/dev/null || true)"
  port="${1:-}"
  [ -n "${port:-}" ] || port="$(ui_controller_port 2>/dev/null || true)"

  [ -n "${ip:-}" ] || return 1
  [ -n "${port:-}" ] || return 1

  ip="$(url_host_bracket_if_needed "$ip")"
  echo "http://${ip}:${port}/ui"
}

ui_lan_url() {
  local ip port
  ip="$(ui_lan_ip 2>/dev/null || true)"
  port="${1:-}"
  [ -n "${port:-}" ] || port="$(ui_controller_port 2>/dev/null || true)"

  [ -n "${ip:-}" ] || return 1
  [ -n "${port:-}" ] || return 1

  ip="$(url_host_bracket_if_needed "$ip")"
  echo "http://${ip}:${port}/ui"
}

cmd_ui() {
  local controller_addr="" controller_raw=""
  local internal_url="" lan_url="" public_url=""
  local current_secret="" controller_port="" controller_status=""

  prepare
  runtime_config_exists || die "🧩 运行时配置不存在，请先生成配置"

  controller_raw="$(status_read_controller_raw 2>/dev/null || true)"
  controller_addr="$(display_controller_local_addr "$controller_raw" 2>/dev/null || echo "$controller_raw")"
  [ -n "${controller_addr:-}" ] && [ "$controller_addr" != "null" ] || die_state "未解析到控制器地址" "clashctl doctor"

  controller_port="${controller_raw##*:}"
  internal_url="$(ui_internal_url "$controller_raw" 2>/dev/null || true)"
  if controller_externally_reachable 2>/dev/null; then
    lan_url="$(ui_lan_url "$controller_port" 2>/dev/null || true)"
    public_url="$(ui_public_url "$controller_port" 2>/dev/null || true)"
  fi
  current_secret="$(controller_secret 2>/dev/null || true)"

  if [ -z "${current_secret:-}" ] || [ "$current_secret" = "null" ]; then
    current_secret="未设置"
  fi

  if status_is_running; then
    if proxy_controller_reachable 2>/dev/null; then
      controller_status="可访问"
    else
      controller_status="不可访问"
    fi
  else
    controller_status="未运行"
  fi

  cmd_ui_box \
    "$controller_status" \
    "$internal_url" \
    "$lan_url" \
    "$public_url" \
    "$current_secret" \
    "$controller_port"

  cmd_ui_help_summary

  if [ "${CLASH_UI_BOX_ONLY:-0}" = "1" ]; then
    return 0
  fi

  case "$controller_status" in
    可访问)
      return 0
      ;;
    不可访问)
      ui_warn "控制器当前不可访问"
      ui_next "clashctl doctor"
      ui_blank
      return 1
      ;;
    未运行)
      ui_warn "当前代理未启动"
      ui_next "clashon"
      ui_blank
      return 1
      ;;
    *)
      ui_warn "控制器状态未知"
      ui_next "clashctl doctor"
      ui_blank
      return 1
      ;;
  esac
}

status_build_active_source() {
  read_build_value "BUILD_ACTIVE_SOURCE" 2>/dev/null || true
}

status_build_active_sources() {
  local value

  value="$(read_build_value "BUILD_ACTIVE_SOURCES" 2>/dev/null || true)"
  if [ -n "${value:-}" ]; then
    echo "$value"
    return 0
  fi

  # 兼容历史 build.env
  read_build_value "BUILD_INCLUDED_SOURCES" 2>/dev/null || true
}

status_build_failed_active_sources() {
  local value
  value="$(read_build_value "BUILD_FAILED_ACTIVE_SOURCES" 2>/dev/null || true)"
  if [ -n "${value:-}" ]; then
    echo "$value"
    return 0
  fi
  # 兼容历史 build.env
  read_build_value "BUILD_FAILED_SOURCES" 2>/dev/null || true
}

status_build_last_status() {
  read_build_value "BUILD_LAST_STATUS" 2>/dev/null || true
}

status_build_last_time() {
  read_build_value "BUILD_LAST_TIME" 2>/dev/null || true
}

status_runtime_last_active_switch_from() {
  read_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_FROM" 2>/dev/null || true
}

status_runtime_last_active_switch_to() {
  read_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_TO" 2>/dev/null || true
}

status_runtime_last_active_switch_time() {
  read_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_TIME" 2>/dev/null || true
}

status_runtime_last_build_block_reason() {
  read_runtime_event_value "RUNTIME_LAST_BUILD_BLOCK_REASON" 2>/dev/null || true
}

status_runtime_last_build_block_time() {
  read_runtime_event_value "RUNTIME_LAST_BUILD_BLOCK_TIME" 2>/dev/null || true
}

status_runtime_config_source() {
  read_runtime_event_value "RUNTIME_LAST_CONFIG_SOURCE" 2>/dev/null || true
}

status_runtime_config_source_time() {
  read_runtime_event_value "RUNTIME_LAST_CONFIG_SOURCE_TIME" 2>/dev/null || true
}

status_runtime_build_applied() {
  read_runtime_event_value "RUNTIME_LAST_BUILD_APPLIED" 2>/dev/null || true
}

status_runtime_build_applied_time() {
  read_runtime_event_value "RUNTIME_LAST_BUILD_APPLIED_TIME" 2>/dev/null || true
}

status_runtime_build_applied_reason() {
  read_runtime_event_value "RUNTIME_LAST_BUILD_APPLIED_REASON" 2>/dev/null || true
}

status_tun_enabled() {
  tun_enabled 2>/dev/null || echo false
}

status_tun_stack() {
  tun_stack 2>/dev/null || echo system
}

status_tun_container_mode() {
  tun_container_mode 2>/dev/null || echo unknown
}

status_tun_container_mode_text() {
  tun_container_mode_text 2>/dev/null || echo 未知
}

status_tun_kernel_support_level() {
  tun_kernel_support_level 2>/dev/null || echo unknown
}

status_tun_kernel_support_text() {
  tun_kernel_support_text 2>/dev/null || echo 未知
}

status_tun_last_verify_result() {
  read_tun_last_verify_result 2>/dev/null || true
}

status_tun_last_verify_reason() {
  read_tun_last_verify_reason 2>/dev/null || true
}

status_tun_last_verify_time() {
  read_tun_last_verify_time 2>/dev/null || true
}

status_tun_effective_status() {
  local enabled result

  enabled="$(status_tun_enabled)"

  if [ "$enabled" != "true" ]; then
    echo "off"
    return 0
  fi

  result="$(tun_effective_check 2>/dev/null || true)"
  case "${result:-unknown}" in
    ok)
      echo "effective"
      ;;
    *)
      echo "ineffective"
      ;;
  esac
}

status_tun_effective_text() {
  local s
  s="$(status_tun_effective_status)"

  case "$s" in
    effective) echo "🟢 已生效" ;;
    *) echo "🔴 未生效" ;;
  esac
}

system_state_build_status() {
  local last_status
  local block_reason

  last_status="$(status_build_last_status 2>/dev/null || true)"
  block_reason="$(status_runtime_last_build_block_reason 2>/dev/null || true)"

  if [ -n "${block_reason:-}" ]; then
    echo "blocked"
    return 0
  fi

  case "${last_status:-}" in
    success) echo "success" ;;
    failed) echo "failed" ;;
    *) echo "unknown" ;;
  esac
}

status_build_effective_status() {
  system_state_build_status 2>/dev/null || true
}

system_state_runtime_status() {
  if status_is_running; then
    if proxy_controller_reachable 2>/dev/null; then
      echo "running"
    else
      echo "degraded"
    fi
  else
    echo "stopped"
  fi
}

system_state_subscription_status() {
  local active

  active="$(active_subscription_name 2>/dev/null || true)"

  if [ -z "${active:-}" ]; then
    echo "missing"
    return 0
  fi

  if ! subscription_exists "$active"; then
    echo "invalid"
    return 0
  fi

  if ! subscription_enabled "$active"; then
    echo "disabled"
    return 0
  fi

  case "$(subscription_health_status "$active" 2>/dev/null || echo unknown)" in
    success) echo "healthy" ;;
    failed) echo "degraded" ;;
    *) echo "unknown" ;;
  esac
}

system_state_risk_level() {
  local risk

  if status_is_running 2>/dev/null && ! proxy_controller_reachable 2>/dev/null; then
    echo "high"
    return 0
  fi

  if ! runtime_config_exists 2>/dev/null; then
    echo "high"
    return 0
  fi

  risk="$(calculate_runtime_risk_level 2>/dev/null || true)"

  case "${risk:-unknown}" in
    low|medium|high|critical)
      echo "$risk"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

system_state_summary() {
  local runtime_status build_status subscription_status risk_level
  local config_source fallback_used build_applied
  local tun_enabled tun_effective tun_container_mode tun_kernel_support
  local overall

  runtime_status="$(system_state_runtime_status)"
  build_status="$(system_state_build_status)"
  subscription_status="$(system_state_subscription_status)"
  risk_level="$(system_state_risk_level)"
  config_source="$(status_runtime_config_source)"
  fallback_used="$(runtime_last_fallback_used 2>/dev/null || true)"
  build_applied="$(status_runtime_build_applied)"

  tun_enabled="$(status_tun_enabled)"
  tun_effective="$(status_tun_effective_status)"
  tun_container_mode="$(status_tun_container_mode)"
  tun_kernel_support="$(status_tun_kernel_support_level)"

  if [ "$runtime_status" = "running" ] \
    && [ "$build_status" = "success" ] \
    && [ "$subscription_status" = "healthy" ]; then
    overall="ready"
  elif [ "$runtime_status" = "stopped" ]; then
    overall="stopped"
  elif [ "$build_status" = "failed" ] || [ "$build_status" = "blocked" ] || [ "$subscription_status" = "invalid" ] || [ "$subscription_status" = "missing" ]; then
    overall="broken"
  else
    overall="degraded"
  fi

  cat <<EOF
SYSTEM_STATE=$overall
RUNTIME_STATE=$runtime_status
BUILD_STATE=$build_status
SUBSCRIPTION_STATE=$subscription_status
RISK_LEVEL=$risk_level
CONFIG_SOURCE=${config_source:-unknown}
FALLBACK_USED=${fallback_used:-false}
BUILD_APPLIED=${build_applied:-unknown}
TUN_ENABLED=${tun_enabled:-false}
TUN_EFFECTIVE=${tun_effective:-unknown}
TUN_CONTAINER_MODE=${tun_container_mode:-unknown}
TUN_KERNEL_SUPPORT=${tun_kernel_support:-unknown}
EOF
}
load_system_state() {
  eval "$(system_state_summary)"
}

system_state_connectivity_text() {
  load_system_state

  case "$SYSTEM_STATE" in
    ready)
      echo "可用（本地代理已就绪）"
      ;;
    degraded)
      if [ "$RUNTIME_STATE" = "running" ]; then
        echo "异常（内核已运行，但部分能力异常）"
      else
        echo "异常（系统处于降级状态）"
      fi
      ;;
    stopped)
      echo "未连接（代理未启动）"
      ;;
    broken)
      echo "不可用（配置或订阅异常）"
      ;;
    *)
      echo "未知"
      ;;
  esac
}

system_state_risk_text() {
  load_system_state

  case "$RISK_LEVEL" in
    low) echo "🟢 低" ;;
    medium) echo "🟡 中" ;;
    high) echo "🟠 高" ;;
    critical) echo "🔴 严重" ;;
    *) echo "⚪ 未知" ;;
  esac
}

system_state_default_action() {
  load_system_state

  case "$SYSTEM_STATE" in
    stopped)
      if [ "$SUBSCRIPTION_STATE" = "missing" ]; then
        echo "clashctl add <订阅链接>"
      else
        echo "clashon"
      fi
      ;;
    broken)
      if [ "$SUBSCRIPTION_STATE" = "missing" ]; then
        echo "clashctl add <订阅链接>"
      else
        echo "clashctl doctor"
      fi
      ;;
    degraded)
      if [ "$RUNTIME_STATE" = "degraded" ]; then
        echo "clashctl doctor"
      else
        echo "clashctl status --verbose"
      fi
      ;;
    ready)
      echo "clashctl select"
      ;;
    *)
      echo "clashctl status --verbose"
      ;;
  esac
}

system_state_problem_lines() {
  load_system_state

  case "$SYSTEM_STATE" in
    ready)
      return 0
      ;;
    stopped)
      if [ "$SUBSCRIPTION_STATE" = "missing" ]; then
        echo "• 当前没有可用订阅"
      else
        echo "• 代理内核未启动"
      fi
      ;;
    degraded)
      [ "$RUNTIME_STATE" = "degraded" ] && echo "• 代理内核已启动，但控制器不可访问"
      [ "$SUBSCRIPTION_STATE" = "degraded" ] && echo "• 当前主订阅健康异常"
      ;;
    broken)
      [ "$BUILD_STATE" = "failed" ] && echo "• 最近一次编译失败"
      [ "$SUBSCRIPTION_STATE" = "missing" ] && echo "• 当前没有主订阅"
      [ "$SUBSCRIPTION_STATE" = "invalid" ] && echo "• 当前主订阅无效"
      [ "$SUBSCRIPTION_STATE" = "disabled" ] && echo "• 当前主订阅已禁用"
      [ "$BUILD_STATE" = "blocked" ] && echo "• 最近一次编译被阻断"
      ;;
  esac
}

system_state_recommendation_lines() {
  load_system_state

  case "$SYSTEM_STATE" in
    ready)
      echo "1. clashctl select"
      echo "2. clashctl health"
      ;;
    stopped)
      if [ "$SUBSCRIPTION_STATE" = "missing" ]; then
        echo "1. clashctl add <订阅链接>"
      else
        echo "1. clashon"
        echo "2. clashctl status"
      fi
      ;;
    degraded)
      echo "1. clashctl doctor"
      echo "2. clashctl status --verbose"
      ;;
    broken)
      if [ "$SUBSCRIPTION_STATE" = "missing" ]; then
        echo "1. clashctl add <订阅链接>"
      else
        echo "1. clashctl doctor"
        echo "2. clashctl health"
      fi
      ;;
    *)
      echo "1. clashctl status --verbose"
      ;;
  esac
}

ui_box_width=47

box_text_width() {
  local text="${1:-}"

  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, unicodedata
s = sys.argv[1]
w = 0
for ch in s:
    if unicodedata.combining(ch):
        continue
    if unicodedata.category(ch)[0] == "C":
        continue
    w += 2 if unicodedata.east_asian_width(ch) in ("F", "W") else 1
print(w)' "$text" 2>/dev/null && return 0
  fi

  if command -v python >/dev/null 2>&1; then
    python -c 'import sys, unicodedata
s = sys.argv[1]
w = 0
for ch in s:
    if unicodedata.combining(ch):
        continue
    if unicodedata.category(ch)[0] == "C":
        continue
    w += 2 if unicodedata.east_asian_width(ch) in ("F", "W") else 1
print(w)' "$text" 2>/dev/null && return 0
  fi

  if command -v od >/dev/null 2>&1 && command -v tr >/dev/null 2>&1; then
    local width=0 byte skip=0

    while IFS= read -r byte; do
      [ -n "${byte:-}" ] || continue

      if [ "$skip" -gt 0 ]; then
        skip=$((skip - 1))
        continue
      fi

      if [ "$byte" -lt 32 ] || [ "$byte" -eq 127 ]; then
        continue
      elif [ "$byte" -lt 128 ]; then
        width=$((width + 1))
      elif [ "$byte" -ge 240 ]; then
        width=$((width + 2))
        skip=3
      elif [ "$byte" -ge 224 ]; then
        width=$((width + 2))
        skip=2
      elif [ "$byte" -ge 192 ]; then
        width=$((width + 1))
        skip=1
      fi
    done < <(printf '%s' "$text" | od -An -t u1 | tr -s ' ' '\n')

    echo "$width"
    return 0
  fi

  echo "${#text}"
}

compute_box_width() {
  local max_len=0
  local line line_width

  for line in "$@"; do
    line_width="$(box_text_width "$line")"
    case "${line_width:-}" in
      ''|*[!0-9]*) line_width="${#line}" ;;
    esac
    [ "$line_width" -gt "$max_len" ] && max_len="$line_width"
  done

  ui_box_width=$((max_len + 8))
}

box_border_top() {
  local i
  printf "╔"
  for ((i = 0; i < ui_box_width - 2; i++)); do
    printf "═"
  done
  printf "╗\n"
}

box_border_mid() {
  local i
  printf "╠"
  for ((i = 0; i < ui_box_width - 2; i++)); do
    printf "═"
  done
  printf "╣\n"
}

box_border_bottom() {
  local i
  printf "╚"
  for ((i = 0; i < ui_box_width - 2; i++)); do
    printf "═"
  done
  printf "╝\n"
}

box_center_line() {
  local text="$1"
  local inner_width=$((ui_box_width - 2))
  local text_len
  text_len="$(box_text_width "$text")"
  local left_pad=$(( (inner_width - text_len) / 2 ))
  local right_pad=$(( inner_width - left_pad - text_len ))

  printf "║%*s%s%*s║\n" "$left_pad" "" "$text" "$right_pad" ""
}

box_empty() {
  printf "║%*s║\n" $((ui_box_width-2)) ""
}

box_section_line() {
  local text="$1"
  local inner_width=$((ui_box_width - 2))
  local content="    $text"
  local content_len
  content_len="$(box_text_width "$content")"
  local right_pad=$((inner_width - content_len))

  [ "$right_pad" -lt 0 ] && right_pad=0
  printf "║%s%*s║\n" "$content" "$right_pad" ""
}

box_title_line() {
  box_center_line "$1"
}

status_is_running() {
  local backend pid

  backend="$(runtime_backend)"

  case "$backend" in
    systemd)
      systemctl is-active --quiet "$(service_unit_name)"
      ;;
    systemd-user)
      systemctl --user is-active --quiet "$(service_unit_name)"
      ;;
    script)
      if [ -f "$RUNTIME_DIR/mihomo.pid" ]; then
        pid="$(cat "$RUNTIME_DIR/mihomo.pid" 2>/dev/null || true)"
        [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null
      else
        return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

apply_runtime_change_after_config_mutation() {
  if status_is_running; then
    info "检测到代理正在运行，正在自动重启以应用新配置"
    service_restart
    success "新配置已自动重启生效"
  else
    info "新配置已写入，当前代理未运行，下次启动自动生效"
  fi
}

print_config_regen_feedback() {
  echo
  echo "🧩 配置已重新生成"
  echo
}

print_config_apply_feedback() {
  local build_status build_applied config_source next_action

  build_status="$(status_build_effective_status 2>/dev/null || true)"
  build_applied="$(status_runtime_build_applied 2>/dev/null || true)"
  config_source="$(status_runtime_config_source 2>/dev/null || true)"
  next_action="$(system_state_default_action 2>/dev/null || echo 'clashctl status')"

  echo
  echo "🧩 配置变更已处理"

  case "${build_status:-unknown}" in
    success)
      echo "🟢 构建结果：success"
      ;;
    failed)
      echo "🔴 构建结果：failed"
      ;;
    blocked)
      echo "⚠️ 构建结果：blocked"
      ;;
    *)
      echo "⚪ 构建结果：unknown"
      ;;
  esac

  case "${build_applied:-unknown}" in
    true)
      echo "🟢 是否应用：true"
      ;;
    false)
      echo "⚠️ 是否应用：false"
      ;;
    *)
      echo "⚪ 是否应用：unknown"
      ;;
  esac

  echo "🧩 配置来源：${config_source:-unknown}"
  echo "👉 下一步：$next_action"
  echo
}

main_feedback_runtime_state() {
  if status_is_running; then
    ui_kv "🟢" "运行状态" "已运行"
  else
    ui_kv "🔴" "运行状态" "未运行"
  fi
}

main_feedback_build_mode() {
  ui_kv "🧩" "编译模式" "active-only"
}

main_feedback_active_subscription() {
  local active
  active="$(active_subscription_name 2>/dev/null || true)"
  if [ -n "${active:-}" ]; then
    ui_kv "📡" "当前订阅" "$active"
  fi
}

main_feedback_subscription_selected_state() {
  local name="$1"
  local active

  [ -n "${name:-}" ] || return 0

  active="$(active_subscription_name 2>/dev/null || true)"

  if [ "$name" = "$active" ]; then
    echo "✅ 参与状态：当前主订阅"
  else
    echo "📦 参与状态：已保存，但当前未启用"
  fi
}

print_add_feedback() {
  local name="$1"
  local url="${2:-}"

  echo "✔ 已添加订阅：$name"
  [ -n "${url:-}" ] && echo "📡 URL：$url"
}

print_use_context() {
  local active recommended

  active="$(active_subscription_name 2>/dev/null || true)"
  recommended="$(recommended_subscription_name 2>/dev/null || true)"

  ui_title "🔁 切换当前订阅"

  if [ -n "${active:-}" ]; then
    ui_kv "📡" "当前主订阅" "$active"
  else
    ui_kv "📡" "当前主订阅" "未设置"
  fi

  if [ -n "${recommended:-}" ] && [ "${recommended:-}" != "${active:-}" ]; then
    ui_kv "💡" "推荐订阅" "$recommended"
  else
    ui_kv "💡" "推荐订阅" "保持当前"
  fi

  ui_blank
}

print_use_feedback() {
  local name="$1" health fail_count enabled_text

  ui_title "🔁 订阅切换完成"

  if [ -n "${name:-}" ]; then
    if subscription_enabled "$name"; then
      enabled_text="enabled"
    else
      enabled_text="disabled"
    fi

    health="$(subscription_health_status "$name" 2>/dev/null || echo "unknown")"
    fail_count="$(subscription_fail_count "$name" 2>/dev/null || echo "0")"

    ui_kv "📡" "当前主订阅" "$name"
    ui_kv "❤️" "订阅状态" "$enabled_text / $health / fail=$fail_count"
  fi

  main_feedback_build_mode
  main_feedback_runtime_state
  ui_next "clashctl select  选择节点"
  ui_blank
}

print_select_context() {
  local current_proxy

  ui_title "🚀 切换节点"

  if ! status_is_running; then
    ui_kv "🔴" "代理状态" "未运行"
    ui_next "clashon"
    ui_blank
    return 1
  fi

  if ! proxy_controller_reachable 2>/dev/null; then
    ui_kv "🔴" "当前节点" "控制器不可访问"
    ui_next "clashctl doctor"
    ui_blank
    return 1
  fi

  if [ "$(proxy_group_count 2>/dev/null || echo 0)" -le 0 ]; then
    ui_kv "🔴" "当前节点" "暂无可切换策略组"
    ui_next "clashctl status --verbose"
    ui_blank
    return 1
  fi

  current_proxy="$(status_current_proxy_brief 2>/dev/null || true)"
  if [ -n "${current_proxy:-}" ]; then
    ui_kv "🚀" "当前节点" "$current_proxy"
  else
    ui_kv "🚀" "当前节点" "未知"
  fi

  ui_next "请选择要切换的策略组和节点"
  ui_blank
  return 0
}

print_select_feedback() {
  local group="$1"
  local current

  current="$(proxy_group_current "$group" 2>/dev/null || true)"

  ui_title "🚀 节点切换完成"

  if [ -n "${group:-}" ]; then
    ui_kv "📦" "已切换策略组" "$group"
  fi

  if [ -n "${current:-}" ]; then
    ui_kv "🚀" "当前节点" "$current"
  fi

  main_feedback_runtime_state
  ui_next "clashctl status"
  ui_blank
}

print_sub_enable_feedback() {
  local name="$1"
  local health fail_count

  health="$(subscription_health_status "$name" 2>/dev/null || echo "unknown")"
  fail_count="$(subscription_fail_count "$name" 2>/dev/null || echo "0")"

  ui_title "📡 订阅已启用"
  ui_kv "📡" "订阅名称" "$name"
  ui_kv "❤️" "当前健康" "$health / fail=$fail_count"
  main_feedback_build_mode
  main_feedback_runtime_state
  ui_next "clashctl health ${name}"
  ui_blank
}

print_sub_disable_feedback() {
  local name="$1"
  local active

  active="$(active_subscription_name 2>/dev/null || true)"

  ui_title "📡 订阅已禁用"
  ui_kv "📡" "订阅名称" "$name"

  if [ "$name" = "$active" ]; then
    ui_kv "⚠️" "当前主订阅" "已被禁用"
    ui_next "clashctl use"
  else
    ui_kv "🧩" "当前主订阅" "${active:-未设置}"
    ui_next "clashctl status"
  fi

  main_feedback_build_mode
  main_feedback_runtime_state
  ui_blank
}

print_sub_rename_feedback() {
  local old_name="$1"
  local new_name="$2"

  ui_title "📡 订阅已重命名"
  ui_kv "📡" "原名称" "$old_name"
  ui_kv "📡" "新名称" "$new_name"
  main_feedback_build_mode
  main_feedback_runtime_state
  ui_next "clashctl ls"
  ui_blank
}

print_sub_remove_feedback() {
  local name="$1"
  local active

  active="$(active_subscription_name 2>/dev/null || true)"

  ui_title "📡 订阅已删除"
  ui_kv "📡" "已删除" "$name"
  ui_kv "📡" "当前主订阅" "${active:-未设置}"
  main_feedback_build_mode
  main_feedback_runtime_state
  ui_next "clashctl ls"
  ui_blank
}

print_config_kernel_feedback() {
  local kernel="$1"

  ui_title "🚀 运行内核已切换"
  ui_kv "🚀" "当前内核" "$kernel"
  main_feedback_runtime_state
  ui_next "clashctl status"
  ui_blank
}

print_tun_container_gate_feedback() {
  local mode="$1"
  local reason="${2:-}"

  echo
  ui_title "🧪 Tun 裁决"

  ui_kv "🚀" "当前内核" "$(runtime_kernel_type 2>/dev/null || echo unknown)"
  ui_kv "🧩" "Tun 支持等级" "$(tun_kernel_support_text 2>/dev/null || echo 未知)"

  case "$mode" in
    host)
      ui_kv "�" "环境模式" "主机环境"
      ui_kv "🟢" "容器裁决" "允许正常开启"
      ;;
    container-safe)
      ui_kv "�" "环境模式" "容器环境"
      ui_kv "⚠️" "容器裁决" "允许开启，但属于保守通过"
      [ -n "${reason:-}" ] && ui_kv "⚠️" "注意事项" "$reason"
      ;;
    container-risky)
      ui_kv "�" "环境模式" "容器环境"
      ui_kv "🔴" "容器裁决" "高风险，已阻断开启"
      [ -n "${reason:-}" ] && ui_kv "🔴" "阻断原因" "$reason"
      ui_next "clashctl tun doctor"
      ui_blank
      ;;
    *)
      ui_kv "⚪" "容器裁决" "未知"
      [ -n "${reason:-}" ] && ui_kv "⚠️" "原因" "$reason"
      ;;
  esac

  if ! tun_kernel_is_recommended 2>/dev/null; then
    ui_warn "$(tun_kernel_support_reason 2>/dev/null || echo '当前内核不适合作为 Tun 主支持内核')"
    ui_next "如需最稳妥 Tun 体验，先执行：clashctl config kernel mihomo"
  fi

  if [ "$mode" != "container-risky" ]; then
    ui_next "clashctl tun doctor"
    ui_blank
  fi
}

print_tun_on_feedback() {
  local verify_result stack auto_route

  verify_result="$1"
  stack="$(runtime_config_tun_stack 2>/dev/null || tun_stack 2>/dev/null || echo unknown)"
  auto_route="$(runtime_config_tun_auto_route 2>/dev/null || echo false)"

  echo
  ui_title "🧪 Tun 模式已处理"
  ui_kv "🧪" "目标状态" "开启"
  ui_kv "⚙️ " "Tun stack" "${stack:-unknown}"
  ui_kv "🧭" "auto-route" "${auto_route:-false}"

  case "$verify_result" in
    ok)
      ui_kv "🟢" "验证结果" "已生效"
      ;;
    *)
      ui_kv "🔴" "验证结果" "未生效"
      ;;
  esac

  if [ "$(container_env_type)" != "host" ]; then
    ui_warn "当前处于容器环境，Tun 可能受宿主机权限或设备映射限制"
  fi

  ui_next "clashctl tun doctor"
  ui_blank
}

print_tun_off_feedback() {
  local verify_result route_dev

  verify_result="$1"
  route_dev="$(default_route_dev 2>/dev/null || true)"

  echo
  ui_title "🧪 Tun 模式已处理"
  ui_kv "🧪" "目标状态" "关闭"

  case "$verify_result" in
    ok)
      ui_kv "🟢" "验证结果" "Tun 已关闭并完成回滚检查"
      [ -n "${route_dev:-}" ] && ui_kv "🌐" "当前默认路由设备" "$route_dev"
      ;;
    *)
      ui_kv "⚠️" "验证结果" "Tun 关闭后仍存在残留或运行异常"
      ui_kv "⚠️" "原因" "$verify_result"
      ;;
  esac

  ui_next "clashctl tun doctor"
  ui_blank
}

status_subscription_health_summary() {
  local active health fail_count auto_disabled

  active="$(active_subscription_name 2>/dev/null || true)"
  [ -n "${active:-}" ] || return 0

  health="$(subscription_health_status "$active" 2>/dev/null || echo "unknown")"
  fail_count="$(subscription_fail_count "$active" 2>/dev/null || echo "0")"

  if subscription_auto_disabled "$active"; then
    auto_disabled="yes"
  else
    auto_disabled="no"
  fi

  echo "❤️ 健康状态：$health"
  echo "⚠️ 失败次数：$fail_count"
  echo "⚠️ 阈值命中：$auto_disabled"

  if [ -n "$(subscription_last_success "$active" 2>/dev/null || true)" ]; then
    echo "🕒 最近成功：$(subscription_last_success "$active" 2>/dev/null || true)"
  fi

  if [ -n "$(subscription_last_failure "$active" 2>/dev/null || true)" ]; then
    echo "🕒 最近失败：$(subscription_last_failure "$active" 2>/dev/null || true)"
  fi
}

status_proxy_summary_lines() {
  print_proxy_groups_status 2>/dev/null | head -n 5 || true
}

status_user_risk_text() {
  system_state_risk_text
}

status_risk_reason_lines() {
  local build_status active controller_ok
  local last_risk_name last_risk_reason last_risk_fail_count last_risk_threshold
  local build_block_reason build_block_time
  local fallback_used fallback_time fallback_reason
  local tun_enabled tun_effective tun_container_mode tun_kernel_support tun_verify_reason

  build_status="$(status_build_last_status 2>/dev/null || true)"
  active="$(active_subscription_name 2>/dev/null || true)"
  controller_ok="false"
  proxy_controller_reachable 2>/dev/null && controller_ok="true"

  build_block_reason="$(status_runtime_last_build_block_reason 2>/dev/null || true)"
  build_block_time="$(status_runtime_last_build_block_time 2>/dev/null || true)"
  fallback_used="$(runtime_last_fallback_used 2>/dev/null || true)"
  fallback_time="$(runtime_last_fallback_time 2>/dev/null || true)"
  fallback_reason="$(runtime_last_fallback_reason 2>/dev/null || true)"
  tun_enabled="$(status_tun_enabled 2>/dev/null || echo false)"
  tun_effective="$(status_tun_effective_status 2>/dev/null || echo unknown)"
  tun_container_mode="$(status_tun_container_mode 2>/dev/null || echo unknown)"
  tun_kernel_support="$(status_tun_kernel_support_level 2>/dev/null || echo unknown)"
  tun_verify_reason="$(status_tun_last_verify_reason 2>/dev/null || true)"

  if ! status_is_running; then
    echo "• 代理内核未启动"
  fi

  if [ "$controller_ok" = "false" ] && status_is_running; then
    echo "• 控制器不可访问"
  fi

  if [ "${build_status:-}" = "failed" ]; then
    echo "• 最近一次编译失败"
  fi

  if [ -n "${build_block_reason:-}" ]; then
    if [ -n "${build_block_time:-}" ]; then
      echo "• 最近一次编译被阻断：${build_block_reason} @ ${build_block_time}"
    else
      echo "• 最近一次编译被阻断：${build_block_reason}"
    fi
  fi

  if [ "${fallback_used:-false}" = "true" ]; then
    if [ -n "${fallback_time:-}" ]; then
      echo "• 最近一次启动触发配置回退：${fallback_time}"
    else
      echo "• 最近一次启动触发配置回退"
    fi
    [ -n "${fallback_reason:-}" ] && echo "• 回退原因：${fallback_reason}"
  fi

  if [ -n "${active:-}" ] && ! active_subscription_enabled 2>/dev/null; then
    echo "• 当前主订阅已禁用或不可用"
  fi

  last_risk_name="$(read_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_NAME" 2>/dev/null || true)"
  last_risk_reason="$(read_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_REASON" 2>/dev/null || true)"
  last_risk_fail_count="$(read_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_FAIL_COUNT" 2>/dev/null || true)"
  last_risk_threshold="$(read_runtime_event_value "RUNTIME_LAST_SUBSCRIPTION_RISK_THRESHOLD" 2>/dev/null || true)"

  if [ -n "${last_risk_name:-}" ] && [ "${last_risk_reason:-}" = "fail-threshold-reached" ]; then
    echo "• 订阅 ${last_risk_name} 连续失败 ${last_risk_fail_count:-?} 次（阈值 ${last_risk_threshold:-?}）"
  fi

  if [ "$tun_enabled" = "true" ] && [ "$tun_effective" != "effective" ]; then
    echo "• Tun 未生效"
  fi

  if [ "$tun_container_mode" = "container-risky" ]; then
    echo "• 当前 Tun 运行环境属于高风险容器场景"
  fi

  if [ "$tun_enabled" = "true" ] && [ "$tun_kernel_support" = "limited" ]; then
    echo "• 当前 Tun 运行在 clash 内核上，仅按降级支持处理"
  fi
}

status_recommendation_lines() {
  system_state_recommendation_lines
}

status_current_proxy_brief() {
  local default_group default_current fallback_group fallback_current

  if ! status_is_running; then
    echo "未启动"
    return 0
  fi

  if ! proxy_controller_reachable 2>/dev/null; then
    echo "控制器不可访问"
    return 0
  fi

  default_group="$(default_proxy_group_name 2>/dev/null || true)"
  default_current="$(default_proxy_group_current 2>/dev/null || true)"

  if [ -n "${default_group:-}" ] && [ -n "${default_current:-}" ]; then
    echo "${default_group} -> ${default_current}"
    return 0
  fi

  fallback_group="$(proxy_group_list 2>/dev/null | sed -n '1p')"
  if [ -n "${fallback_group:-}" ]; then
    fallback_current="$(proxy_group_current "$fallback_group" 2>/dev/null || true)"
    if [ -n "${fallback_current:-}" ]; then
      echo "${fallback_group} -> ${fallback_current}"
      return 0
    fi
  fi

  echo "暂无可切换策略组"
}

system_proxy_supported_state() {
  if system_proxy_supported; then
    echo "true"
  else
    echo "false"
  fi
}

connectivity_issue_code() {
  local active group_count

  if ! status_is_running; then
    echo "runtime_stopped"
    return 0
  fi

  if ! proxy_controller_reachable 2>/dev/null; then
    echo "controller_unreachable"
    return 0
  fi

  case "$(system_state_build_status 2>/dev/null || echo unknown)" in
    failed|blocked)
      echo "config_invalid"
      return 0
      ;;
  esac

  case "$(system_state_subscription_status 2>/dev/null || echo unknown)" in
    missing|invalid|disabled|degraded)
      echo "subscription_unhealthy"
      return 0
      ;;
  esac

  group_count="$(proxy_group_count 2>/dev/null || echo 0)"
  case "${group_count:-0}" in
    ''|*[!0-9]*) group_count=0 ;;
  esac

  if [ "$group_count" -le 0 ]; then
    echo "proxy_control_broken"
    return 0
  fi

  if ! system_proxy_supported; then
    echo "system_proxy_unsupported"
    return 0
  fi

  if [ "$(system_proxy_status 2>/dev/null || echo off)" != "on" ]; then
    echo "system_proxy_off"
    return 0
  fi

  if ! system_proxy_matches_runtime; then
    echo "system_proxy_mismatch"
    return 0
  fi

  echo "ok"
}

connectivity_issue_text() {
  case "$(connectivity_issue_code)" in
    ok) echo "可用（代理链路已闭环）" ;;
    runtime_stopped) echo "不可用（代理内核未启动）" ;;
    controller_unreachable) echo "异常（内核已运行，但控制器不可访问）" ;;
    config_invalid) echo "异常（当前运行配置不可用）" ;;
    subscription_unhealthy) echo "异常（当前主订阅不可用）" ;;
    proxy_control_broken) echo "异常（当前无可用策略组或节点控制面异常）" ;;
    system_proxy_unsupported) echo "未接管（当前环境不支持系统代理）" ;;
    system_proxy_off) echo "未接管（系统代理未开启）" ;;
    system_proxy_mismatch) echo "异常（系统代理端口与运行时不一致）" ;;
    *) echo "未知" ;;
  esac
}

connectivity_next_action() {
  case "$(connectivity_issue_code)" in
    ok)
      echo "clashctl select"
      ;;
    runtime_stopped)
      echo "clashon"
      ;;
    controller_unreachable)
      echo "clashctl doctor"
      ;;
    config_invalid)
      echo "clashctl doctor"
      ;;
    subscription_unhealthy)
      echo "clashctl health"
      ;;
    proxy_control_broken)
      echo "clashctl status --verbose"
      ;;
    system_proxy_unsupported)
      echo "clashctl doctor"
      ;;
    system_proxy_off)
      echo "clashon"
      ;;
    system_proxy_mismatch)
      echo "clashoff && clashon"
      ;;
    *)
      echo "clashctl doctor"
      ;;
  esac
}

connectivity_evidence_lines() {
  local runtime_running controller_ok build_status subscription_status
  local group_count expected_proxy actual_proxy active config_source
  local system_proxy_state system_proxy_supported_text

  if status_is_running; then
    runtime_running="true"
  else
    runtime_running="false"
  fi

  if proxy_controller_reachable 2>/dev/null; then
    controller_ok="true"
  else
    controller_ok="false"
  fi

  build_status="$(system_state_build_status 2>/dev/null || echo unknown)"
  subscription_status="$(system_state_subscription_status 2>/dev/null || echo unknown)"
  group_count="$(proxy_group_count 2>/dev/null || echo 0)"
  active="$(active_subscription_name 2>/dev/null || true)"
  config_source="$(status_runtime_config_source 2>/dev/null || true)"
  expected_proxy="$(proxy_http_url 2>/dev/null || true)"
  actual_proxy="$(system_proxy_http_value 2>/dev/null || true)"
  system_proxy_state="$(system_proxy_status 2>/dev/null || echo off)"
  system_proxy_supported_text="$(system_proxy_supported_state)"

  echo "• runtime_running = ${runtime_running:-false}"
  echo "• controller_reachable = ${controller_ok:-false}"
  echo "• build_status = ${build_status:-unknown}"
  echo "• subscription_status = ${subscription_status:-unknown}"
  echo "• active_subscription = ${active:-unset}"
  echo "• config_source = ${config_source:-unknown}"
  echo "• proxy_group_count = ${group_count:-0}"

  echo "• system_proxy_supported = ${system_proxy_supported_text:-false}"
  echo "• system_proxy_enabled = ${system_proxy_state:-off}"
  [ -n "${actual_proxy:-}" ] && echo "• system_proxy_http = ${actual_proxy}"

  if [ -n "${expected_proxy:-}" ]; then
    echo "• runtime_proxy_http = $expected_proxy"
  fi
  echo "• tun_enabled = $(status_tun_enabled 2>/dev/null || echo false)"
  echo "• tun_effective = $(status_tun_effective_status 2>/dev/null || echo unknown)"
  echo "• tun_container_mode = $(status_tun_container_mode 2>/dev/null || echo unknown)"
  echo "• tun_kernel_support = $(status_tun_kernel_support_level 2>/dev/null || echo unknown)"
}

status_runtime_backend_text() {
  local backend

  backend="$(install_plan_backend 2>/dev/null || true)"
  [ -n "${backend:-}" ] || backend="$(runtime_backend 2>/dev/null || true)"

  case "${backend:-unknown}" in
    systemd) echo "systemd" ;;
    systemd-user) echo "systemd-user" ;;
    script) echo "script" ;;
    *) echo "unknown" ;;
  esac
}

status_runtime_backend_reason_text() {
  local backend container_type

  backend="$(runtime_backend 2>/dev/null || echo unknown)"
  container_type="$(install_env_container 2>/dev/null || echo unknown)"

  case "$backend" in
    systemd)
      echo "root + systemd 可用"
      ;;
    systemd-user)
      echo "普通用户 + user systemd 可用"
      ;;
    script)
      if [ "$container_type" != "host" ] && [ -n "${container_type:-}" ]; then
        echo "容器环境默认回退 script"
      else
        echo "systemd 不可用，自动回退 script"
      fi
      ;;
    *)
      echo "未知"
      ;;
  esac
}

status_container_mode_text() {
  local container_mode env_container

  container_mode="$(install_plan_container_mode 2>/dev/null || true)"
  env_container="$(install_env_container 2>/dev/null || true)"

  if [ "${container_mode:-}" = "true" ]; then
    echo "容器兼容模式"
    return 0
  fi

  case "${env_container:-host}" in
    host) echo "主机模式" ;;
    "") echo "未知" ;;
    *) echo "容器环境（未启用兼容模式）" ;;
  esac
}

status_install_verify_brief() {
  local runtime_ready controller_ready
  local live_runtime="false"
  local live_controller="false"

  runtime_ready="$(install_verify_runtime_ready 2>/dev/null || true)"
  controller_ready="$(install_verify_controller_ready 2>/dev/null || true)"

  if status_is_running 2>/dev/null; then
    live_runtime="true"
  fi

  if proxy_controller_reachable 2>/dev/null; then
    live_controller="true"
  fi

  if [ "$live_runtime" = "true" ] && [ "$live_controller" = "true" ]; then
    echo "安装验证通过"
    return 0
  fi

  if [ "$runtime_ready" = "true" ] && [ "$controller_ready" = "true" ]; then
    echo "安装验证通过"
    return 0
  fi

  if [ "$live_runtime" = "true" ] && [ "$live_controller" != "true" ]; then
    echo "运行已就绪，控制器未就绪"
    return 0
  fi

  if [ "$runtime_ready" = "true" ] && [ "$controller_ready" != "true" ]; then
    echo "运行已就绪，控制器未就绪"
    return 0
  fi

  if [ "$live_runtime" != "true" ] && [ "$live_controller" = "true" ]; then
    echo "控制器异常记录"
    return 0
  fi

  if [ "$runtime_ready" != "true" ] && [ "$controller_ready" = "true" ]; then
    echo "控制器异常记录"
    return 0
  fi

  echo "安装验证未完成"
}

status_port_adjustment_brief() {
  local changed=0

  [ "$(install_plan_mixed_port_auto_changed 2>/dev/null || echo false)" = "true" ] && changed=1
  [ "$(install_plan_controller_auto_changed 2>/dev/null || echo false)" = "true" ] && changed=1
  [ "$(install_plan_dns_port_auto_changed 2>/dev/null || echo false)" = "true" ] && changed=1

  if [ "$changed" -eq 1 ]; then
    echo "安装期发生过端口自动避让"
  else
    echo "安装期端口保持默认"
  fi
}

print_status_summary_compact() {
  local profile mixed_port controller controller_lan controller_public
  local running_text user_connectivity user_risk current_proxy_brief system_proxy_text
  local current_active dashboard_text dashboard_source_text dashboard_policy_text secret_text
  local tun_text

  profile="$(show_active_profile 2>/dev/null || true)"
  [ -n "${profile:-}" ] || profile="default"

  mixed_port="$(status_read_mixed_port 2>/dev/null || true)"
  controller="$(status_read_controller 2>/dev/null || true)"
  controller_lan="$(status_read_controller_lan 2>/dev/null || true)"
  controller_public="$(status_read_controller_public 2>/dev/null || true)"
  current_active="$(active_subscription_name 2>/dev/null || true)"
  tun_text="$(status_tun_effective_text)"

  if status_is_running; then
    running_text="🟢 已开启"
  else
    running_text="🔴 未开启"
  fi

  user_connectivity="$(connectivity_issue_text)"
  user_risk="$(status_user_risk_text)"
  current_proxy_brief="$(status_current_proxy_brief)"
  if system_proxy_supported; then
    system_proxy_text="$(system_proxy_status 2>/dev/null || echo off)"
  else
    system_proxy_text="unsupported"
  fi
  if [ -f "$(runtime_dashboard_dir)/index.html" ]; then
    dashboard_text="已部署"
  else
    dashboard_text="未部署"
  fi
  dashboard_source_text="$(read_runtime_value "DASHBOARD_ASSET_SOURCE" 2>/dev/null || echo none)"
  case "${dashboard_source_text:-none}" in
    dir|zip|none) ;;
    *) dashboard_source_text="none" ;;
  esac
  if [ "$dashboard_source_text" = "none" ]; then
    dashboard_policy_text="默认策略：Dashboard 资产无效将阻断 install/update"
  else
    dashboard_policy_text="默认策略：Dashboard 资产需保持可部署"
  fi
  if [ -n "$(read_env_value "CLASH_CONTROLLER_SECRET" 2>/dev/null || true)" ]; then
    secret_text="已设置"
  else
    secret_text="未设置"
  fi

  echo
  echo "😼 Clash 状态总览"
  echo

  echo "【当前结果】"
  echo "🟢 代理状态：$running_text"
  echo "🌐 当前可用性：$user_connectivity"
  echo "📡 当前订阅：${current_active:-未设置}"
  echo "🚀 当前节点：$current_proxy_brief"
  echo "⚠️ 当前风险：$user_risk"
  echo "👉 clashctl select  切换节点"
  echo

  echo "【核心入口】"
  echo "⚙️ Profile：$profile"
  echo "⚙️ 运行后端：$(status_runtime_backend_text)"
  echo "🧪 环境模式：$(status_container_mode_text)"
  echo "🧪 Tun 状态：${tun_text:-未知}"
  echo "🧭 系统代理状态：${system_proxy_text}"
  echo "🧩 Dashboard：${dashboard_text}（来源：${dashboard_source_text}）"
  echo "🧩 Dashboard 策略：${dashboard_policy_text}"
  echo "🔐 控制器密钥：${secret_text}"

  if [ -n "${mixed_port:-}" ] && [ "$mixed_port" != "null" ]; then
    echo "🌐 本地代理：http://127.0.0.1:${mixed_port}"
  else
    echo "🌐 本地代理：未知"
  fi

  if [ -n "${controller:-}" ] && [ "$controller" != "null" ]; then
    echo "� 控制台：http://${controller}/ui"
    [ -n "${controller_lan:-}" ] && echo "🏠 局域网：http://${controller_lan}/ui"
    if [ -n "${controller_public:-}" ]; then
      echo "🌍 公网：http://${controller_public}/ui"
    else
      echo "🌍 公网：需公网 IP / 端口映射后可访问"
    fi
  else
    echo "� 控制台：未知"
  fi

  echo
  echo "🧩 安装验证：$(status_install_verify_brief)"
  echo "💡 更多细节：clashctl status --verbose"
  echo
}

print_status_summary_verbose() {
  local running_text profile mixed_port controller controller_lan controller_public
  local current_active build_active_sources build_failed_active_sources build_status build_time
  local build_block_reason build_block_time
  local last_switch_from last_switch_to last_switch_time
  local controller_ok current_proxy_lines
  local user_connectivity user_risk current_proxy_brief
  local fallback_used fallback_time fallback_reason
  local config_source config_source_time build_applied build_applied_time build_applied_reason
  local install_backend_text install_container_text install_verify_text port_adjustment_text
  local tun_enabled tun_effective tun_stack tun_container_text tun_kernel_text tun_verify_result tun_verify_reason tun_verify_time
  local system_proxy_text dashboard_text dashboard_source_text dashboard_policy_text secret_text

  profile="$(show_active_profile 2>/dev/null || true)"
  [ -n "${profile:-}" ] || profile="default"

  mixed_port="$(status_read_mixed_port 2>/dev/null || true)"
  controller="$(status_read_controller 2>/dev/null || true)"
  controller_lan="$(status_read_controller_lan 2>/dev/null || true)"
  controller_public="$(status_read_controller_public 2>/dev/null || true)"


  current_active="$(active_subscription_name 2>/dev/null || true)"
  build_active_sources="$(status_build_active_sources)"
  build_failed_active_sources="$(status_build_failed_active_sources)"
  build_status="$(status_build_last_status)"
  build_time="$(status_build_last_time)"

  build_block_reason="$(status_runtime_last_build_block_reason)"
  build_block_time="$(status_runtime_last_build_block_time)"
  last_switch_from="$(status_runtime_last_active_switch_from)"
  last_switch_to="$(status_runtime_last_active_switch_to)"
  last_switch_time="$(status_runtime_last_active_switch_time)"

  fallback_used="$(runtime_last_fallback_used 2>/dev/null || true)"
  fallback_time="$(runtime_last_fallback_time 2>/dev/null || true)"
  fallback_reason="$(runtime_last_fallback_reason 2>/dev/null || true)"
  config_source="$(status_runtime_config_source 2>/dev/null || true)"
  config_source_time="$(status_runtime_config_source_time 2>/dev/null || true)"
  build_applied="$(status_runtime_build_applied 2>/dev/null || true)"
  build_applied_time="$(status_runtime_build_applied_time 2>/dev/null || true)"
  build_applied_reason="$(status_runtime_build_applied_reason 2>/dev/null || true)"

  if status_is_running; then
    running_text="🟢 已开启"
  else
    running_text="🔴 未开启"
  fi

  controller_ok="false"
  current_proxy_lines=""
  if status_is_running && proxy_controller_reachable 2>/dev/null; then
    controller_ok="true"
    current_proxy_lines="$(status_proxy_summary_lines)"
  fi

  user_connectivity="$(connectivity_issue_text)"
  user_risk="$(status_user_risk_text)"
  current_proxy_brief="$(status_current_proxy_brief)"
  install_backend_text="$(status_runtime_backend_text)"
  install_container_text="$(status_container_mode_text)"
  install_verify_text="$(status_install_verify_brief)"
  port_adjustment_text="$(status_port_adjustment_brief)"

  tun_enabled="$(status_tun_enabled 2>/dev/null || echo false)"
  tun_effective="$(status_tun_effective_text 2>/dev/null || echo 未知)"
  tun_stack="$(status_tun_stack 2>/dev/null || echo system)"
  tun_container_text="$(status_tun_container_mode_text 2>/dev/null || echo 未知)"
  tun_kernel_text="$(status_tun_kernel_support_text 2>/dev/null || echo 未知)"
  tun_verify_result="$(status_tun_last_verify_result 2>/dev/null || true)"
  tun_verify_reason="$(status_tun_last_verify_reason 2>/dev/null || true)"
  tun_verify_time="$(status_tun_last_verify_time 2>/dev/null || true)"
  if system_proxy_supported; then
    system_proxy_text="$(system_proxy_status 2>/dev/null || echo off)"
  else
    system_proxy_text="unsupported"
  fi
  if [ -f "$(runtime_dashboard_dir)/index.html" ]; then
    dashboard_text="已部署"
  else
    dashboard_text="未部署"
  fi
  dashboard_source_text="$(read_runtime_value "DASHBOARD_ASSET_SOURCE" 2>/dev/null || echo none)"
  case "${dashboard_source_text:-none}" in
    dir|zip|none) ;;
    *) dashboard_source_text="none" ;;
  esac
  if [ "$dashboard_source_text" = "none" ]; then
    dashboard_policy_text="默认策略：Dashboard 资产无效将阻断 install/update"
  else
    dashboard_policy_text="默认策略：Dashboard 资产需保持可部署"
  fi
  if [ -n "$(read_env_value "CLASH_CONTROLLER_SECRET" 2>/dev/null || true)" ]; then
    secret_text="已设置"
  else
    secret_text="未设置"
  fi

  echo
  echo "😼 Clash 状态总览"
  echo

  echo "【当前结果】"
  echo "🟢 代理状态：$running_text"
  echo "🌐 当前可用性：$user_connectivity"
  echo "📡 当前订阅：${current_active:-未设置}"
  echo "🚀 当前节点：$current_proxy_brief"
  echo "⚠️ 当前风险：$user_risk"
  echo "👉 clashctl select  切换节点"
  echo

  echo "【核心入口】"
  echo "⚙️ Profile：$profile"
  if [ -n "${mixed_port:-}" ] && [ "$mixed_port" != "null" ]; then
    echo "🌐 本地代理：http://127.0.0.1:${mixed_port}"
  else
    echo "🌐 本地代理：未知"
  fi

  if [ -n "${controller:-}" ] && [ "$controller" != "null" ]; then
    echo "� 控制台：http://${controller}/ui"
    [ -n "${controller_lan:-}" ] && echo "🏠 局域网：http://${controller_lan}/ui"
    if [ -n "${controller_public:-}" ]; then
      echo "🌍 公网：http://${controller_public}/ui"
    else
      echo "🌍 公网：需公网 IP / 端口映射后可访问"
    fi
  else
    echo "� 控制台：未知"
  fi
  echo

  echo "【安装上下文】"
  echo "⚙️ 运行后端：${install_backend_text:-unknown}"
  echo "💡 后端原因：$(status_runtime_backend_reason_text 2>/dev/null || echo unknown)"
  echo "🧪 环境模式：${install_container_text:-unknown}"
  echo "🧩 安装验证：${install_verify_text:-unknown}"
  echo "🧭 端口裁决：${port_adjustment_text:-unknown}"
  echo "🧭 系统代理状态：${system_proxy_text}"
  echo "🧩 Dashboard：${dashboard_text}（来源：${dashboard_source_text}）"
  echo "🧩 Dashboard 策略：${dashboard_policy_text}"
  echo "🔐 控制器密钥：${secret_text}"
  echo

  if [ -n "$(install_plan_controller 2>/dev/null || true)" ]; then
    echo "� 安装期控制器：$(display_controller_local_addr "$(install_plan_controller 2>/dev/null || true)" 2>/dev/null || install_plan_controller 2>/dev/null || true)"
  fi

  if [ -n "$(install_plan_mixed_port 2>/dev/null || true)" ]; then
    echo "🌐 安装期代理端口：$(install_plan_mixed_port 2>/dev/null || true)"
  fi

  echo

  echo "【Tun 状态】"
  if [ "$tun_enabled" = "true" ]; then
    echo "🟢 Tun 开关：已开启"
  else
    echo "🔴 Tun 开关：未开启"
  fi

  echo "🧪 Tun 生效：${tun_effective:-未知}"
  echo "⚙️  Tun stack：${tun_stack:-unknown}"
  echo "� 容器裁决：${tun_container_text:-未知}"
  echo "🚀 内核支持：${tun_kernel_text:-未知}"
  echo

  echo "【编译结果】"
  echo "🧩 编译模式：active-only"
  [ -n "$(status_build_active_source 2>/dev/null || true)" ] && echo "📦 编译主订阅：$(status_build_active_source 2>/dev/null || true)"

  if [ -n "${build_status:-}" ]; then
    echo "🧩 最近编译：${build_status} @ ${build_time:-unknown}"
  else
    echo "🧩 最近编译：未知"
  fi

  [ -n "${build_active_sources:-}" ] && echo "🟢 实际参与编译：$build_active_sources"
  [ -n "${build_failed_active_sources:-}" ] && echo "❌ 编译失败源：$build_failed_active_sources"
  echo

  echo "【当前订阅健康】"
  if status_subscription_health_summary | grep -q .; then
    status_subscription_health_summary | sed 's/^/  /'
  else
    echo "  暂无健康数据"
  fi
  echo

  echo "【系统事件】"
  echo "🧩 当前配置来源：${config_source:-unknown}${config_source_time:+ @ ${config_source_time}}"

  case "${build_applied:-}" in
    true)
      echo "🟢 最近构建应用：true @ ${build_applied_time:-unknown}"
      ;;
    false)
      echo "⚠️ 最近构建应用：false @ ${build_applied_time:-unknown}"
      [ -n "${build_applied_reason:-}" ] && echo "未应用原因：${build_applied_reason}"
      ;;
    *)
      echo "⚪ 最近构建应用：unknown"
      ;;
  esac

  if [ -n "${build_block_reason:-}" ]; then
    echo "⚠️ 最近阻断：${build_block_reason} @ ${build_block_time:-unknown}"
  else
    echo "⚠️ 最近阻断：无"
  fi

  if [ -n "${last_switch_to:-}" ]; then
    echo "🤖 订阅切换建议记录：${last_switch_from:-unknown} -> ${last_switch_to} @ ${last_switch_time:-unknown}"
  else
    echo "🤖 订阅切换建议记录：无"
  fi

  if [ "${fallback_used:-false}" = "true" ]; then
    echo "⚠️ 最近回退：true @ ${fallback_time:-unknown}"
    [ -n "${fallback_reason:-}" ] && echo "回退原因：${fallback_reason}"
  else
    echo "⚠️ 最近回退：false"
  fi
  echo

  echo "【风险原因】"
  if status_risk_reason_lines | grep -q .; then
    status_risk_reason_lines | sed 's/^/  /'
  else
    echo "  无明显风险原因"
  fi
  echo

  echo "【网络闭环】"
  echo "🧭 问题裁决：$(connectivity_issue_text)"
  echo "🔍 关键证据："
  connectivity_evidence_lines | sed 's/^/  /'
  echo

  echo "【策略组摘要】"
  if [ "$controller_ok" = "true" ] && [ -n "${current_proxy_lines:-}" ]; then
    printf '%s\n' "$current_proxy_lines" | sed 's/^/  /'
  else
    echo "  控制器不可访问"
  fi
  echo
}

cmd_status() {
  prepare

  case "${1:-}" in
    --verbose|-v)
      print_status_summary_verbose
      ;;
    "")
      print_status_summary_compact
      ;;
    *)
      die_usage "未知的 status 参数：$1" "clashctl status [--verbose]"
      ;;
  esac
}

cmd_status_next() {
  prepare
  system_state_default_action
}

url_host_bracket_if_needed() {
  local host="$1"

  [ -n "${host:-}" ] || return 1

  case "$host" in
    \[*\])
      echo "$host"
      ;;
    *:*)
      echo "[$host]"
      ;;
    *)
      echo "$host"
      ;;
  esac
}

url_host_bracket_if_needed() {
  local host="$1"

  [ -n "${host:-}" ] || return 1

  case "$host" in
    \[*\])
      echo "$host"
      ;;
    *:*)
      echo "[$host]"
      ;;
    *)
      echo "$host"
      ;;
  esac
}

ui_controller_port() {
  local controller
  controller="$(status_read_controller_raw 2>/dev/null || true)"
  [ -n "${controller:-}" ] && [ "$controller" != "null" ] || return 1
  echo "${controller##*:}"
}

ui_lan_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "src") {
          print $(i+1)
          exit
        }
      }
    }
  '
}

ui_public_ip() {
  local ip=""

  ip="$(
    env \
      -u http_proxy \
      -u https_proxy \
      -u HTTP_PROXY \
      -u HTTPS_PROXY \
      -u all_proxy \
      -u ALL_PROXY \
      curl -4 -fsSL --connect-timeout 2 --max-time 3 https://api.ipify.org 2>/dev/null || true
  )"

  if [ -n "${ip:-}" ]; then
    echo "$ip"
    return 0
  fi

  ip="$(
    env \
      -u http_proxy \
      -u https_proxy \
      -u HTTP_PROXY \
      -u HTTPS_PROXY \
      -u all_proxy \
      -u ALL_PROXY \
      curl -6 -fsSL --connect-timeout 2 --max-time 3 https://api64.ipify.org 2>/dev/null || true
  )"

  [ -n "${ip:-}" ] && echo "$ip"
}

cmd_ui_box() {
  local line0="" line1="" line2="" line3="" line4="" line5=""
  local secret="${5:-}"

  line0="🔓 注意放行端口：${6:-unknown}"
  [ -n "${1:-}" ] && line1="📶 状态：$1"
  [ -n "${2:-}" ] && line2="💻 本机：$2"
  [ -n "${3:-}" ] && line3="🏠 局域网：$3"
  [ -n "${4:-}" ] && line4="🌏 公网：$4"
  [ -n "${secret:-}" ] && line5="🔑 密钥：$secret"

  compute_box_width \
    "🐱 Web 控制台" \
    "$line0" "$line1" "$line2" "$line3" "$line4" "$line5"

  echo
  box_border_top
  box_title_line "🐱 Web 控制台"
  box_border_mid
  box_empty

  [ -n "$line0" ] && box_section_line "$line0"
  [ -n "$line1" ] && box_section_line "$line1"
  [ -n "$line2" ] && box_section_line "$line2"
  [ -n "$line3" ] && box_section_line "$line3"
  [ -n "$line4" ] && box_section_line "$line4"
  [ -n "$line5" ] && box_section_line "$line5"

  box_empty
  box_border_bottom
  echo
}

cmd_ui_help_summary() {
  echo "〽️ 常用命令"
  printf '  %-18s %s\n' "clashon" "开启代理"
  printf '  %-18s %s\n' "clashoff" "关闭代理"
  printf '  %-18s %s\n' "clashctl select" "选择节点"
  echo "📦 订阅"
  printf '  %-18s %s\n' "clashctl add" "添加订阅"
  printf '  %-18s %s\n' "clashctl use" "切换订阅"
  printf '  %-18s %s\n' "clashctl ls" "查看订阅"
  echo "🧭 状态"
  printf '  %-18s %s\n' "clashctl status" "查看状态"
  printf '  %-18s %s\n' "clashctl doctor" "诊断面板"
  echo
}

logs_mihomo() {
  if [ ! -f "$LOG_DIR/mihomo.out.log" ]; then
    echo "Mihomo 日志文件不存在"
    return 0
  fi

  tail -n 200 "$LOG_DIR/mihomo.out.log"
}

logs_subconverter() {
  local file
  file="$(subconverter_log_file)"

  if [ ! -f "$file" ]; then
    echo "subconverter 日志文件不存在"
    return 0
  fi

  tail -n 200 "$file"
}

logs_service() {
  local backend
  backend="$(runtime_backend)"

  case "$backend" in
    systemd)
      systemd_service_logs
      ;;
    systemd-user)
      systemd_user_service_logs
      ;;
    script)
      echo "当前为脚本运行模式，服务日志即 Mihomo 日志"
      logs_mihomo
      ;;
    *)
      die "未知运行后端：$backend"
      ;;
  esac
}

cmd_logs() {
  prepare

  case "${1:-mihomo}" in
    mihomo)
      logs_mihomo
      ;;
    subconverter)
      logs_subconverter
      ;;
    service)
      logs_service
      ;;
    *)
      die "用法：clashctl log|logs [mihomo|subconverter|service]"
      ;;
  esac
}

doctor_print_title() {
  echo
  echo "🧰【$1】"
}

doctor_ok() {
  echo "  ✔ $1"
}

doctor_warn() {
  echo "  ⚠ $1"
}

doctor_fail() {
  echo "  ✘ $1"
}

doctor_yq_available() {
  local yq_path
  yq_path="$(yq_bin 2>/dev/null || true)"
  [ -n "${yq_path:-}" ] && [ -x "$yq_path" ]
}

doctor_warn_skip_yq_parse() {
  doctor_warn "缺少 yq，跳过配置解析类检查"
}

doctor_install_context() {
  doctor_print_title "安装环境检查"

  if [ -n "$(install_env_os 2>/dev/null || true)" ]; then
    doctor_ok "操作系统：$(install_env_os 2>/dev/null || echo unknown)"
  else
    doctor_warn "未记录安装期操作系统"
  fi

  if [ -n "$(install_env_arch 2>/dev/null || true)" ]; then
    doctor_ok "系统架构：$(install_env_arch 2>/dev/null || echo unknown)"
  else
    doctor_warn "未记录安装期系统架构"
  fi

  if [ -n "$(install_env_scope 2>/dev/null || true)" ]; then
    doctor_ok "安装范围：$(install_env_scope 2>/dev/null || echo unknown)"
  else
    doctor_warn "未记录安装范围"
  fi

  if [ -n "$(install_env_container 2>/dev/null || true)" ]; then
    doctor_ok "容器环境：$(install_env_container 2>/dev/null || echo unknown)"
  else
    doctor_warn "未记录容器环境"
  fi

  if [ -n "$(install_plan_backend 2>/dev/null || true)" ]; then
    doctor_ok "安装期选择后端：$(install_plan_backend 2>/dev/null || echo unknown)"
  else
    doctor_warn "未记录安装期运行后端"
  fi

  if [ -n "$(install_plan_container_mode 2>/dev/null || true)" ]; then
    doctor_ok "容器兼容模式：$(install_plan_container_mode 2>/dev/null || echo unknown)"
  else
    doctor_warn "未记录容器兼容模式"
  fi

  if [ -n "$(install_plan_port_policy 2>/dev/null || true)" ]; then
    doctor_ok "端口策略：$(install_plan_port_policy 2>/dev/null || echo unknown)"
  else
    doctor_warn "未记录端口策略"
  fi
}

doctor_container_tun() {
  doctor_print_title "容器与 Tun 检查"

  case "$(install_env_container 2>/dev/null || echo unknown)" in
    host)
      doctor_ok "当前运行在主机环境"
      ;;
    docker)
      doctor_warn "检测到 Docker 环境"
      ;;
    container)
      doctor_warn "检测到容器环境"
      ;;
    *)
      doctor_warn "容器环境未知"
      ;;
  esac

  case "$(runtime_backend 2>/dev/null || echo unknown)" in
    systemd)
      doctor_ok "当前运行后端：systemd"
      ;;
    systemd-user)
      doctor_ok "当前运行后端：systemd-user"
      ;;
    script)
      doctor_warn "当前运行后端：script"
      ;;
    *)
      doctor_warn "当前运行后端未知"
      ;;
  esac

  if tun_device_exists; then
    doctor_ok "/dev/net/tun 存在"
  else
    doctor_warn "/dev/net/tun 不存在"
  fi

  if tun_device_readable; then
    doctor_ok "/dev/net/tun 可读写"
  else
    doctor_warn "/dev/net/tun 不可直接读写"
  fi

  case "$(install_env_tun_safe 2>/dev/null || true)" in
    true)
      doctor_ok "安装期判定：Tun 可安全管理"
      ;;
    false)
      doctor_warn "安装期判定：Tun 不可安全管理"
      ;;
    *)
      doctor_warn "安装期未记录 Tun 安全性"
      ;;
  esac

  if has_ip_command; then
    doctor_ok "ip 命令可用"
  else
    doctor_warn "缺少 ip 命令，Tun/路由能力受限"
  fi

  case "$(tun_enabled 2>/dev/null || echo false)" in
    true)
      doctor_warn "当前 Tun 状态：开启"
      ;;
    *)
      doctor_ok "当前 Tun 状态：关闭"
      ;;
  esac
}

doctor_dependencies() {
  local dashboard_source

  doctor_print_title "依赖检查"

  [ -x "$(mihomo_bin)" ] && doctor_ok "Mihomo 已安装：$(mihomo_bin)" || doctor_fail "Mihomo 缺失：$(mihomo_bin)"
  [ -x "$(subconverter_bin)" ] && doctor_ok "subconverter 已安装：$(subconverter_bin)" || doctor_fail "subconverter 缺失：$(subconverter_bin)"
  [ -x "$(yq_bin)" ] && doctor_ok "yq 已安装：$(yq_bin)" || doctor_fail "yq 缺失：$(yq_bin)"

  dashboard_source="$(dashboard_asset_source)"
  case "$dashboard_source" in
    dir)
      doctor_ok "Dashboard 来源：dir（当前部署不依赖 unzip）"
      ;;
    zip)
      if command -v unzip >/dev/null 2>&1; then
        if dashboard_archive_valid; then
          doctor_ok "Dashboard 来源：zip（unzip 可用，压缩包可解压）"
        else
          doctor_fail "Dashboard 来源：zip（压缩包损坏或不可解压，将阻断 install/update）"
        fi
      else
        doctor_fail "Dashboard 来源：zip（缺少 unzip，无法部署，将阻断 install/update）"
      fi
      ;;
    *)
      doctor_warn "Dashboard 来源：none（dist/ 与 dist.zip 均不可用，将阻断 install/update）"
      ;;
  esac

  if command -v openssl >/dev/null 2>&1; then
    doctor_ok "Secret 生成：openssl 可用"
  elif [ -r /dev/urandom ] && command -v od >/dev/null 2>&1 && command -v tr >/dev/null 2>&1 && command -v head >/dev/null 2>&1; then
    doctor_ok "Secret 生成：fallback 可用（/dev/urandom + od/tr/head）"
  else
    doctor_fail "Secret 生成：缺少 openssl 且 fallback 不可用"
  fi
}

doctor_config() {
  local config_file active_profile mixed_port controller controller_secret_value external_ui_path dashboard_source

  doctor_print_title "配置检查"

  config_file="$RUNTIME_DIR/config.yaml"

  if [ -s "$config_file" ]; then
    doctor_ok "运行配置存在：$config_file"
  else
    doctor_fail "运行配置缺失：$config_file"
    return 0
  fi

  active_profile="$(show_active_profile 2>/dev/null || true)"
  [ -n "${active_profile:-}" ] || active_profile="default"
  doctor_ok "当前 Profile：$active_profile"

  if ! doctor_yq_available; then
    doctor_warn_skip_yq_parse
    if test_runtime_config "$config_file" >/dev/null 2>&1; then
      doctor_ok "配置校验通过"
    else
      doctor_fail "配置校验失败"
    fi
    return 0
  fi

  mixed_port="$("$(yq_bin)" eval '.["mixed-port"] // .port // ""' "$config_file" 2>/dev/null | head -n 1)"
  controller="$("$(yq_bin)" eval '.["external-controller"] // ""' "$config_file" 2>/dev/null | head -n 1)"

  if [ -n "${mixed_port:-}" ] && [ "$mixed_port" != "null" ]; then
    doctor_ok "代理端口：$mixed_port"
  else
    doctor_warn "未解析到代理端口"
  fi

  if [ -n "${controller:-}" ] && [ "$controller" != "null" ]; then
    doctor_ok "控制器地址：$(display_controller_local_addr "$controller" 2>/dev/null || echo "$controller")"
  else
    doctor_warn "未解析到控制器地址"
  fi

  controller_secret_value="$("$(yq_bin)" eval '.secret // ""' "$config_file" 2>/dev/null | head -n 1)"
  if [ -n "${controller_secret_value:-}" ] && [ "$controller_secret_value" != "null" ]; then
    doctor_ok "控制器密钥：已设置"
  else
    doctor_fail "控制器密钥：未设置"
  fi

  external_ui_path="$("$(yq_bin)" eval '.["external-ui"] // ""' "$config_file" 2>/dev/null | head -n 1)"
  dashboard_source="$(read_runtime_value "DASHBOARD_ASSET_SOURCE" 2>/dev/null || echo none)"
  case "${dashboard_source:-none}" in
    dir|zip|none) ;;
    *) dashboard_source="none" ;;
  esac
  if [ -n "${external_ui_path:-}" ] && [ "$external_ui_path" != "null" ] && [ -f "${external_ui_path%/}/index.html" ]; then
    doctor_ok "Dashboard 已接入：${external_ui_path}（来源：${dashboard_source}）"
  else
    doctor_warn "Dashboard 未接入或目录无效（来源：${dashboard_source}）"
  fi

  if test_runtime_config "$config_file" >/dev/null 2>&1; then
    doctor_ok "配置校验通过"
  else
    doctor_fail "配置校验失败"
  fi
}

doctor_subscription() {
  local active file total enabled convert_count auto_disabled_count name

  doctor_print_title "订阅检查"

  file="$(subscriptions_file 2>/dev/null || true)"
  if [ -z "${file:-}" ] || [ ! -f "$file" ]; then
    doctor_warn "订阅配置文件不存在"
    return 0
  fi

  doctor_ok "订阅策略：active-only"

  if ! doctor_yq_available; then
    doctor_warn_skip_yq_parse
    return 0
  fi

  active="$(active_subscription_name 2>/dev/null || true)"

  total="$("$(yq_bin)" eval '.sources | keys | length' "$file" 2>/dev/null || echo 0)"
  enabled="$("$(yq_bin)" eval '[.sources[] | select(.enabled == true)] | length' "$file" 2>/dev/null || echo 0)"
  convert_count="$("$(yq_bin)" eval '[.sources[] | select(.type == "convert")] | length' "$file" 2>/dev/null || echo 0)"

  auto_disabled_count="$(
    while IFS= read -r name; do
      [ -n "${name:-}" ] || continue
      if subscription_auto_disabled "$name"; then
        echo 1
      fi
    done < <("$(yq_bin)" eval '.sources | keys | .[]' "$file")
  )"
  auto_disabled_count="$(printf '%s\n' "${auto_disabled_count:-}" | awk 'NF{c++} END{print c+0}')"

  [ -n "${active:-}" ] && doctor_ok "当前主订阅：$active" || doctor_warn "当前主订阅为空"

  doctor_ok "订阅源总数：$total"
  doctor_ok "已启用订阅源：$enabled"
  doctor_ok "convert 订阅源：$convert_count"
  doctor_ok "自动禁用订阅源：$auto_disabled_count"

  if [ -n "${active:-}" ] && subscription_exists "$active"; then
    if subscription_enabled "$active"; then
      doctor_ok "当前主订阅可用：$active"
    else
      doctor_warn "当前主订阅已禁用：$active"
    fi

    if subscription_auto_disabled "$active"; then
      doctor_warn "当前主订阅曾被自动禁用：$active"
    fi
  fi
}

doctor_build() {
  local active active_sources failed_active_sources last_status last_time
  local block_reason block_time
  local error_summary error_detail error_stage

  doctor_print_title "编译状态检查"

  active="$(read_build_value "BUILD_ACTIVE_SOURCE" 2>/dev/null || true)"
  active_sources="$(status_build_active_sources 2>/dev/null || true)"
  failed_active_sources="$(status_build_failed_active_sources 2>/dev/null || true)"
  last_status="$(read_build_value "BUILD_LAST_STATUS" 2>/dev/null || true)"
  last_time="$(read_build_value "BUILD_LAST_TIME" 2>/dev/null || true)"
  error_summary="$(read_build_value "BUILD_LAST_ERROR_SUMMARY" 2>/dev/null || true)"
  error_detail="$(read_build_value "BUILD_LAST_ERROR_DETAIL" 2>/dev/null || true)"
  error_stage="$(read_build_value "BUILD_LAST_ERROR_STAGE" 2>/dev/null || true)"
  block_reason="$(read_runtime_event_value "RUNTIME_LAST_BUILD_BLOCK_REASON" 2>/dev/null || true)"
  block_time="$(read_runtime_event_value "RUNTIME_LAST_BUILD_BLOCK_TIME" 2>/dev/null || true)"

  if [ -z "${active:-}${active_sources:-}${failed_active_sources:-}${last_status:-}${last_time:-}${error_summary:-}${error_stage:-}${block_reason:-}" ]; then
    doctor_warn "未找到编译元数据（build.env）"
    return 0
  fi

  doctor_ok "编译模式：active-only"

  if [ -n "${active:-}" ]; then
    doctor_ok "当前主订阅：$active"
  else
    doctor_warn "当前主订阅为空"
  fi

  if [ -n "${active_sources:-}" ]; then
    doctor_ok "实际参与编译：$active_sources"
  else
    doctor_warn "没有任何订阅参与编译"
  fi

  if [ -n "${failed_active_sources:-}" ]; then
    doctor_warn "失败订阅源：$failed_active_sources"
  else
    doctor_ok "失败订阅源：无"
  fi

  if [ -n "${last_status:-}" ]; then
    if [ "$last_status" = "success" ]; then
      doctor_ok "最近一次编译状态：$last_status"
    else
      doctor_warn "最近一次编译状态：$last_status"
    fi
  else
    doctor_warn "最近一次编译状态未知"
  fi

  if [ -n "${last_time:-}" ]; then
    doctor_ok "最近一次编译时间：$last_time"
  else
    doctor_warn "最近一次编译时间未知"
  fi

  if [ -n "${block_reason:-}" ]; then
    if [ -n "${block_time:-}" ]; then
      doctor_warn "最近一次编译阻断原因：${block_reason} @ ${block_time}"
    else
      doctor_warn "最近一次编译阻断原因：$block_reason"
    fi
  fi

  if [ -n "${error_summary:-}" ]; then
    doctor_warn "最近一次错误摘要：$error_summary"
  fi

  if [ -n "${error_stage:-}" ]; then
    doctor_warn "最近一次错误阶段：$error_stage"
  fi

  if [ -n "${error_detail:-}" ]; then
    echo "    详细错误："
    printf '%s\n' "$error_detail" | sed 's/^/      /'
  fi
}

doctor_service() {
  local backend

  doctor_print_title "服务检查"

  backend="$(runtime_backend)"
  doctor_ok "运行后端：$backend"

  case "$backend" in
    systemd)
      if systemctl is-active --quiet "$(service_unit_name)"; then
        doctor_ok "systemd 服务运行中"
        systemctl show "$(service_unit_name)" --property MainPID --value 2>/dev/null | awk '{print "    进程号：" $1}'
      else
        doctor_warn "systemd 服务未运行"
      fi
      ;;
    systemd-user)
      if systemctl --user is-active --quiet "$(service_unit_name)"; then
        doctor_ok "用户级 systemd 服务运行中"
        systemctl --user show "$(service_unit_name)" --property MainPID --value 2>/dev/null | awk '{print "    进程号：" $1}'
      else
        doctor_warn "用户级 systemd 服务未运行"
      fi
      ;;
    script)
      if [ -f "$RUNTIME_DIR/mihomo.pid" ]; then
        local pid
        pid="$(cat "$RUNTIME_DIR/mihomo.pid" 2>/dev/null || true)"
        if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
          doctor_ok "脚本模式进程运行中"
          echo "    进程号：$pid"
        else
          doctor_warn "脚本模式 PID 文件存在，但进程未运行"
        fi
      else
        doctor_warn "脚本模式当前未运行"
      fi
      ;;
    *)
      doctor_fail "未知运行后端：$backend"
      ;;
  esac
}

doctor_ports() {
  local config_file mixed_port controller controller_port

  doctor_print_title "端口检查"

  config_file="$RUNTIME_DIR/config.yaml"

  if [ ! -s "$config_file" ]; then
    doctor_warn "运行配置不存在，跳过端口检查"
    return 0
  fi

  if ! doctor_yq_available; then
    doctor_warn_skip_yq_parse
    if [ -x "$(subconverter_bin)" ]; then
      if is_port_in_use "$(subconverter_port)"; then
        doctor_ok "subconverter 端口已监听：$(subconverter_port)"
      else
        doctor_warn "subconverter 端口未监听：$(subconverter_port)"
      fi
    fi
    return 0
  fi

  mixed_port="$("$(yq_bin)" eval '.["mixed-port"] // .port // ""' "$config_file" 2>/dev/null | head -n 1)"
  controller="$("$(yq_bin)" eval '.["external-controller"] // ""' "$config_file" 2>/dev/null | head -n 1)"
  controller_port="${controller##*:}"

  if [ -n "${mixed_port:-}" ] && [ "$mixed_port" != "null" ]; then
    if is_port_in_use "$mixed_port"; then
      doctor_ok "代理端口已监听：$mixed_port"
    else
      doctor_warn "代理端口未监听：$mixed_port"
    fi
  else
    doctor_warn "无法检查代理端口"
  fi

  if [ -n "${controller_port:-}" ] && [ "$controller_port" != "$controller" ] && [ "$controller_port" != "null" ]; then
    if is_port_in_use "$controller_port"; then
      doctor_ok "控制器端口已监听：$controller_port"
    else
      doctor_warn "控制器端口未监听：$controller_port"
    fi
  else
    doctor_warn "无法检查控制器端口"
  fi

  if [ -x "$(subconverter_bin)" ]; then
    if is_port_in_use "$(subconverter_port)"; then
      doctor_ok "subconverter 端口已监听：$(subconverter_port)"
    else
      doctor_warn "subconverter 端口未监听：$(subconverter_port)"
    fi
  fi
}

doctor_install_ports() {
  doctor_print_title "安装端口裁决检查"

  if [ -n "$(install_plan_mixed_port 2>/dev/null || true)" ]; then
    doctor_ok "安装期代理端口：$(install_plan_mixed_port 2>/dev/null || echo unknown)"
    if [ "$(install_plan_mixed_port_auto_changed 2>/dev/null || echo false)" = "true" ]; then
      doctor_warn "代理端口在安装期发生自动避让"
    fi
  else
    doctor_warn "未记录安装期代理端口"
  fi

  if [ -n "$(install_plan_controller 2>/dev/null || true)" ]; then
    doctor_ok "安装期控制器：$(install_plan_controller 2>/dev/null || echo unknown)"
    if [ "$(install_plan_controller_auto_changed 2>/dev/null || echo false)" = "true" ]; then
      doctor_warn "控制器端口在安装期发生自动避让"
    fi
  else
    doctor_warn "未记录安装期控制器地址"
  fi

  if [ -n "$(install_plan_dns_port 2>/dev/null || true)" ]; then
    doctor_ok "安装期 DNS 端口：$(install_plan_dns_port 2>/dev/null || echo unknown)"
    if [ "$(install_plan_dns_port_auto_changed 2>/dev/null || echo false)" = "true" ]; then
      doctor_warn "DNS 端口在安装期发生自动避让"
    fi
  else
    doctor_warn "未记录安装期 DNS 端口"
  fi
}

doctor_runtime_events() {
  local fallback_used fallback_time fallback_reason risk_level
  local config_source build_applied build_applied_time build_applied_reason
  local system_proxy_text dashboard_status dashboard_source secret_status

  doctor_print_title "运行事件检查"

  fallback_used="$(runtime_last_fallback_used)"
  fallback_time="$(runtime_last_fallback_time)"
  fallback_reason="$(runtime_last_fallback_reason)"
  risk_level="$(doctor_risk_level)"
  config_source="$(status_runtime_config_source 2>/dev/null || true)"
  build_applied="$(status_runtime_build_applied 2>/dev/null || true)"
  build_applied_time="$(status_runtime_build_applied_time 2>/dev/null || true)"
  build_applied_reason="$(status_runtime_build_applied_reason 2>/dev/null || true)"
  if system_proxy_supported; then
    system_proxy_text="$(system_proxy_status 2>/dev/null || echo off)"
  else
    system_proxy_text="unsupported"
  fi
  if [ -f "$(runtime_dashboard_dir)/index.html" ]; then
    dashboard_status="已部署"
  else
    dashboard_status="未部署"
  fi
  dashboard_source="$(read_runtime_value "DASHBOARD_ASSET_SOURCE" 2>/dev/null || echo none)"
  case "${dashboard_source:-none}" in
    dir|zip|none) ;;
    *) dashboard_source="none" ;;
  esac
  if [ -n "$(read_env_value "CLASH_CONTROLLER_SECRET" 2>/dev/null || true)" ]; then
    secret_status="已设置"
  else
    secret_status="未设置"
  fi

  doctor_ok "当前风险等级：${risk_level:-unknown}"
  doctor_ok "当前配置来源：${config_source:-unknown}"
  doctor_ok "系统代理状态：${system_proxy_text}"
  doctor_ok "Dashboard 运行目录：${dashboard_status}（来源：${dashboard_source}）"
  doctor_ok ".env 控制器密钥：${secret_status}"

  case "${build_applied:-}" in
    true)
      doctor_ok "最近一次构建已应用"
      [ -n "${build_applied_time:-}" ] && echo "    应用时间：$build_applied_time"
      ;;
    false)
      doctor_warn "最近一次构建未应用"
      [ -n "${build_applied_time:-}" ] && echo "    记录时间：$build_applied_time"
      [ -n "${build_applied_reason:-}" ] && echo "    未应用原因：$build_applied_reason"
      ;;
    *)
      doctor_warn "最近一次构建应用状态未知"
      ;;
  esac

  if [ "${fallback_used:-}" = "true" ]; then
    doctor_warn "最近一次启动触发了配置回退"
    [ -n "${fallback_time:-}" ] && echo "    回退时间：$fallback_time"
    [ -n "${fallback_reason:-}" ] && echo "    回退原因：$fallback_reason"
  else
    doctor_ok "最近一次启动未触发配置回退"
  fi
}

doctor_install_verify() {
  local live_runtime="false"
  local live_controller="false"

  doctor_print_title "安装验证检查"

  case "$(install_verify_command_ready 2>/dev/null || true)" in
    true) doctor_ok "clashctl 命令入口可用" ;;
    false) doctor_fail "clashctl 命令入口不可用" ;;
    *) doctor_warn "未记录命令入口验证结果" ;;
  esac

  case "$(install_verify_config_ready 2>/dev/null || true)" in
    true) doctor_ok "安装后配置已就绪" ;;
    false) doctor_fail "安装后配置未就绪" ;;
    *) doctor_warn "未记录配置验证结果" ;;
  esac

  if status_is_running 2>/dev/null; then
    live_runtime="true"
  fi

  if proxy_controller_reachable 2>/dev/null; then
    live_controller="true"
  fi

  if [ "$live_runtime" = "true" ]; then
    doctor_ok "安装后运行态已就绪"
  else
    case "$(install_verify_runtime_ready 2>/dev/null || true)" in
      true) doctor_ok "安装后运行态已就绪" ;;
      false) doctor_warn "安装后运行态未就绪" ;;
      *) doctor_warn "未记录运行态验证结果" ;;
    esac
  fi

  if [ "$live_controller" = "true" ]; then
    doctor_ok "安装后控制器可访问"
  else
    case "$(install_verify_controller_ready 2>/dev/null || true)" in
      true) doctor_ok "安装后控制器可访问" ;;
      false) doctor_warn "安装后控制器不可访问" ;;
      *) doctor_warn "未记录控制器验证结果" ;;
    esac
  fi
}

doctor_active_switch() {
  local from to at reason

  doctor_print_title "主订阅自动切换检查"

  from="$(read_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_FROM" 2>/dev/null || true)"
  to="$(read_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_TO" 2>/dev/null || true)"
  at="$(read_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_TIME" 2>/dev/null || true)"
  reason="$(read_runtime_event_value "RUNTIME_LAST_ACTIVE_SWITCH_REASON" 2>/dev/null || true)"

  if [ -n "${to:-}" ]; then
    doctor_warn "检测到最近一次主订阅自动切换"
    [ -n "${from:-}" ] && echo "    from   : $from"
    echo "    to     : $to"
    [ -n "${at:-}" ] && echo "    time   : $at"
    [ -n "${reason:-}" ] && echo "    reason : $reason"
  else
    doctor_ok "最近未发生主订阅自动切换"
  fi
}

doctor_controller() {
  local controller group_count current_examples

  doctor_print_title "控制器检查"

  controller="$(status_read_controller 2>/dev/null || true)"

  if [ -z "${controller:-}" ] || [ "$controller" = "null" ]; then
    doctor_fail "未解析到 external-controller"
    return 0
  fi

  doctor_ok "控制器地址：$(display_controller_local_addr "$controller" 2>/dev/null || echo "$controller")"

  if ! status_is_running; then
    doctor_warn "内核未运行，无法检查控制器 API"
    return 0
  fi

  if proxy_controller_reachable 2>/dev/null; then
    doctor_ok "控制器 API 可访问"

    group_count="$(proxy_group_count 2>/dev/null || echo 0)"
    doctor_ok "可切换策略组数量：$group_count"

    if [ "${group_count:-0}" -gt 0 ]; then
      echo "    当前策略组摘要："
      print_proxy_groups_status | head -n 5 | sed 's/^/      /'
    fi
  else
    doctor_fail "控制器 API 不可访问"
  fi
}

cmd_doctor() {
  prepare
  load_system_state

  ui_title "🧭 系统诊断"

  ui_section "总体结论"
  doctor_primary_conclusion
  ui_kv "⚠️" "风险等级" "$(doctor_risk_text)"
  ui_blank

  ui_section "发现的问题"
  if doctor_problem_lines | grep -q .; then
    doctor_problem_lines | sed 's/^/  /'
  else
    echo "  🟢 未发现明显问题"
  fi
  ui_blank

  ui_section "关键证据"
  doctor_evidence_lines | sed 's/^/  /'
  ui_blank

  ui_section "修复建议"
  doctor_recommendation_lines | sed 's/^/  /'
  ui_blank

  ui_section "详细检查"
  doctor_install_context
  doctor_dependencies
  doctor_container_tun
  doctor_config
  doctor_subscription
  doctor_build
  doctor_service
  doctor_ports
  doctor_install_ports
  doctor_runtime_events
  doctor_install_verify
  doctor_active_switch
  doctor_controller

}

cmd_dev() {
  prepare

  case "${1:-}" in
    reset)
      echo
      echo "🧪 正在恢复到安装前状态（保留项目目录与下载文件） ..."
      echo

      bash "$PROJECT_DIR/uninstall.sh" --dev-reset

      echo
      echo "🟢 开发重置完成"
      echo "🧩 保留内容：项目目录、已下载依赖、调试环境"
      echo "👉 下一步：重新执行 install.sh 或 clashctl status"
      echo
      ;;
    "")
      echo "🧭 用法：clashctl dev reset"
      ;;
    *)
      die_usage "未知的 dev 子命令：$1" "clashctl dev reset"
      ;;
  esac
}

cmd_config_show() {
  local active kernel build_status build_time config_source

  prepare

  active="$(active_subscription_name 2>/dev/null || true)"
  kernel="$(runtime_kernel_type 2>/dev/null || echo mihomo)"
  build_status="$(status_build_last_status 2>/dev/null || true)"
  build_time="$(status_build_last_time 2>/dev/null || true)"
  config_source="$(status_runtime_config_source 2>/dev/null || true)"

  ui_title "🧩 配置编译管理"
  ui_kv "📡" "当前主订阅" "${active:-未设置}"
  ui_kv "🚀" "当前内核" "${kernel:-mihomo}"
  ui_kv "🧩" "编译模式" "active-only"
  ui_kv "🟢" "最近构建" "${build_status:-unknown}${build_time:+ @ ${build_time}}"
  ui_kv "🧩" "配置来源" "${config_source:-unknown}"
  ui_blank
  ui_next "clashctl status"
  ui_blank
}

cmd_config() {
  prepare

  case "${1:-}" in
    show)
      cmd_config_show
      ;;
    explain)
      print_build_explain
      ;;
    regen)
      regenerate_config
      apply_runtime_change_after_config_mutation
      print_config_regen_feedback
      print_config_apply_feedback
      ;;
    kernel)
      shift || true
      [ -n "${1:-}" ] || die_usage "内核类型不能为空" "clashctl config kernel <mihomo|clash>"
      write_runtime_kernel_type "$1"
      resolve_runtime_kernel
      regenerate_config
      apply_runtime_change_after_config_mutation
      print_config_kernel_feedback "$(runtime_kernel_type)"
      print_config_apply_feedback
      ;;
    "")
      ui_title "🧩 配置编译管理"
      echo "🧭 用法："
      echo "  clashctl config show"
      echo "  clashctl config explain"
      echo "  clashctl config regen"
      echo "  clashctl config kernel <mihomo|clash>"
      echo
      echo "🧩 说明："
      echo "  当前编译链固定为 active-only"
      echo "  只处理当前 active 主订阅"
      echo
      ui_next "clashctl config show"
      ui_blank
      ;;
    *)
      die_usage "未知的 config 子命令：$1" "clashctl config"
      ;;
  esac
}

print_profile_use_feedback() {
  local profile="$1"

  ui_title "⚙️ Profile 已切换"
  ui_kv "⚙️" "当前 Profile" "$profile"
  main_feedback_runtime_state
  ui_next "clashctl status"
  ui_blank
}

cmd_profile() {
  prepare

  echo "⚠ 当前版本未启用 Profile 功能"
  return 0
}

mixin_config_file() {
  echo "$CONFIG_DIR/mixin.yaml"
}

active_subscription_runtime_raw_file() {
  local name="$1"
  echo "$RUNTIME_DIR/tmp/source-${name}.yaml"
}

ensure_mixin_runtime_prepared() {
  local active source_file

  active="$(active_subscription_name 2>/dev/null || true)"
  [ -n "${active:-}" ] || die "当前没有活动订阅"

  subscription_exists "$active" || die "当前活动订阅不存在：$active"

  source_file="$(active_subscription_runtime_raw_file "$active")"
  mkdir -p "$RUNTIME_DIR/tmp"

  if [ -s "$source_file" ]; then
    echo "$source_file"
    return 0
  fi

  if fetch_subscription_source "$active" "$source_file"; then
    echo "$source_file"
    return 0
  fi

  rm -f "$source_file" 2>/dev/null || true
  die "无法获取当前活动订阅原始配置：$active"
}

open_editor_for_file() {
  local file="$1"
  local editor

  [ -n "${file:-}" ] || die "文件路径不能为空"
  touch "$file"

  if [ -n "${EDITOR:-}" ]; then
    editor="$EDITOR"
  elif command -v nano >/dev/null 2>&1; then
    editor="nano"
  elif command -v vim >/dev/null 2>&1; then
    editor="vim"
  elif command -v vi >/dev/null 2>&1; then
    editor="vi"
  else
    die "未找到可用编辑器，请先设置 EDITOR 环境变量"
  fi

  "$editor" "$file"
}

cmd_mixin_show() {
  local file
  prepare
  ensure_config_files
  file="$(mixin_config_file)"

  ui_title "🧩 Mixin 配置"
  ui_kv "🧩" "作用" "对原始订阅配置进行补充、覆盖或前后置合并"
  ui_kv "⚙️" "配置文件" "$file"
  ui_blank
  cat "$file"
  ui_blank
  ui_next "clashctl mixin edit"
  ui_blank
}

cmd_mixin_edit() {
  local file
  prepare
  ensure_config_files
  file="$(mixin_config_file)"

  open_editor_for_file "$file"

  echo
  echo "ℹ️ 正在重新生成配置 ..."
  regenerate_config

  if status_is_running; then
    service_restart
    echo "🟢 Mixin 已生效（已自动重启）"
  else
    echo "🟡 Mixin 已写入（下次启动生效）"
  fi

  echo "👉 下一步：clashctl mixin runtime"
  echo
}

cmd_mixin_raw() {
  local file
  prepare
  file="$(ensure_mixin_runtime_prepared)"

  echo
  echo "📡 原始订阅配置"
  echo
  echo "📡 说明：这是当前活动订阅拉取到的原始配置，不包含 Mixin 最终合并结果"
  echo "⚙️ 来源文件：$file"
  echo
  cat "$file"
  echo
  echo "👉 下一步：clashctl mixin runtime"
  echo
}

cmd_mixin_runtime() {
  local file
  prepare
  file="$RUNTIME_DIR/config.yaml"

  [ -s "$file" ] || die "🧩 运行时配置不存在：$file"

  echo
  echo "🧩 运行时配置"
  echo
  echo "🧩 说明：这是当前内核真正加载的最终配置"
  echo "⚙️ 配置文件：$file"
  echo
  cat "$file"
  echo
  echo "👉 下一步：clashctl status"
  echo
}

cmd_mixin() {
  case "${1:-}" in
    "")
      cmd_mixin_show
      ;;
    edit|-e|--edit)
      cmd_mixin_edit
      ;;
    raw|-c|--raw)
      cmd_mixin_raw
      ;;
    runtime|-r|--runtime)
      cmd_mixin_runtime
      ;;
    help|-h|--help)
      ui_title "🧩 Mixin 配置管理"
      echo "🧭 用法："
      echo "  clashctl mixin"
      echo "  clashctl mixin edit"
      echo "  clashctl mixin raw"
      echo "  clashctl mixin runtime"
      echo
      echo "🧩 说明："
      echo "  mixin 用于补充、覆盖或前后置合并原始订阅配置"
      echo "  runtime 展示当前内核真正加载的最终配置"
      echo
      echo "💡 常用动作："
      echo "  clashctl mixin"
      echo "  clashctl mixin edit"
      echo "  clashctl mixin runtime"
      echo
      echo "⚡ 快捷参数："
      echo "  clashctl mixin -e"
      echo "  clashctl mixin -c"
      echo "  clashctl mixin -r"
      echo
      ui_next "clashctl mixin"
      ui_blank
      ;;
    *)
      die_usage "未知的 mixin 子命令：$1" "clashctl mixin"
      ;;
  esac
}

runtime_config_exists() {
  [ -s "$RUNTIME_DIR/config.yaml" ]
}

doctor_risk_level() {
  local running controller_ok config_ok

  running="false"
  controller_ok="false"
  config_ok="false"

  status_is_running && running="true"
  proxy_controller_reachable 2>/dev/null && controller_ok="true"
  runtime_config_exists && config_ok="true"

  if [ "$running" = "true" ] && [ "$controller_ok" = "true" ] && [ "$config_ok" = "true" ]; then
    echo "low"
    return
  fi

  if [ "$running" = "false" ]; then
    echo "medium"
    return
  fi

  if [ "$controller_ok" = "false" ]; then
    echo "high"
    return
  fi

  echo "medium"
}

doctor_risk_text() {
  case "$(doctor_risk_level)" in
    low) echo "🟢 低" ;;
    medium) echo "🟡 中" ;;
    high) echo "🔴 高" ;;
    *) echo "⚪ 未知" ;;
  esac
}

doctor_problem_lines() {
  local active_sub

  active_sub="$(active_subscription_name 2>/dev/null || true)"

  if ! runtime_config_exists; then
    echo "⚠️ 运行配置缺失"
  fi

  if ! status_is_running; then
    echo "⚠️ 代理内核未运行"
  fi

  if status_is_running && ! proxy_controller_reachable 2>/dev/null; then
    echo "⚠️ 控制器不可访问"
  fi

  if [ -n "${active_sub:-}" ] && ! active_subscription_enabled 2>/dev/null; then
    echo "⚠️ 当前主订阅不可用"
  fi

  if [ "$(status_build_last_status 2>/dev/null || true)" = "failed" ]; then
    echo "⚠️ 最近一次编译失败"
  fi
}

doctor_primary_conclusion() {
  if ! runtime_config_exists; then
    echo "🔴 当前不可用：缺少运行配置"
    return 0
  fi

  if ! status_is_running; then
    echo "🟡 当前未连接：代理内核未启动"
    return 0
  fi

  if ! proxy_controller_reachable 2>/dev/null; then
    echo "🔴 当前异常：内核已启动，但控制器不可访问"
    return 0
  fi

  echo "🟢 当前基本可用：代理内核与控制器均正常"
}

doctor_recommendation_lines() {
  local active_sub

  active_sub="$(active_subscription_name 2>/dev/null || true)"

  if ! runtime_config_exists; then
    if [ -n "$(subscription_url 2>/dev/null || true)" ]; then
      echo "💡 clashctl config regen"
    else
      echo "💡 clashctl add <订阅链接>"
    fi
    return 0
  fi

  if ! status_is_running; then
    echo "💡 clashon"
    return 0
  fi

  if ! proxy_controller_reachable 2>/dev/null; then
    echo "💡 clashctl logs service"
    echo "💡 clashctl off && clashon"
    return 0
  fi

  if [ -n "${active_sub:-}" ] && ! active_subscription_enabled 2>/dev/null; then
    echo "💡 clashctl use"
    echo "💡 clashctl health"
    return 0
  fi

  if [ "$(status_build_last_status 2>/dev/null || true)" = "failed" ]; then
    echo "💡 clashctl health"
    echo "💡 clashctl config regen"
    return 0
  fi

  echo "💡 clashctl status"
  echo "💡 clashctl select"
}

doctor_evidence_lines() {
  local active_sub mixed_port controller

  active_sub="$(active_subscription_name 2>/dev/null || true)"
  mixed_port="$(status_read_mixed_port 2>/dev/null || true)"
  controller="$(status_read_controller 2>/dev/null || true)"

  if runtime_config_exists; then
    echo "🔍 运行配置：存在"
  else
    echo "🔍 运行配置：缺失"
  fi

  if status_is_running; then
    echo "🔍 服务状态：运行中"
  else
    echo "🔍 服务状态：未运行"
  fi

  if proxy_controller_reachable 2>/dev/null; then
    echo "🔍 控制器状态：可访问"
  else
    echo "🔍 控制器状态：不可访问"
  fi

  if [ -n "${active_sub:-}" ]; then
    if active_subscription_enabled 2>/dev/null; then
      echo "🔍 当前订阅：${active_sub}（可用）"
    else
      echo "🔍 当前订阅：${active_sub}（不可用）"
    fi
  else
    echo "🔍 当前订阅：未设置"
  fi

  if [ -n "${mixed_port:-}" ] && [ "$mixed_port" != "null" ]; then
    if is_port_in_use "$mixed_port"; then
      echo "🔍 代理端口：${mixed_port}（已监听）"
    else
      echo "🔍 代理端口：${mixed_port}（未监听）"
    fi
  fi

  if [ -n "${controller:-}" ] && [ "$controller" != "null" ]; then
    echo "🔍 控制器地址：$(display_controller_local_addr "$controller" 2>/dev/null || echo "$controller")"
  fi
}

set_controller_secret() {
  local secret="$1"
  local file="$RUNTIME_DIR/config.yaml"

  [ -n "${secret:-}" ] || die "密钥不能为空"
  [ -s "$file" ] || die "运行时配置不存在：$file"

  SECRET_VALUE="$secret" "$(yq_bin)" eval -i '
    .secret = strenv(SECRET_VALUE)
  ' "$file"

  write_env_value "CLASH_CONTROLLER_SECRET" "$secret"
}

cmd_secret() {
  local current_secret new_secret

  prepare
  runtime_config_exists || die_state "运行时配置不存在" "clashctl add <订阅链接> 或 clashctl config regen"

  case "${1:-}" in
    "")
      current_secret="$(controller_secret 2>/dev/null || true)"

      echo
      ui_title "🔑 Web 密钥"

      if [ -n "${current_secret:-}" ] && [ "$current_secret" != "null" ]; then
        ui_kv "🔑" "当前密钥" "$current_secret"
      else
        ui_kv "⚠️" "当前密钥" "未设置"
      fi

      ui_kv "�" "用途" "用于访问 Clash Web 控制台"
      ui_next "clashctl ui"
      ui_blank
      echo
      ;;
    *)
      new_secret="$1"
      set_controller_secret "$new_secret"

      echo
      ui_title "🔑 密钥已更新"
      ui_kv "🔑" "新密钥" "$new_secret"

      if status_is_running; then
        service_restart
        ui_kv "🟢" "生效状态" "已重启并生效"
      else
        ui_kv "🟡" "生效状态" "将在下次启动时生效"
      fi

      ui_next "clashctl ui"
      ui_blank
      echo
      ;;
  esac
}

cmd_tun_status() {
  local enabled stack env_type effective_status

  prepare
  enabled="$(tun_enabled)"
  stack="$(tun_stack)"
  env_type="$(container_env_type)"
  effective_status="$(status_tun_effective_status 2>/dev/null || echo ineffective)"

  echo
  echo "🧪 Tun 状态"
  echo

  if [ "$enabled" = "true" ]; then
    echo "🟢 当前状态：已开启"
  else
    echo "🔴 当前状态：未开启"
  fi

  echo "⚙️  Tun stack：$stack"
  echo "💻 环境类型：$env_type"

  if can_manage_tun_safely; then
    echo "🟢 环境检查：满足基础开启条件"
  else
    echo "⚠️ 环境检查：当前不满足基础开启条件"
  fi

  if [ "$effective_status" = "effective" ]; then
    echo "🟢 已生效"
  else
    echo "🔴 未生效"
  fi

  if [ "$enabled" = "true" ]; then
    echo "👉 下一步：clashctl tun doctor"
  else
    echo "👉 下一步：clashctl tun on"
  fi
  echo
}

cmd_tun_on() {
  local verify_result
  local container_mode risk_reason

  prepare

  container_mode="$(tun_container_mode 2>/dev/null || echo unknown)"
  risk_reason="$(tun_container_risk_reason 2>/dev/null || true)"

  case "$container_mode" in
    host)
      ;;
    container-safe)
      ui_warn "当前处于容器环境，Tun 将按保守模式尝试开启"
      [ -n "${risk_reason:-}" ] && ui_warn "$risk_reason"
      ;;
    container-risky)
      mark_tun_last_action "on" "blocked" "${risk_reason:-container-risky}"
      mark_tun_last_verification "blocked" "${risk_reason:-container-risky}"
      print_tun_container_gate_feedback "$container_mode" "${risk_reason:-容器环境不满足 Tun 基础条件}"
      return 1
      ;;
    *)
      ui_warn "无法识别当前 Tun 容器模式，按高风险处理"
      mark_tun_last_action "on" "blocked" "unknown-container-mode"
      mark_tun_last_verification "blocked" "unknown-container-mode"
      print_tun_container_gate_feedback "container-risky" "unknown-container-mode"
      return 1
      ;;
  esac

  if ! can_manage_tun_safely; then
    echo
    echo "🔴 Tun 模式无法开启"
    echo "⚠️ 原因：当前环境不满足基础 Tun 条件"
    echo "👉 下一步：clashctl tun doctor"
    echo
    return 1
  fi

  case "$(tun_kernel_support_level 2>/dev/null || echo unknown)" in
    full)
      ;;
    limited)
      ui_warn "$(tun_kernel_support_reason 2>/dev/null || echo '当前内核仅对 Tun 提供降级支持')"
      ;;
    *)
      ui_warn "当前内核的 Tun 支持等级未知，请谨慎开启"
      ;;
  esac

  set_tun_enabled "true"
  regenerate_config

  if status_is_running; then
    service_restart
  fi

  verify_result="$(tun_effective_check 2>/dev/null || true)"
  [ -n "${verify_result:-}" ] || verify_result="unknown"

  if [ "$verify_result" = "ok" ]; then
    mark_tun_last_action "on" "success" "effective"
    mark_tun_last_verification "success" "effective"
  else
    mark_tun_last_action "on" "partial" "$verify_result"
    mark_tun_last_verification "partial" "$verify_result"
  fi

  print_tun_container_gate_feedback "$container_mode" "$risk_reason"
  print_tun_on_feedback "$verify_result"
}

cmd_tun_off() {
  local verify_result

  prepare

  set_tun_enabled "false"
  regenerate_config

  if status_is_running; then
    service_restart
  fi

  verify_result="$(tun_disable_check 2>/dev/null || true)"
  [ -n "${verify_result:-}" ] || verify_result="unknown"

  if [ "$verify_result" = "ok" ]; then
    mark_tun_last_action "off" "success" "rolled-back"
    mark_tun_last_verification "success" "disabled"
  else
    mark_tun_last_action "off" "partial" "$verify_result"
    mark_tun_last_verification "partial" "$verify_result"
  fi

  print_tun_off_feedback "$verify_result"
}

tun_runtime_status_text() {
  if [ "$(tun_enabled)" = "true" ]; then
    echo "已开启"
  else
    echo "未开启"
  fi
}

doctor_tun_checks() {
  local env_type stack runtime_tun_status backend dns_listen_value
  local runtime_tun_enabled runtime_tun_stack runtime_tun_auto_route
  local effective_result route_dev primary_reason cap_rc

  prepare

  echo
  echo "😼 Tun 诊断"
  echo

  runtime_tun_status="$(tun_runtime_status_text)"
  stack="$(tun_stack)"
  backend="$(runtime_backend)"
  env_type="$(container_env_type)"

  runtime_tun_enabled="$(runtime_config_tun_enabled 2>/dev/null || echo false)"
  runtime_tun_stack="$(runtime_config_tun_stack 2>/dev/null || echo "")"
  runtime_tun_auto_route="$(runtime_config_tun_auto_route 2>/dev/null || echo false)"
  route_dev="$(default_route_dev 2>/dev/null || true)"
  has_cap_net_admin >/dev/null 2>&1
  cap_rc=$?

  echo "【总体结论】"
  if [ "$cap_rc" -eq 1 ]; then
    echo "🔴 当前环境缺少 CAP_NET_ADMIN 权限"
  elif can_manage_tun_safely; then
    echo "🟢 当前环境满足基础 Tun 开启条件"
  else
    echo "🔴 当前环境不满足基础 Tun 开启条件"
  fi
  echo "🧪 当前 Tun 状态：$runtime_tun_status"
  echo "⚙️  Tun stack：$stack"
  echo "⚙️  运行后端：$backend"
  echo "🚀 当前内核：$(runtime_kernel_type 2>/dev/null || echo unknown)"
  echo "🧩 Tun 支持等级：$(tun_kernel_support_text 2>/dev/null || echo 未知)"
  echo "💻 环境类型：$env_type"
  echo "🧭 容器裁决：$(tun_container_mode_text 2>/dev/null || echo 未知)"
  echo "💡 内核说明：$(tun_kernel_support_reason 2>/dev/null || echo 未知)"

  if [ "$(tun_container_mode 2>/dev/null || echo unknown)" = "container-risky" ]; then
    local gate_reason
    gate_reason="$(tun_container_risk_reason 2>/dev/null || true)"
    [ -n "${gate_reason:-}" ] && echo "🔴 阻断原因：$gate_reason"
  fi
  echo

  echo "【发现的问题】"
  if tun_problem_lines | grep -q .; then
    tun_problem_lines | sed 's/^/  /'
  else
    echo "  🟢 未发现明显问题"
  fi
  echo

  echo "【关键证据】"
  if is_root_user; then
    echo "  🟢 当前为 root 用户"
  else
    echo "  ⚠️ 当前不是 root 用户"
  fi

  if tun_device_exists; then
    echo "  🟢 /dev/net/tun：存在"
  else
    echo "  🔴 /dev/net/tun：不存在"
  fi

  if tun_device_exists; then
    if tun_device_readable; then
      echo "  🟢 /dev/net/tun：可读写"
    else
      echo "  ⚠️ /dev/net/tun：存在但不可正常读写"
    fi
  fi

  case "$cap_rc" in
    0)
      echo "  🟢 CAP_NET_ADMIN：已检测到"
      ;;
    2)
      echo "  ⚠️ CAP_NET_ADMIN：无法精确判断（缺少 capsh）"
      ;;
    *)
      echo "  ⚠️ CAP_NET_ADMIN：未检测到"
      ;;
  esac

  if has_ip_command; then
    echo "  🟢 ip 命令：可用"
  else
    echo "  ⚠️ ip 命令：缺失"
  fi

  if runtime_config_exists; then
    dns_listen_value="$("$(yq_bin)" eval '.dns.listen // ""' "$RUNTIME_DIR/config.yaml" 2>/dev/null | head -n 1)"
    if [ -n "${dns_listen_value:-}" ] && [ "$dns_listen_value" != "null" ]; then
      echo "  🟢 DNS 监听：$dns_listen_value"
    else
      echo "  ⚠️ DNS 监听：未解析到"
    fi

    echo "  🧩 runtime tun.enable：${runtime_tun_enabled:-false}"
    if [ -n "${runtime_tun_stack:-}" ] && [ "$runtime_tun_stack" != "null" ]; then
      echo "  🧩 runtime tun.stack：$runtime_tun_stack"
    fi
    echo "  🧭 runtime tun.auto-route：${runtime_tun_auto_route:-false}"
  else
    echo "  ⚠️ 运行时配置：不存在"
  fi

  if [ -n "${route_dev:-}" ]; then
    echo "  🌐 默认路由设备：$route_dev"
  else
    echo "  ⚠️ 默认路由设备：未解析到"
  fi
  echo

  echo "【生效验证】"
  if [ "$(tun_enabled 2>/dev/null || echo false)" = "true" ]; then
    effective_result="$(tun_effective_check 2>/dev/null || true)"
    primary_reason="$(tun_doctor_primary_reason "$effective_result")"

    if [ "$effective_result" = "ok" ]; then
      echo "  🟢 已生效"
    else
      tun_doctor_conclusion_line "$primary_reason" | sed 's/^/  /'
    fi
  else
    primary_reason="$(tun_doctor_primary_reason "tun-disabled")"
    tun_doctor_conclusion_line "$primary_reason" | sed 's/^/  /'
  fi
  echo

  echo "【建议操作】"
  tun_recommendation_lines "$primary_reason" | sed 's/^/  /'
  echo
}

tun_doctor_primary_reason() {
  local effective_result cap_rc

  effective_result="${1:-unknown}"

  has_cap_net_admin >/dev/null 2>&1
  cap_rc=$?
  if [ "$cap_rc" -eq 1 ]; then
    echo "missing-cap-net-admin"
    return 0
  fi

  if ! tun_device_exists 2>/dev/null; then
    echo "missing-tun-device"
    return 0
  fi

  if tun_device_exists 2>/dev/null && ! tun_device_readable 2>/dev/null; then
    echo "tun-device-not-readable"
    return 0
  fi

  if ! has_ip_command 2>/dev/null; then
    echo "missing-ip-command"
    return 0
  fi

  case "$effective_result" in
    controller-unreachable|runtime-not-running|disabled-in-state|disabled-in-runtime-config|tun-disabled|host-ip-unavailable|current-ip-unavailable|traffic-same-as-host)
      echo "$effective_result"
      ;;
    *)
      echo "traffic-check-failed"
      ;;
  esac
}

tun_doctor_conclusion_line() {
  case "${1:-traffic-check-failed}" in
    missing-cap-net-admin)
      echo "🔴 Tun 未生效：缺少 CAP_NET_ADMIN 权限"
      ;;
    missing-tun-device)
      echo "🔴 Tun 未生效：缺少 /dev/net/tun"
      ;;
    tun-device-not-readable)
      echo "🔴 Tun 未生效：/dev/net/tun 不可读写"
      ;;
    missing-ip-command)
      echo "🔴 Tun 未生效：缺少 ip 命令"
      ;;
    runtime-not-running)
      echo "🔴 Tun 未生效：代理内核未运行"
      ;;
    controller-unreachable)
      echo "🔴 Tun 未生效：控制器不可访问"
      ;;
    disabled-in-state|disabled-in-runtime-config)
      echo "🔴 Tun 未生效：Tun 状态与运行配置不一致"
      ;;
    tun-disabled)
      echo "🔴 Tun 未生效：Tun 未开启"
      ;;
    host-ip-unavailable|current-ip-unavailable)
      echo "🔴 Tun 未生效：无法完成公网出口验证"
      ;;
    traffic-same-as-host)
      echo "🔴 Tun 未生效：流量出口仍是本机公网 IP"
      ;;
    *)
      echo "🔴 Tun 未生效：流量验证未通过"
      ;;
  esac
}

tun_doctor_action_lines() {
  local reason backend unit

  reason="${1:-traffic-check-failed}"
  backend="$(runtime_backend 2>/dev/null || echo unknown)"
  unit="$(service_unit_name 2>/dev/null || echo clash-for-linux.service)"

  case "$reason" in
    missing-cap-net-admin)
      case "$backend" in
        systemd)
          echo "👉 当前运行后端为 systemd，请为服务添加 CAP_NET_ADMIN："
          echo "   sudo systemctl edit $unit"
          ;;
        systemd-user)
          echo "👉 当前运行后端为 systemd-user，请改用 systemd 系统服务或为用户服务补齐 CAP_NET_ADMIN"
          ;;
        script)
          echo "👉 当前运行后端为 script，请使用具备 CAP_NET_ADMIN 的环境运行："
          echo "   sudo clashctl tun on"
          ;;
        *)
          echo "👉 请为当前运行环境补齐 CAP_NET_ADMIN 权限"
          ;;
      esac
      ;;
    missing-tun-device)
      echo "👉 请先挂载或启用 /dev/net/tun"
      ;;
    tun-device-not-readable)
      echo "👉 请修复 /dev/net/tun 权限，确保当前运行用户可读写"
      ;;
    missing-ip-command)
      echo "👉 请先安装 iproute2，确保 ip 命令可用"
      ;;
    runtime-not-running)
      echo "👉 请先启动代理：clashon"
      ;;
    controller-unreachable)
      echo "👉 请先修复控制器可访问性：clashctl doctor"
      ;;
    disabled-in-state|disabled-in-runtime-config)
      echo "👉 请重新同步 Tun 配置：clashctl tun off && clashctl tun on"
      ;;
    tun-disabled)
      echo "👉 请开启 Tun：clashctl tun on"
      ;;
    host-ip-unavailable|current-ip-unavailable)
      echo "👉 请先确认服务器可访问 https://ip.sb：curl https://ip.sb"
      ;;
    traffic-same-as-host)
      echo "👉 当前流量仍走本机出口，请检查 Tun 路由规则和内核日志：clashctl logs"
      ;;
    *)
      echo "👉 请查看运行日志定位流量验证失败原因：clashctl logs"
      ;;
  esac
}

tun_recommendation_lines() {
  local enabled env_type can_enable container_mode risk_reason
  local effective_result disable_result
  local config_tun_enabled auto_route
  local kernel_support
  local primary_reason

  primary_reason="${1:-}"
  kernel_support="$(tun_kernel_support_level 2>/dev/null || echo unknown)"
  enabled="$(tun_enabled 2>/dev/null || echo false)"
  env_type="$(container_env_type 2>/dev/null || echo unknown)"
  container_mode="$(tun_container_mode 2>/dev/null || echo unknown)"
  risk_reason="$(tun_container_risk_reason 2>/dev/null || true)"
  config_tun_enabled="$(runtime_config_tun_enabled 2>/dev/null || echo false)"
  auto_route="$(runtime_config_tun_auto_route 2>/dev/null || echo false)"

  can_enable="false"
  if can_manage_tun_safely 2>/dev/null; then
    can_enable="true"
  fi

  if [ "$enabled" != "true" ] && [ -n "${primary_reason:-}" ] && [ "$primary_reason" != "tun-disabled" ]; then
    tun_doctor_action_lines "$primary_reason"
    return 0
  fi

  if [ "$kernel_support" = "limited" ] && [ "$enabled" != "true" ]; then
    echo "1. 当前内核为 clash，Tun 仅按降级支持处理"
    echo "2. 如需最稳妥 Tun 体验，建议先执行：clashctl config kernel mihomo"
    echo "3. 再开启 Tun：clashctl tun on"
    return 0
  fi

  if [ "$enabled" = "true" ]; then
    effective_result="$(tun_effective_check 2>/dev/null || true)"
    [ -n "${effective_result:-}" ] || effective_result="unknown"
    [ -n "${primary_reason:-}" ] || primary_reason="$(tun_doctor_primary_reason "$effective_result")"

    if [ "$effective_result" != "ok" ]; then
      tun_doctor_action_lines "$primary_reason"
      return 0
    fi

    echo "1. Tun 已生效，可继续使用"
    echo "2. 如需恢复普通代理模式，执行：clashctl tun off"
    if [ "$kernel_support" = "limited" ]; then
      echo "3. 当前 Tun 运行在 clash 内核上，如需更稳妥体验可切换：clashctl config kernel mihomo"
    fi

    return 0
  fi

  disable_result="$(tun_disable_check 2>/dev/null || true)"
  [ -n "${disable_result:-}" ] || disable_result="unknown"

  if [ "$disable_result" != "ok" ]; then
    echo "1. Tun 关闭后仍有残留，建议执行：clashctl tun off"
    echo "2. 如仍异常，执行：clashoff && clashon"
    return 0
  fi

  if [ "$can_enable" != "true" ]; then
    case "$container_mode" in
      container-risky)
        echo "1. 当前容器环境已被裁决为高风险：${risk_reason:-容器条件不足}"
        echo "2. 检查宿主机是否映射 /dev/net/tun"
        echo "3. 检查是否授予 CAP_NET_ADMIN / --cap-add=NET_ADMIN"
        echo "4. 检查容器内是否具备 ip 命令"
        echo "5. 条件满足后再执行：clashctl tun on"
        ;;
      *)
        echo "1. 当前环境不满足 Tun 基础条件"
        echo "2. 优先检查：/dev/net/tun、CAP_NET_ADMIN、ip 命令"
        echo "3. 条件满足后再执行：clashctl tun on"
        ;;
    esac
    return 0
  fi

  if [ "${config_tun_enabled:-false}" = "true" ] && [ "$enabled" != "true" ]; then
    echo "1. 当前运行配置仍保留 Tun 开启状态"
    echo "2. 建议先执行：clashctl tun off"
    echo "3. 再观察：clashctl tun doctor"
    return 0
  fi

  case "$container_mode" in
    container-safe)
      echo "1. 当前容器环境已通过保守裁决，可尝试开启 Tun：clashctl tun on"
      echo "2. 开启后立即执行：clashctl tun doctor"
      echo "3. 若未生效，优先检查宿主机权限与设备映射"
      return 0
      ;;
    container-risky)
      echo "1. 当前容器环境属于高风险，不建议直接开启 Tun"
      echo "2. 先修复：${risk_reason:-容器条件不足}"
      echo "3. 修复后再执行：clashctl tun on"
      return 0
      ;;
  esac

  echo "1. 当前环境可尝试开启 Tun：clashctl tun on"
  echo "2. 开启后建议立即执行：clashctl tun doctor"
}

tun_problem_lines() {
  local enabled env_type config_tun_enabled auto_route
  local effective_result disable_result route_dev
  local container_mode risk_reason
  local kernel_support
  kernel_support="$(tun_kernel_support_level 2>/dev/null || echo unknown)"
  container_mode="$(tun_container_mode 2>/dev/null || echo unknown)"
  risk_reason="$(tun_container_risk_reason 2>/dev/null || true)"

  enabled="$(tun_enabled 2>/dev/null || echo false)"
  env_type="$(container_env_type 2>/dev/null || echo unknown)"
  config_tun_enabled="$(runtime_config_tun_enabled 2>/dev/null || echo false)"
  auto_route="$(runtime_config_tun_auto_route 2>/dev/null || echo false)"
  route_dev="$(default_route_dev 2>/dev/null || true)"

  if ! tun_device_exists 2>/dev/null; then
    echo "• /dev/net/tun 不存在"
  fi

  if tun_device_exists 2>/dev/null && ! tun_device_readable 2>/dev/null; then
    echo "• /dev/net/tun 存在但不可正常读写"
  fi

  if ! has_ip_command 2>/dev/null; then
    echo "• 缺少 ip 命令，无法进行完整路由校验"
  fi

  if ! can_manage_tun_safely 2>/dev/null; then
    echo "• 当前环境不满足 Tun 安全开启条件"
  fi

  if [ "$env_type" != "host" ]; then
    case "$container_mode" in
      container-safe)
        echo "• 当前处于容器环境，Tun 虽可尝试开启，但建议重点关注流量验证结果"
        ;;
      container-risky)
        echo "• 当前处于高风险容器环境：${risk_reason:-容器条件不足}"
        ;;
      *)
        echo "• 当前处于容器环境，Tun 状态未知"
        ;;
    esac
  fi

  case "$kernel_support" in
    limited)
      echo "• 当前内核为 clash，Tun 仅按降级支持处理，稳定性可能弱于 mihomo"
      ;;
    unknown)
      echo "• 当前内核的 Tun 支持等级未知"
      ;;
  esac

  if ! runtime_config_exists 2>/dev/null; then
    echo "• 运行时配置不存在"
    return 0
  fi

  if [ "$enabled" = "true" ] && [ "${config_tun_enabled:-false}" != "true" ]; then
    echo "• Tun 状态文件已开启，但 runtime/config.yaml 未启用 tun.enable"
  fi

  if [ "$enabled" != "true" ] && [ "${config_tun_enabled:-false}" = "true" ]; then
    echo "• Tun 状态文件已关闭，但 runtime/config.yaml 仍启用 tun.enable"
  fi

  if [ "$enabled" = "true" ]; then
    effective_result="$(tun_effective_check 2>/dev/null || true)"
    if [ "$effective_result" != "ok" ]; then
      echo "• Tun 未生效"
    fi
  else
    disable_result="$(tun_disable_check 2>/dev/null || true)"
    if [ "$disable_result" != "ok" ]; then
      echo "• Tun 当前虽为关闭态，但仍存在残留：${disable_result:-unknown}"
    fi
  fi
}

cmd_tun() {
  case "${1:-}" in
    ""|status)
      cmd_tun_status
      ;;
    on)
      cmd_tun_on
      ;;
    off)
      cmd_tun_off
      ;;
    doctor)
      doctor_tun_checks
      ;;
    *)
      ui_title "🧪 Tun 模式管理"
      echo "🧭 用法："
      echo "  clashctl tun"
      echo "  clashctl tun status"
      echo "  clashctl tun on"
      echo "  clashctl tun off"
      echo "  clashctl tun doctor"
      echo
      echo "🧩 说明："
      echo "  Tun 属于高级接管能力"
      echo "  开启前应确认环境支持 /dev/net/tun、权限与网络能力"
      echo
      echo "💡 常用动作："
      echo "  clashctl tun status"
      echo "  clashctl tun doctor"
      echo "  clashtun on"
      echo
      ui_next "clashctl tun doctor"
      ui_blank
      ;;
  esac
}

add_trim_input() {
  printf '%s' "${1:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

add_next_subscription_name() {
  local suffix="" letter candidate

  while true; do
    for letter in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
      candidate="${letter}${suffix}"
      if ! subscription_name_exists "$candidate"; then
        echo "$candidate"
        return 0
      fi
    done

    if [ -z "${suffix:-}" ]; then
      suffix=1
    else
      suffix=$((suffix + 1))
    fi
  done
}

add_prompt_url() {
  local input url

  while true; do
    printf "请输入订阅地址：" >&2
    IFS= read -r input || return 1
    url="$(add_trim_input "$input")"

    if [ -n "${url:-}" ]; then
      echo "$url"
      return 0
    fi

    echo "订阅地址不能为空，请重新输入" >&2
  done
}

add_prompt_name() {
  local input name

  while true; do
    printf "请输入订阅名称（回车自动生成）：" >&2
    IFS= read -r input || return 1
    name="$(add_trim_input "$input")"

    if [ -z "${name:-}" ]; then
      add_next_subscription_name
      return 0
    fi

    if subscription_name_exists "$name"; then
      echo "⚠ 名称已存在，请重新输入" >&2
      continue
    fi

    echo "$name"
    return 0
  done
}

cmd_add() {
  local sub_url sub_name sub_fmt

  prepare
  ensure_add_use_prerequisites

  case "$#" in
    0)
      sub_url="$(add_prompt_url)"
      sub_name="$(add_prompt_name)"
      ;;
    1)
      sub_url="$(add_trim_input "${1:-}")"
      [ -n "${sub_url:-}" ] || die "订阅地址不能为空"
      sub_name="$(add_prompt_name)"
      ;;
    *)
      sub_url="$(add_trim_input "${1:-}")"
      [ -n "${sub_url:-}" ] || die "订阅地址不能为空"
      sub_name="${2:-default}"
      ;;
  esac

  sub_fmt="$(detect_subscription_format "$sub_url")"

  set_subscription "$sub_url" "$sub_fmt" "$sub_name"
  apply_runtime_change_after_config_mutation
  print_add_feedback "$sub_name" "$sub_url"
}

cmd_use() {
  local recommended active

  prepare
  ensure_add_use_prerequisites

  case "${1:-}" in
    --recommend|-r)
      recommended="$(recommended_subscription_name 2>/dev/null || true)"
      active="$(active_subscription_name 2>/dev/null || true)"

      if [ -z "${recommended:-}" ]; then
        if [ -n "${active:-}" ]; then
          ui_title "🟢 当前无更优推荐，保持当前"
          ui_kv "📡" "当前主订阅" "$active"
          ui_next "clashctl select  选择节点"
          ui_blank
          return 0
        fi

        ui_title "🔴 当前没有可推荐的订阅"
        ui_next "clashctl select  选择节点"
        ui_blank
        return 1
      fi

      if [ "${recommended:-}" = "${active:-}" ]; then
        ui_title "🟢 当前已是推荐订阅，无需切换"
        [ -n "${active:-}" ] && ui_kv "📡" "当前主订阅" "$active"
        ui_next "clashctl select  选择节点"
        ui_blank
        return 0
      fi

      set_active_subscription "$recommended"
      apply_runtime_change_after_config_mutation
      print_use_feedback "$recommended"
      return 0
      ;;
    "")
      print_use_context
      use_subscription_interactive
      ;;
    --verbose|-v)
      print_use_context
      use_subscription_interactive "verbose"
      ;;
    *)
      set_active_subscription "$1"
      apply_runtime_change_after_config_mutation
      print_use_feedback "$1"
      ;;
  esac
}

subscription_pick_index() {
  local count="$1"
  local input choice

  while true; do
    printf "> " >&2
    IFS= read -r input || return 1
    choice="$(printf '%s' "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    case "${choice:-}" in
      q|Q)
        return 1
        ;;
    esac

    if ! printf '%s' "$choice" | grep -Eq '^[0-9]+$'; then
      echo "请输入有效编号" >&2
      continue
    fi

    if [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
      echo "$choice"
      return 0
    fi

    echo "请输入有效编号" >&2
  done
}

use_subscription_interactive() {
  local url_mode="${1:-full}"
  local active idx count selected_name
  local -a names

  active="$(active_subscription_name 2>/dev/null || true)"

  while IFS= read -r selected_name; do
    [ -n "${selected_name:-}" ] || continue
    names+=("$selected_name")
  done < <("$(yq_bin)" eval '.sources | keys | .[]' "$(subscriptions_file)" 2>/dev/null)

  count="${#names[@]}"
  [ "$count" -gt 0 ] || die "当前没有任何订阅"

  echo
  echo "😼 请选择订阅"
  echo

  if [ -n "${active:-}" ] && subscription_exists "$active"; then
    echo "当前主订阅：$active"
    echo
  fi

  print_subscription_table_header "true"
  idx=1
  for selected_name in "${names[@]}"; do
    print_subscription_pick_line "$idx" "$selected_name" "$url_mode" "true"
    idx=$((idx + 1))
  done

  echo
  echo "  q) 退出"
  echo

  idx="$(subscription_pick_index "$count")" || return 0
  selected_name="${names[$((idx - 1))]}"

  set_active_subscription "$selected_name"
  apply_runtime_change_after_config_mutation
  print_use_feedback "$selected_name"
}

health_overview_lines() {
  local active recommended active_health active_fail active_enabled

  active="$(active_subscription_name 2>/dev/null || true)"
  recommended="$(recommended_subscription_name 2>/dev/null || true)"

  if [ -n "${active:-}" ]; then
    if subscription_enabled "$active"; then
      active_enabled="enabled"
    else
      active_enabled="disabled"
    fi
    active_health="$(subscription_health_status "$active" 2>/dev/null || echo "unknown")"
    active_fail="$(subscription_fail_count "$active" 2>/dev/null || echo "0")"

    echo "📡 当前主订阅：$active"
    echo "❤️ 当前健康状态：$active_health"
    echo "⚠️ 当前失败次数：$active_fail"
    echo "⚙️ 当前启用状态：$active_enabled"
  else
    echo "📡 当前主订阅：未设置"
  fi

  if [ -n "${recommended:-}" ] && [ "${recommended:-}" != "${active:-}" ]; then
    echo "💡 推荐订阅：$recommended"
  elif [ -n "${active:-}" ]; then
    echo "💡 推荐订阅：保持当前"
  else
    echo "💡 推荐订阅：暂无"
  fi
}

health_recommendation_lines() {
  load_system_state

  case "$SYSTEM_STATE" in
    ready)
      echo "💡 clashctl status"
      echo "💡 clashctl select"
      ;;
    stopped)
      if [ "$SUBSCRIPTION_STATE" = "missing" ]; then
        echo "💡 clashctl add <订阅链接>"
      else
        echo "💡 clashon"
      fi
      ;;
    degraded|broken)
      echo "💡 clashctl doctor"
      echo "💡 clashctl status --verbose"
      ;;
    *)
      echo "💡 clashctl status"
      ;;
  esac
}

cmd_ls() {
  prepare

  case "${1:-}" in
    "") ;;
    *)
      die_usage "ls 参数不合法" "clashctl ls"
      ;;
  esac

  ui_title "📡 订阅列表"

  subscription_list_overview_lines | sed 's/^/  /'
  ui_blank

  list_subscriptions
  ui_blank

  ui_section "下一步建议"
  subscription_list_recommendation_lines | sed 's/^/  /'
  ui_blank
}

cmd_health() {
  local verbose_mode="false"
  local target_name=""

  prepare

  while [ $# -gt 0 ]; do
    case "$1" in
      --verbose|-v)
        verbose_mode="true"
        ;;
      *)
        if [ -z "${target_name:-}" ]; then
          target_name="$1"
        else
          die_usage "health 参数不合法" "clashctl health [名称] [--verbose]"
        fi
        ;;
    esac
    shift
  done

  if [ "$verbose_mode" = "true" ]; then
    if [ -n "${target_name:-}" ]; then
      ui_section "单订阅详情"
      print_subscription_health_one "$target_name" | sed 's/^/  /'
      ui_blank

      ui_section "建议操作"
      echo "  💡 clashctl use ${target_name}"
      echo "  💡 clashctl ls"
      ui_blank
      return 0
    fi

    ui_info "订阅健康已收敛到 clashctl ls"
    cmd_ls
    return $?
  fi

  if [ -n "${target_name:-}" ]; then
    ui_section "单订阅详情"
    print_subscription_health_one "$target_name" | sed 's/^/  /'
    ui_blank
    ui_section "建议操作"
    echo "  💡 clashctl use ${target_name}"
    echo "  💡 clashctl ls"
    ui_blank
    return 0
  fi

  ui_info "订阅健康已收敛到 clashctl ls"
  cmd_ls
}

cmd_select() {
  prepare

  if [ -z "${1:-}" ]; then
    print_select_context || return $?
    proxy_select_interactive
    return 0
  fi

  proxy_select_direct "$@"
}

cmd_proxy_groups() {
  local group current type found="false"

  prepare

  if ! status_is_running; then
    die_state "代理内核未运行" "clashon"
  fi

  if ! proxy_controller_reachable 2>/dev/null; then
    die_state "控制器不可访问" "clashctl doctor"
  fi

  ui_title "📦 策略组列表"
  echo "  📦 名称                 类型         当前节点"
  while IFS= read -r group; do
    [ -n "${group:-}" ] || continue
    found="true"
    type="$(proxy_group_type "$group" 2>/dev/null || echo "unknown")"
    current="$(proxy_group_current "$group" 2>/dev/null || echo "-")"
    printf '  📦 %-20s %-12s %s\n' "$group" "$type" "$current"
  done < <(proxy_group_list)

  if [ "$found" != "true" ]; then
    echo "  📭 暂无可切换策略组"
  fi

  ui_blank
  ui_next "clashctl select"
  ui_blank
}

cmd_proxy_current() {
  local group current found="false"

  prepare

  if ! status_is_running; then
    die_state "代理内核未运行" "clashon"
  fi

  if ! proxy_controller_reachable 2>/dev/null; then
    die_state "控制器不可访问" "clashctl doctor"
  fi

  if [ -n "${1:-}" ]; then
    group="$1"
    current="$(proxy_group_current "$group" 2>/dev/null || true)"
    ui_title "🚀 当前节点"
    ui_kv "📦" "策略组" "$group"
    ui_kv "🚀" "当前节点" "${current:-未知}"
    ui_blank
    return 0
  fi

  ui_title "🚀 当前节点总览"
  while IFS= read -r group; do
    [ -n "${group:-}" ] || continue
    found="true"
    current="$(proxy_group_current "$group" 2>/dev/null || echo "-")"
    printf '  🚀 %-20s %s\n' "$group" "$current"
  done < <(proxy_group_list)

  if [ "$found" != "true" ]; then
    echo "  📭 暂无可切换策略组"
  fi

  ui_blank
}

cmd_proxy_nodes() {
  local group="$1"
  local current node found="false"

  prepare
  [ -n "${group:-}" ] || die "请使用 clashctl select 切换节点"

  if ! status_is_running; then
    die_state "代理内核未运行" "clashon"
  fi

  if ! proxy_controller_reachable 2>/dev/null; then
    die_state "控制器不可访问" "clashctl doctor"
  fi

  current="$(proxy_group_current "$group" 2>/dev/null || true)"

  ui_title "🚀 候选节点列表"
  ui_kv "📦" "策略组" "$group"
  [ -n "${current:-}" ] && ui_kv "🚀" "当前节点" "$current"
  ui_blank

  while IFS= read -r node; do
    [ -n "${node:-}" ] || continue
    found="true"
    if [ "$node" = "$current" ]; then
      printf '  * 🚀 %s\n' "$node"
    else
      printf '    🚀 %s\n' "$node"
    fi
  done < <(proxy_group_nodes "$group")

  if [ "$found" != "true" ]; then
    echo "  📭 当前策略组没有候选节点"
  fi

  ui_blank
  ui_next "clashctl select"
  ui_blank
}

proxy_pick_index() {
  local count="$1"
  local input

  while true; do
    printf "> "
    IFS= read -r input || return 1

    case "${input:-}" in
      q|Q)
        return 1
        ;;
    esac

    if printf '%s' "$input" | grep -Eq '^[0-9]+$' && [ "$input" -ge 1 ] && [ "$input" -le "$count" ]; then
      echo "$input"
      return 0
    fi

    echo "⚠️ 请输入 1-$count 之间的编号，或输入 q 退出"
  done
}

proxy_pick_group_interactive() {
  local idx count group current
  local -a groups

  while IFS= read -r group; do
    [ -n "${group:-}" ] || continue
    groups+=("$group")
  done < <(proxy_group_list)

  count="${#groups[@]}"
  [ "$count" -gt 0 ] || die "📭 暂无可切换策略组"

  echo "📦 请选择策略组："
  idx=1
  for group in "${groups[@]}"; do
    current="$(proxy_group_current "$group" 2>/dev/null || echo "-")"
    printf '  %s) 📦 %s  ->  🚀 %s\n' "$idx" "$group" "$current"
    idx=$((idx + 1))
  done
  echo "  q) 退出"
  echo

  idx="$(proxy_pick_index "$count")" || return 1
  echo "${groups[$((idx - 1))]}"
}

cmd_sub() {
  prepare

  case "${1:-}" in
    list)
      shift || true
      cmd_ls "$@"
      ;;
    use)
      shift || true
      [ -n "${1:-}" ] || die "用法：clashctl sub use <名称>"
      set_active_subscription "$1"
      apply_runtime_change_after_config_mutation
      ;;
    set)
      shift || true
      [ -n "${1:-}" ] || die "用法：clashctl sub set <url> [name]（固定 convert，推荐使用：clashctl add <订阅链接>）"
      set_subscription "${1:-}" "convert" "${2:-default}"
      apply_runtime_change_after_config_mutation
      ;;
    enable)
      shift || true
      [ -n "${1:-}" ] || die "🧭 用法：clashctl sub enable <名称>"
      enable_subscription "$1"
      regenerate_config
      apply_runtime_change_after_config_mutation
      print_sub_enable_feedback "$1"
      ;;
    disable)
      shift || true
      [ -n "${1:-}" ] || die "🧭 用法：clashctl sub disable <名称>"
      disable_subscription "$1"
      regenerate_config
      apply_runtime_change_after_config_mutation
      print_sub_disable_feedback "$1"
      ;;
    rename)
      shift || true
      [ -n "${1:-}" ] || die "🧭 用法：clashctl sub rename <旧名称> <新名称>"
      [ -n "${2:-}" ] || die "🧭 用法：clashctl sub rename <旧名称> <新名称>"
      rename_subscription "$1" "$2"
      regenerate_config
      apply_runtime_change_after_config_mutation
      print_sub_rename_feedback "$1" "$2"
      ;;
    remove|rm|del)
      shift || true
      [ -n "${1:-}" ] || die "🧭 用法：clashctl sub remove <名称>"
      remove_subscription "$1"
      regenerate_config
      apply_runtime_change_after_config_mutation
      print_sub_remove_feedback "$1"
      ;;
    health)
      shift || true
      cmd_health "$@"
      ;;
    "")
      ui_title "📡 订阅高级管理"
      echo "🧭 用法："
      echo "  clashctl sub list"
      echo "  clashctl sub use <名称>"
      echo "  clashctl sub enable <名称>"
      echo "  clashctl sub disable <名称>"
      echo "  clashctl sub rename <旧名称> <新名称>"
      echo "  clashctl sub remove <名称>"
      echo "  clashctl sub health [名称]"
      echo
      echo "🧩 说明："
      echo "  add / use / ls / health 属于主路径"
      echo "  sub 仅用于高级维护操作"
      echo
      echo "💡 常用动作："
      echo "  clashctl sub list"
      echo "  clashctl sub health"
      echo "  clashctl sub enable <名称>"
      echo
      ui_next "clashctl ls"
      ui_blank
      ;;
    *)
      die_usage "未知的 sub 子命令：$1" "clashctl sub"
      ;;
  esac
}

proxy_select_interactive() {
  local group="${1:-}"
  local current idx count node selected_node
  local -a nodes

  prepare

  if ! status_is_running; then
    die_state "代理内核未运行" "clashon"
  fi

  if ! proxy_controller_reachable 2>/dev/null; then
    die_state "控制器不可访问" "clashctl doctor"
  fi

  if [ -z "${group:-}" ]; then
    ui_title "🚀 节点切换"
    group="$(proxy_pick_group_interactive)" || return 0
  fi

  current="$(proxy_group_current "$group" 2>/dev/null || true)"

  while IFS= read -r node; do
    [ -n "${node:-}" ] || continue
    nodes+=("$node")
  done < <(proxy_group_nodes "$group")

  count="${#nodes[@]}"
  [ "$count" -gt 0 ] || die "📭 当前策略组没有候选节点：$group"

  echo
  echo "📦 当前策略组：$group"
  [ -n "${current:-}" ] && echo "🚀 当前节点：$current"
  echo
  echo "🚀 请选择节点："

  idx=1
  for node in "${nodes[@]}"; do
    if [ "$node" = "$current" ]; then
      printf '  %s) 🚀 %s [当前]\n' "$idx" "$node"
    else
      printf '  %s) 🚀 %s\n' "$idx" "$node"
    fi
    idx=$((idx + 1))
  done

  echo "  q) 退出"
  echo

  idx="$(proxy_pick_index "$count")" || return 0
  selected_node="${nodes[$((idx - 1))]}"

  proxy_group_select "$group" "$selected_node"
  print_select_feedback "$group"
}

cmd_proxy() {
  echo "⚠ 当前版本不提供 proxy 子命令"
  echo "👉 使用 clashon / clashoff 控制代理"
  echo "👉 使用 clashctl select 切换节点"
  return 0
}

cmd_upgrade() {
  local verbose="false"
  local target_kernel=""

  prepare

  while [ $# -gt 0 ]; do
    case "$1" in
      mihomo|clash)
        target_kernel="$1"
        ;;
      -v|--verbose)
        verbose="true"
        ;;
      *)
        die_usage "upgrade 参数不合法" "clashctl upgrade [mihomo|clash] [-v|--verbose]"
        ;;
    esac
    shift
  done

  [ -n "${target_kernel:-}" ] || target_kernel="$(runtime_kernel_type)"

  ui_title "🚀 正在升级 ${target_kernel} 内核 ..."

  upgrade_runtime_kernel "$target_kernel" "$verbose"

  ui_title "🟢 内核升级完成"
  ui_kv "🚀" "当前内核" "$(runtime_kernel_type)"
  ui_kv "🧩" "影响范围" "仅更新代理内核，不更新项目脚本"
  ui_next "clashctl status"
  ui_blank
}

cmd_update() {
  local force_mode="false"
  local regenerate_mode="false"

  prepare

  while [ $# -gt 0 ]; do
    case "$1" in
      --force)
        force_mode="true"
        ;;
      --regenerate)
        regenerate_mode="true"
        ;;
      *)
        die_usage "update 参数不合法" "clashctl update [--force] [--regenerate]"
        ;;
    esac
    shift
  done

  ui_title "🔄 正在更新项目代码 ..."

  update_project_code "$force_mode" "$regenerate_mode"

  ui_title "🟢 项目代码已更新"
  ui_kv "🧩" "影响范围" "脚本、CLI、配置处理逻辑可能已变化"
  if [ "$regenerate_mode" = "true" ]; then
    ui_kv "🧩" "配置状态" "已重新生成"
  else
    ui_kv "⚠️" "配置状态" "未自动重新生成"
  fi
  ui_next "clashctl status"
  ui_blank
}

cmd_start_direct() {
  prepare
  start_runtime
}

cmd_stop_direct() {
  prepare
  stop_runtime
}

cmd_restart_direct() {
  prepare
  stop_runtime || true
  start_runtime
}

status_read_mixed_port() {
  runtime_config_mixed_port 2>/dev/null || true
}

status_read_controller_raw() {
  runtime_config_controller_addr 2>/dev/null || true
}

controller_externally_reachable() {
  local controller host

  controller="$(status_read_controller_raw 2>/dev/null || true)"
  [ -n "${controller:-}" ] && [ "$controller" != "null" ] || return 1

  host="${controller%:*}"

  case "$host" in
    0.0.0.0|::|[::])
      return 0
      ;;
    127.0.0.1|localhost|::1|[::1])
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

status_read_controller() {
  local controller
  controller="$(status_read_controller_raw 2>/dev/null || true)"
  display_controller_local_addr "$controller" 2>/dev/null || echo "$controller"
}

status_read_controller_lan() {
  local controller lan_ip port
  controller="$(status_read_controller_raw 2>/dev/null || true)"
  [ -n "${controller:-}" ] && [ "$controller" != "null" ] || return 1

  controller_externally_reachable || return 1

  port="${controller##*:}"
  lan_ip="$(ui_lan_ip 2>/dev/null || true)"
  [ -n "${lan_ip:-}" ] || return 1
  echo "${lan_ip}:${port}"
}

status_read_controller_public() {
  local controller public_ip port
  controller="$(status_read_controller_raw 2>/dev/null || true)"
  [ -n "${controller:-}" ] && [ "$controller" != "null" ] || return 1

  controller_externally_reachable || return 1

  port="${controller##*:}"
  public_ip="$(ui_public_ip 2>/dev/null || true)"
  [ -n "${public_ip:-}" ] || return 1
  echo "${public_ip}:${port}"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  add)            cmd_add "$@" ;;
  use)            cmd_use "$@" ;;
  ls)             cmd_ls "$@" ;;
  health)         cmd_health "$@" ;;
  select)         cmd_select "$@" ;;
  on)             cmd_on "$@" ;;
  off)            cmd_off "$@" ;;
  status)         cmd_status "$@" ;;
  status-next)    cmd_status_next "$@" ;;
  log|logs)       cmd_logs "$@" ;;
  doctor)         cmd_doctor "$@" ;;
  ui)             cmd_ui "$@" ;;
  secret)         cmd_secret "$@" ;;
  tun)            cmd_tun "$@" ;;
  dev)            cmd_dev "$@" ;;
  config)         cmd_config "$@" ;;
  mixin)          cmd_mixin "$@" ;;
  profile)        cmd_profile "$@" ;;
  sub)            cmd_sub "$@" ;;
  proxy)          cmd_proxy "$@" ;;
  upgrade)        cmd_upgrade "$@" ;;
  update)         cmd_update "$@" ;;
  start-direct)   cmd_start_direct "$@" ;;
  stop-direct)    cmd_stop_direct "$@" ;;
  restart-direct) cmd_restart_direct "$@" ;;
  -h|--help|"") usage ;;
  help)
    case "${1:-}" in
      advanced) usage_advanced ;;
      *) usage ;;
    esac
    ;;
  *) die "未知命令：$cmd" ;;
esac
