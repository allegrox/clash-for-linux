#!/usr/bin/env bash
set -euo pipefail

Server_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Install_Dir="${CLASH_INSTALL_DIR:-$Server_Dir}"

Service_Name="clash-for-linux"
Service_User="root"
Service_Group="root"

# =========================
# 基础校验
# =========================
if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] root required" >&2
  exit 1
fi

if [ ! -f "${Server_Dir}/.env" ]; then
  echo "[ERROR] .env not found in ${Server_Dir}" >&2
  exit 1
fi

# =========================
# 同步文件
# =========================
mkdir -p "$Install_Dir"

chmod +x "$Install_Dir"/clashctl 2>/dev/null || true
chmod +x "$Install_Dir"/scripts/* 2>/dev/null || true
chmod +x "$Install_Dir"/bin/* 2>/dev/null || true

# =========================
# 目录初始化（新结构）
# =========================
mkdir -p \
  "$Install_Dir/runtime" \
  "$Install_Dir/logs" \
  "$Install_Dir/config/mixin.d"

# =========================
# 加载 env
# =========================
# shellcheck disable=SC1090
source "$Install_Dir/.env"

# shellcheck disable=SC1090
source "$Install_Dir/scripts/get_cpu_arch.sh"

# shellcheck disable=SC1090
source "$Install_Dir/scripts/resolve_clash.sh"

# =========================
# 内核检查
# =========================
if ! resolve_clash_bin "$Install_Dir" "${CpuArch:-}" >/dev/null 2>&1; then
  echo "[ERROR] clash core not ready" >&2
  exit 1
fi

# =========================
# 安装 clashctl
# =========================
ln -sf "$Install_Dir/clashctl" /usr/local/bin/clashctl
chmod +x "$Install_Dir/clashctl"

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
Service_Enabled="unknown"
Service_Started="unknown"

if command -v systemctl >/dev/null 2>&1; then
  CLASH_SERVICE_USER="$Service_User" CLASH_SERVICE_GROUP="$Service_Group" \
    "$Install_Dir/scripts/install_systemd.sh" "$Install_Dir"

  if [ "${CLASH_ENABLE_SERVICE:-true}" = "true" ]; then
    systemctl enable "${Service_Name}.service" || true
  fi

  if [ "${CLASH_START_SERVICE:-true}" = "true" ]; then
    systemctl start "${Service_Name}.service" || true
  fi

  if systemctl is-enabled --quiet "${Service_Name}.service" 2>/dev/null; then
    Service_Enabled="enabled"
  else
    Service_Enabled="disabled"
  fi

  if systemctl is-active --quiet "${Service_Name}.service" 2>/dev/null; then
    Service_Started="active"
  else
    Service_Started="inactive"
  fi
else
  echo "[WARN] systemd not found, will use script mode"
fi

# =========================
# 输出（全部收敛到 clashctl）
# =========================
echo
echo "=== Install Complete ==="
echo "Install Dir : $Install_Dir"
echo "clashctl    : /usr/local/bin/clashctl"

echo
echo "Next:"
echo "  clashctl generate"
echo "  clashctl start"
echo "  clashctl doctor"

echo
echo "Commands:"
echo "  clashctl status"
echo "  clashctl logs"
echo "  clashctl restart"
echo "  clashctl stop"