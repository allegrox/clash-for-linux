#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! declare -f ui_info >/dev/null 2>&1; then
  # shellcheck source=scripts/ui.sh
  source "$PROJECT_DIR/scripts/ui.sh"
fi


PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/runtime"
PID_FILE="$RUNTIME_DIR/clash.pid"
STATE_FILE="$RUNTIME_DIR/state.env"
SERVICE_NAME="clash-for-linux.service"

mkdir -p "$RUNTIME_DIR"

# =========================
# 基础能力
# =========================
has_systemd() {
  command -v systemctl >/dev/null 2>&1
}

service_unit_exists() {
  has_systemd || return 1
  systemctl show "$SERVICE_NAME" -p LoadState --value 2>/dev/null | grep -q '^loaded$'
}

read_pid() {
  [ -s "$PID_FILE" ] || return 1
  tr -d '[:space:]' < "$PID_FILE"
}

is_pid_running() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

is_script_running() {
  local pid
  pid="$(read_pid 2>/dev/null || true)"
  is_pid_running "$pid"
}

# =========================
# 清理僵尸 PID（关键）
# =========================
cleanup_dead_pid() {
  local pid
  pid="$(read_pid 2>/dev/null || true)"

  if [ -n "${pid:-}" ] && ! is_pid_running "$pid"; then
    rm -f "$PID_FILE"
  fi
}

# =========================
# 模式检测（统一）
# =========================
detect_mode() {
  cleanup_dead_pid

  if service_unit_exists && systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "systemd"
  elif is_script_running; then
    echo "script"
  elif service_unit_exists; then
    echo "systemd-installed"
  else
    echo "none"
  fi
}

# =========================
# state 写入（唯一实现）
# =========================
write_state_kv() {
  local key="$1"
  local value="$2"

  mkdir -p "$RUNTIME_DIR"
  touch "$STATE_FILE"

  if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$STATE_FILE"
  else
    echo "${key}=${value}" >> "$STATE_FILE"
  fi
}

write_run_state() {
  local status="${1:-unknown}"
  local mode="${2:-unknown}"
  local pid="${3:-}"

  write_state_kv "LAST_RUN_STATUS" "$status"
  write_state_kv "LAST_RUN_MODE" "$mode"
  write_state_kv "LAST_RUN_AT" "$(date -Iseconds)"

  if [ -n "$pid" ]; then
    write_state_kv "LAST_RUN_PID" "$pid"
  fi
}

# =========================
# systemd 模式
# =========================
start_via_systemd() {
  systemctl start "$SERVICE_NAME"
}

stop_via_systemd() {
  systemctl stop "$SERVICE_NAME" || true
  cleanup_dead_pid
  write_run_state "stopped" "systemd"
}

restart_via_systemd() {
  systemctl restart "$SERVICE_NAME"
}

# =========================
# script 模式
# =========================
start_via_script() {
  cleanup_dead_pid

  if is_script_running; then
    ui_info "clash already running (script)"
    return 0
  fi

  "$PROJECT_DIR/scripts/run_clash.sh" --daemon
}

stop_via_script() {
  local pid
  pid="$(read_pid 2>/dev/null || true)"

  if [ -n "${pid:-}" ] && is_pid_running "$pid"; then
    ui_info "stopping clash pid=$pid"

    kill "$pid" 2>/dev/null || true

    for _ in 1 2 3 4 5; do
      if ! is_pid_running "$pid"; then
        break
      fi
      sleep 1
    done

    if is_pid_running "$pid"; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi

  rm -f "$PID_FILE"
  write_run_state "stopped" "script"
}

restart_via_script() {
  stop_via_script || true
  start_via_script
}