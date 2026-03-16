#!/usr/bin/env bash
set -euo pipefail

# More accurate uninstall for clash-for-linux
SERVICE_NAME="clash-for-linux"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

if [ "$(id -u)" -ne 0 ]; then
  err "需要 root 权限执行卸载脚本（请使用 sudo bash uninstall.sh）"
  exit 1
fi

# Candidate install dirs:
# 1) explicit CLASH_INSTALL_DIR
# 2) working directory if it looks like clash-for-linux
# 3) service WorkingDirectory / ExecStart path inferred from unit
# 4) common defaults
candidates=()
[ -n "${CLASH_INSTALL_DIR:-}" ] && candidates+=("${CLASH_INSTALL_DIR}")
PWD_BASENAME="$(basename "${PWD}")"
if [ "$PWD_BASENAME" = "clash-for-linux" ] && [ -f "${PWD}/start.sh" ]; then
  candidates+=("${PWD}")
fi

if [ -f "$UNIT_PATH" ]; then
  wd="$(sed -nE 's#^WorkingDirectory=(.*)#\1#p' "$UNIT_PATH" | head -n1 || true)"
  [ -n "$wd" ] && candidates+=("$wd")

  exec_path="$(sed -nE 's#^ExecStart=/bin/bash[[:space:]]+([^[:space:]]+/start\.sh).*#\1#p' "$UNIT_PATH" | head -n1 || true)"
  if [ -n "$exec_path" ]; then
    candidates+=("$(dirname "$exec_path")")
  fi
fi

candidates+=("/root/clash-for-linux" "/opt/clash-for-linux")

# normalize + uniq + choose first existing dir containing start.sh or shutdown.sh
INSTALL_DIR=""
declare -A seen
for d in "${candidates[@]}"; do
  [ -n "$d" ] || continue
  d="${d%/}"
  [ -n "$d" ] || continue
  if [ -z "${seen[$d]:-}" ]; then
    seen[$d]=1
    if [ -d "$d" ] && { [ -f "$d/start.sh" ] || [ -f "$d/shutdown.sh" ] || [ -d "$d/conf" ]; }; then
      INSTALL_DIR="$d"
      break
    fi
  fi
done

if [ -z "$INSTALL_DIR" ]; then
  warn "未能自动识别安装目录，将按候选路径继续清理 systemd / 环境文件。"
else
  info "识别到安装目录: $INSTALL_DIR"
fi

info "开始卸载 ${SERVICE_NAME} ..."

# 1) graceful stop
if [ -n "$INSTALL_DIR" ] && [ -f "${INSTALL_DIR}/shutdown.sh" ]; then
  info "执行 shutdown.sh（优雅停止）..."
  bash "${INSTALL_DIR}/shutdown.sh" >/dev/null 2>&1 || true
fi

if command -v systemctl >/dev/null 2>&1; then
  info "停止并禁用 systemd 服务..."
  systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl disable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
fi

# 2) stop process by pid file from all likely dirs
for d in "/root/clash-for-linux" "/opt/clash-for-linux" "${INSTALL_DIR:-}"; do
  [ -n "$d" ] || continue
  PID_FILE="$d/temp/clash.pid"
  if [ -f "$PID_FILE" ]; then
    PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
      info "检测到 PID=${PID}（来自 $PID_FILE），尝试停止..."
      kill "$PID" 2>/dev/null || true
      sleep 1
      if kill -0 "$PID" 2>/dev/null; then
        warn "进程仍在运行，强制 kill -9 ${PID}"
        kill -9 "$PID" 2>/dev/null || true
      fi
    fi
    rm -f "$PID_FILE" || true
  fi
done

# 兜底：按完整路径匹配，避免误杀其他 clash
pkill -f '/clash-for-linux/.*/clash' >/dev/null 2>&1 || true
pkill -f '/clash-for-linux/.*/mihomo' >/dev/null 2>&1 || true
sleep 1
pkill -9 -f '/clash-for-linux/.*/clash' >/dev/null 2>&1 || true
pkill -9 -f '/clash-for-linux/.*/mihomo' >/dev/null 2>&1 || true

# 3) remove unit and related files
if [ -f "$UNIT_PATH" ]; then
  rm -f "$UNIT_PATH"
  ok "已移除 systemd 单元: ${UNIT_PATH}"
fi
if [ -d "/etc/systemd/system/${SERVICE_NAME}.service.d" ]; then
  rm -rf "/etc/systemd/system/${SERVICE_NAME}.service.d"
  ok "已移除 drop-in: /etc/systemd/system/${SERVICE_NAME}.service.d"
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
fi

# 4) cleanup env / command entry
rm -f "/etc/default/${SERVICE_NAME}" >/dev/null 2>&1 || true
rm -f "/etc/profile.d/clash-for-linux.sh" >/dev/null 2>&1 || true
rm -f "/usr/local/bin/clashctl" >/dev/null 2>&1 || true
for d in "/root/clash-for-linux" "/opt/clash-for-linux" "${INSTALL_DIR:-}"; do
  [ -n "$d" ] || continue
  rm -f "$d/temp/clash-for-linux.sh" >/dev/null 2>&1 || true
done

# 5) remove install dirs
# removed_any=false
# for d in "${INSTALL_DIR:-}" "/root/clash-for-linux" "/opt/clash-for-linux"; do
#   [ -n "$d" ] || continue
#   if [ -d "$d" ] && { [ -f "$d/start.sh" ] || [ -d "$d/conf" ] || [ "$d" = "$INSTALL_DIR" ]; }; then
#     rm -rf "$d"
#     ok "已移除安装目录: $d"
#     removed_any=true
#   fi
# done

# if [ "$removed_any" = false ]; then
#   warn "未发现可删除的安装目录"
# fi

echo
warn "如果你曾执行 proxy_on，当前终端可能仍保留代理环境变量。可执行："
echo "  unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY"
echo "  # 或关闭终端重新打开"

echo
ok "卸载完成 ✅"
