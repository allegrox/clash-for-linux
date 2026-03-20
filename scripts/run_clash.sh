#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/runtime"
LOG_DIR="$PROJECT_DIR/logs"
CONFIG_FILE="$RUNTIME_DIR/config.yaml"
PID_FILE="$RUNTIME_DIR/clash.pid"

mkdir -p "$RUNTIME_DIR" "$LOG_DIR"

FOREGROUND=false
DAEMON=false

# 解析参数
for arg in "$@"; do
  case "$arg" in
    --foreground) FOREGROUND=true ;;
    --daemon) DAEMON=true ;;
    *)
      echo "[ERROR] Unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

if [ "$FOREGROUND" = true ] && [ "$DAEMON" = true ]; then
  echo "[ERROR] Cannot use both --foreground and --daemon" >&2
  exit 2
fi

if [ ! -s "$CONFIG_FILE" ]; then
  echo "[ERROR] runtime config not found: $CONFIG_FILE" >&2
  exit 2
fi

if grep -q '\${' "$CONFIG_FILE"; then
  echo "[ERROR] unresolved placeholder found in $CONFIG_FILE" >&2
  exit 2
fi

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/get_cpu_arch.sh"
# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/resolve_clash.sh"
# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/service_lib.sh"

CLASH_BIN="$(resolve_clash_bin "$PROJECT_DIR" "${CpuArch:-}")"

if [ ! -x "$CLASH_BIN" ]; then
  echo "[ERROR] clash binary not found or not executable: $CLASH_BIN" >&2
  exit 2
fi

test_config() {
  local bin="$1"
  local config="$2"
  local runtime_dir="$3"
  "$bin" -d "$runtime_dir" -t -f "$config" >/dev/null 2>&1
}

if ! test_config "$CLASH_BIN" "$CONFIG_FILE" "$RUNTIME_DIR"; then
  echo "[ERROR] config test failed: $CONFIG_FILE" >&2
  exit 2
fi

# systemd 模式
if [ "$FOREGROUND" = true ]; then
  write_run_state "running" "systemd"
  exec "$CLASH_BIN" -f "$CONFIG_FILE" -d "$RUNTIME_DIR"
fi

# script / daemon 模式
if [ "$DAEMON" = true ]; then
  nohup "$CLASH_BIN" -f "$CONFIG_FILE" -d "$RUNTIME_DIR" >>"$LOG_DIR/clash.log" 2>&1 &
  pid=$!
  echo "$pid" > "$PID_FILE"
  write_run_state "running" "script" "$pid"
  echo "[OK] Clash started in script mode, pid=$pid"
  exit 0
fi

echo "[ERROR] Must specify --foreground or --daemon" >&2
exit 2