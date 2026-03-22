#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! declare -f ui_info >/dev/null 2>&1; then
  # shellcheck source=scripts/ui.sh
  source "$PROJECT_DIR/scripts/ui.sh"
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/runtime"
LOG_DIR="$PROJECT_DIR/logs"
CONFIG_FILE="$RUNTIME_DIR/config.yaml"
PID_FILE="$RUNTIME_DIR/clash.pid"

mkdir -p "$RUNTIME_DIR" "$LOG_DIR"

FOREGROUND=false
DAEMON=false

# =========================
# 参数解析
# =========================
for arg in "$@"; do
  case "$arg" in
    --foreground) FOREGROUND=true ;;
    --daemon) DAEMON=true ;;
    *)
      ui_error "未知参数: $arg" >&2
      exit 2
      ;;
  esac
done

if [ "$FOREGROUND" = true ] && [ "$DAEMON" = true ]; then
  ui_error "不能同时使用 --foreground 和 --daemon" >&2
  exit 2
fi

if [ "$FOREGROUND" = false ] && [ "$DAEMON" = false ]; then
  ui_error "必须指定 --foreground 或 --daemon" >&2
  exit 2
fi

# =========================
# 基础校验
# =========================
if [ ! -s "$CONFIG_FILE" ]; then
  ui_error "未找到运行配置文件: $CONFIG_FILE" >&2
  exit 2
fi

if grep -q '\${' "$CONFIG_FILE"; then
  ui_error "配置文件存在未替换变量: $CONFIG_FILE" >&2
  exit 2
fi

# =========================
# 加载依赖
# =========================
# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/get_cpu_arch.sh"
# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/resolve_clash.sh"
# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/service_lib.sh"

# =========================
# 获取二进制
# =========================
CLASH_BIN="$(resolve_clash_bin "$PROJECT_DIR" "${CpuArch:-}")"

if [ ! -x "$CLASH_BIN" ]; then
  ui_error "Clash 二进制不可执行: $CLASH_BIN" >&2
  exit 2
fi

# =========================
# 配置校验（仅执行一次）
# =========================
if ! "$CLASH_BIN" -t -f "$CONFIG_FILE" -d "$RUNTIME_DIR" >/dev/null 2>&1; then
  ui_error "Clash 配置校验失败: $CONFIG_FILE" >&2
  write_run_state "failed" "config-test"
  exit 2
fi

# =========================
# 前台模式（systemd）
# =========================
if [ "$FOREGROUND" = true ]; then
  write_run_state "running" "systemd"
  exec "$CLASH_BIN" -f "$CONFIG_FILE" -d "$RUNTIME_DIR"
fi

# =========================
# 后台模式（脚本）
# =========================
cleanup_dead_pid

if is_script_running; then
  pid="$(read_pid 2>/dev/null || true)"
  ui_info "Clash 已在运行，pid=${pid:-未知}"
  exit 0
fi

nohup "$CLASH_BIN" -f "$CONFIG_FILE" -d "$RUNTIME_DIR" >>"$LOG_DIR/clash.log" 2>&1 &

pid=$!
echo "$pid" > "$PID_FILE"

write_run_state "running" "script" "$pid"

echo "[SUCCESS] 已以脚本模式启动 Clash，pid=$pid"