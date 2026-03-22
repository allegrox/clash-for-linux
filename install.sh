#!/usr/bin/env bash
set -euo pipefail

Server_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ui.sh
. "$Server_Dir/scripts/ui.sh"
Install_Dir="${CLASH_INSTALL_DIR:-$Server_Dir}"

Service_Name="clash-for-linux"
Service_User="root"
Service_Group="root"

# =========================
# 基础校验
# =========================
ui_header "clashctl install"

ui_step "[1/5] Preflight checks"

if [ "$(id -u)" -ne 0 ]; then
  die "root privilege required"
fi
ui_ok "root privilege confirmed"

if [ ! -f "${Server_Dir}/.env" ]; then
  die_with_reason \
    ".env not found" \
    "missing file: ${Server_Dir}/.env" \
    "ensure project directory is complete"
fi
ui_ok ".env file found"

# =========================
# 同步文件
# =========================
ui_blank
ui_step "[2/5] Prepare directories"
mkdir -p "$Install_Dir"
ui_ok "install dir ready: $Install_Dir"

chmod +x "$Install_Dir"/clashctl 2>/dev/null || true
chmod +x "$Install_Dir"/scripts/* 2>/dev/null || true
chmod +x "$Install_Dir"/bin/* 2>/dev/null || true

# =========================
# 目录初始化
# =========================
mkdir -p \
  "$Install_Dir/runtime" \
  "$Install_Dir/logs" \
  "$Install_Dir/config/mixin.d"

ui_ok "runtime directory ready"
ui_ok "logs directory ready"
ui_ok "mixin directory ready"

# =========================
# 加载 env
# =========================
# shellcheck disable=SC1090
ui_blank
ui_step "[3/5] Load environment"

source "$Install_Dir/.env"

ui_ok ".env loaded"

# shellcheck disable=SC1090
source "$Install_Dir/scripts/get_cpu_arch.sh"

ui_ok "cpu arch detected: ${CpuArch:-unknown}"

# shellcheck disable=SC1090
source "$Install_Dir/scripts/resolve_clash.sh"

ui_blank
ui_step "[4/5] Prepare core"

if ! bash "$Install_Dir/scripts/resolve_clash.sh"; then
  ui_error "failed to prepare clash core"
  ui_fix_block \
    "resolve_clash.sh returned non-zero" \
    "check download URL and network connectivity"
  ui_debug_block \
    "bash $Install_Dir/scripts/resolve_clash.sh"
  exit 1
fi

ui_ok "clash core ready"

write_env_value() {
  local key="$1"
  local value="$2"
  local env_file="$Install_Dir/.env"
  local escaped="${value//\\/\\\\}"
  escaped="${escaped//&/\\&}"
  escaped="${escaped//|/\\|}"
  escaped="${escaped//\'/\'\\\'\'}"

  if grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$env_file"; then
    sed -i -E "s|^[[:space:]]*(export[[:space:]]+)?${key}=.*$|export ${key}='${escaped}'|g" "$env_file"
  else
    printf "export %s='%s'\n" "$key" "$value" >> "$env_file"
  fi
}

read_env_value() {
  local key="$1"
  sed -nE "s/^[[:space:]]*(export[[:space:]]+)?${key}=['\"]?([^'\"]*)['\"]?$/\2/p" "$Install_Dir/.env" | head -n 1
}

get_public_ip() {
  curl -fsS --max-time 5 ifconfig.me 2>/dev/null \
    || curl -fsS --max-time 5 ip.sb 2>/dev/null \
    || curl -fsS --max-time 5 api.ipify.org 2>/dev/null \
    || true
}

show_dashboard_info() {
  local secret="$1"
  local public_ip="$2"

  local controller_addr="${CLASH_CONTROLLER_ADDR:-127.0.0.1:9090}"
  local host="${controller_addr%:*}"
  local port="${controller_addr##*:}"

  local local_ui="http://127.0.0.1:${port}/ui"
  local public_ui=""

  if [ -n "${public_ip:-}" ]; then
    public_ui="http://${public_ip}:${port}/ui"
  fi

  ui_blank
  ui_summary_begin "Dashboard"

  ui_summary_row "Control" "${host}:${port}"
  ui_summary_row "Local UI" "$local_ui"

  if [ -n "$public_ui" ] && [ "$host" = "0.0.0.0" ]; then
    ui_summary_row "Public UI" "$public_ui"
  fi

  ui_summary_end

  ui_blank
  ui_subheader "Secret"
  printf '  %s\n' "$secret"

  # 安全提示（非常关键）
  if [ "$host" = "0.0.0.0" ]; then
    ui_security_block \
      "面板已暴露到公网" \
      "建议通过防火墙限制访问" \
      "避免直接开放给所有来源"
  else
    ui_security_block \
      "面板默认仅本机可访问" \
      "未开启公网访问"
  fi
}

wait_dashboard_ready() {
  local host="$1"
  local port="${2:-9090}"
  local max_retry="${3:-20}"
  local i

  for ((i=1; i<=max_retry; i++)); do
    if curl -fsS --max-time 2 "http://${host}:${port}/ui/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

prompt_and_apply_subscription() {
  local sub_url=""
  local secret=""
  local public_ip=""

  while true; do
    echo
    ui_subheader "订阅设置"
    read -r -p "请输入要添加的订阅链接：" sub_url

    if [ -z "${sub_url:-}" ]; then
      ui_error "❌ 订阅链接不能为空"
      continue
    fi

    write_env_value "CLASH_URL" "$sub_url"

    echo "⏳ 正在下载订阅..."
    echo "🍃 验证订阅配置..."
    if ! "$Install_Dir/scripts/generate_config.sh" >/dev/null 2>&1; then
      ui_error "❌ 订阅不可用或转换失败，请检查链接后重试"
      continue
    fi
    
    ui_ok "🎉 订阅已添加：[1] $sub_url"
    ui_ok "🔥 订阅已生效"

    if command -v systemctl >/dev/null 2>&1; then
      systemctl restart "${Service_Name}.service"
    else
      "$Install_Dir/scripts/run_clash.sh" --daemon
    fi

    secret="$(read_env_value "CLASH_SECRET")"
    public_ip="$(get_public_ip)"

    show_dashboard_info "$secret" "$public_ip"
    return 0
  done
}

# =========================
# 内核检查
# =========================
if ! resolve_clash_bin "$Install_Dir" "${CpuArch:-}" >/dev/null 2>&1; then
  die_with_reason \
    "clash core not ready" \
    "binary validation failed" \
    "check download result or architecture mismatch"
fi

ui_ok "clash core validated"

# =========================
# 安装 clashctl
# =========================
# ===== 安装/覆盖 clashctl 命令 =====

OLD_CLASHCTL_PATH="$(command -v clashctl 2>/dev/null || true)"
OLD_CLASHCTL_REAL=""
if [ -n "$OLD_CLASHCTL_PATH" ]; then
  OLD_CLASHCTL_REAL="$(readlink -f "$OLD_CLASHCTL_PATH" 2>/dev/null || true)"
fi

chmod +x "$Install_Dir/clashctl"

# 如果存在旧版本，打印提示
if [ -n "$OLD_CLASHCTL_REAL" ] && [ "$OLD_CLASHCTL_REAL" != "$(readlink -f "$Install_Dir/clashctl")" ]; then
  echo "[WARN] 检测到旧版 clashctl: $OLD_CLASHCTL_REAL"
  echo "[INFO] 将覆盖为当前版本: $Install_Dir/clashctl"
fi

# 强制覆盖（关键）
rm -f /usr/local/bin/clashctl
ln -s "$Install_Dir/clashctl" /usr/local/bin/clashctl

# 清理 shell 缓存（非常关键）
hash -r

# 强校验（防止假覆盖）
NEW_CLASHCTL_REAL="$(readlink -f /usr/local/bin/clashctl 2>/dev/null || true)"
EXPECTED_CLASHCTL_REAL="$(readlink -f "$Install_Dir/clashctl" 2>/dev/null || true)"

if [ "$NEW_CLASHCTL_REAL" != "$EXPECTED_CLASHCTL_REAL" ]; then
  echo "[ERROR] clashctl 覆盖失败，系统命令未指向当前安装目录" >&2
  exit 1
fi

echo "[OK] clashctl 已更新: /usr/local/bin/clashctl -> $EXPECTED_CLASHCTL_REAL"

chmod +x "$Install_Dir/clashctl"

ui_ok "clashctl installed: /usr/local/bin/clashctl"

# =========================
# 安装 proxy helper
# =========================
cat >/etc/profile.d/clash-for-linux.sh <<EOF
# clash-for-linux proxy helpers

CLASH_INSTALL_DIR="${Install_Dir}"
ENV_FILE="\${CLASH_INSTALL_DIR}/.env"

if [ -f "\$ENV_FILE" ]; then
  set +u
  . "\$ENV_FILE" >/dev/null 2>&1 || true
  set -u
fi

CLASH_LISTEN_IP="\${CLASH_LISTEN_IP:-127.0.0.1}"
CLASH_HTTP_PORT="\${CLASH_HTTP_PORT:-7890}"
CLASH_SOCKS_PORT="\${CLASH_SOCKS_PORT:-7891}"

proxy_on() {
  export http_proxy="http://\${CLASH_LISTEN_IP}:\${CLASH_HTTP_PORT}"
  export https_proxy="http://\${CLASH_LISTEN_IP}:\${CLASH_HTTP_PORT}"
  export HTTP_PROXY="http://\${CLASH_LISTEN_IP}:\${CLASH_HTTP_PORT}"
  export HTTPS_PROXY="http://\${CLASH_LISTEN_IP}:\${CLASH_HTTP_PORT}"
  export all_proxy="socks5://\${CLASH_LISTEN_IP}:\${CLASH_SOCKS_PORT}"
  export ALL_PROXY="socks5://\${CLASH_LISTEN_IP}:\${CLASH_SOCKS_PORT}"
  export no_proxy="127.0.0.1,localhost,::1"
  export NO_PROXY="127.0.0.1,localhost,::1"
  echo "[OK] Proxy enabled: http://\${CLASH_LISTEN_IP}:\${CLASH_HTTP_PORT}"
}

proxy_off() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  unset all_proxy ALL_PROXY no_proxy NO_PROXY
  echo "[OK] Proxy disabled"
}
EOF

chmod 644 /etc/profile.d/clash-for-linux.sh

# =========================
# 安装 systemd
# =========================
if command -v systemctl >/dev/null 2>&1; then
  CLASH_SERVICE_USER="$Service_User" CLASH_SERVICE_GROUP="$Service_Group" \
    "$Install_Dir/scripts/install_systemd.sh" "$Install_Dir"

  if [ "${CLASH_ENABLE_SERVICE:-true}" = "true" ]; then
    systemctl enable "${Service_Name}.service" || true
  fi
else
  ui_warn "未找到 systemd，回退到脚本模式"
fi

# =========================
# 输出 + 订阅录入
# =========================
ui_blank
ui_summary_begin "Installation Summary"
ui_summary_row "Status" "Installed"
ui_summary_row "Path" "$Install_Dir"
ui_summary_row "clashctl" "/usr/local/bin/clashctl"
ui_summary_row "Mode" "systemd"
ui_summary_end

prompt_and_apply_subscription

echo
echo "Commands:"
echo "  clashctl status"
echo "  clashctl logs"
echo "  clashctl restart"
echo "  clashctl stop"
echo "  clashctl ui"
echo "  clashctl secret"