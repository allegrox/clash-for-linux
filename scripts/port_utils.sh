#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! declare -f ui_info >/dev/null 2>&1; then
  # shellcheck source=scripts/ui.sh
  source "$PROJECT_DIR/scripts/ui.sh"
fi

PORT_CHECK_WARNED=${PORT_CHECK_WARNED:-0}

# =========================
# 判断端口是否被占用（更稳）
# =========================
is_port_in_use() {
	local port="$1"

	if command -v ss >/dev/null 2>&1; then
		ss -lnt 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null 2>&1
		return $?
	fi

	if command -v netstat >/dev/null 2>&1; then
		netstat -lnt 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null 2>&1
		return $?
	fi

	if command -v lsof >/dev/null 2>&1; then
		lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk '{print $9}' | grep -E "[:.]${port}$" >/dev/null 2>&1
		return $?
	fi

	if [ "$PORT_CHECK_WARNED" -eq 0 ]; then
		ui_warn "未检测到端口检查工具（ss/netstat/lsof）" >&2
		PORT_CHECK_WARNED=1
	fi

	return 1
}

# =========================
# 找可用端口（优化版）
# =========================
find_available_port() {
	local start="${1:-20000}"
	local end="${2:-65000}"
	local port

	# 优先随机尝试
	if command -v shuf >/dev/null 2>&1; then
		for _ in {1..30}; do
			port=$(shuf -i "${start}-${end}" -n 1)
			if ! is_port_in_use "$port"; then
				echo "$port"
				return 0
			fi
		done
	fi

	# fallback 顺序扫描（限制范围避免慢）
	for port in $(seq "$start" "$((start + 2000))"); do
		if ! is_port_in_use "$port"; then
			echo "$port"
			return 0
		fi
	done

	return 1
}

# =========================
# 解析端口值（核心函数）
# =========================
resolve_port_value() {
  local name="$1"
  local value="$2"
  local resolved

  # auto / 空
  if [ -z "$value" ] || [ "$value" = "auto" ]; then
    resolved=$(find_available_port) || {
      ui_error "${name} 端口分配失败" >&2
      return 1
    }
    ui_warn "${name} 自动分配端口: ${resolved}" >&2
    echo "$resolved"
    return 0
  fi

  # 非数字
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    ui_error "非法端口: $value" >&2
    return 1
  fi

  # 被占用 → 自动替换
  if is_port_in_use "$value"; then
    resolved=$(find_available_port)
    if [ -n "$resolved" ]; then
      ui_warn "${name} 端口 ${value} 已被占用，已切换为 ${resolved}" >&2
      echo "$resolved"
      return 0
    fi
  fi

  echo "$value"
}

# =========================
# 解析 host:port
# =========================
resolve_host_port() {
	local name="$1"
	local raw="$2"
	local default_host="$3"

	local host
	local port

	if [ -z "$raw" ] || [ "$raw" = "auto" ]; then
		host="$default_host"
		port="auto"
	else
		if [[ "$raw" == *:* ]]; then
			host="${raw%:*}"
			port="${raw##*:}"
		else
			host="$default_host"
			port="$raw"
		fi
	fi

	# host 兜底
	[ -z "$host" ] && host="$default_host"

	port=$(resolve_port_value "$name" "$port") || return 1

	echo "${host}:${port}"
}