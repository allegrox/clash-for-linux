#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! declare -f ui_info >/dev/null 2>&1; then
  # shellcheck source=scripts/ui.sh
  source "$PROJECT_DIR/scripts/ui.sh"
fi


# 作用：
# - 根据 OS/ARCH 选择 tools/subconverter/<platform>/subconverter
# - 生成稳定入口 tools/subconverter/subconverter（优先软链接，失败则复制）
# -（可选）以守护进程模式启动本地 subconverter（HTTP 服务）
# - 导出统一变量供后续脚本使用：
#   SUBCONVERTER_BIN / SUBCONVERTER_READY / SUBCONVERTER_URL
#
# 设计原则：
# - 永不 exit 1（不可用时标记 Ready=false，主流程继续）
# - 不阻塞 start.sh（快速启动，不等待健康检查）

Server_Dir="${Server_Dir:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
Temp_Dir="${Temp_Dir:-$Server_Dir/temp}"

mkdir -p "$Temp_Dir"

SC_DIR="$Server_Dir/tools/subconverter"
SC_LINK="$SC_DIR/subconverter"   # 稳定入口（统一调用路径）
Subconverter_Bin="$SC_LINK"
Subconverter_Ready=false

# 配置项（可写入 .env）
SUBCONVERTER_MODE="${SUBCONVERTER_MODE:-daemon}"     # daemon | off
SUBCONVERTER_HOST="${SUBCONVERTER_HOST:-127.0.0.1}"
SUBCONVERTER_PORT="${SUBCONVERTER_PORT:-25500}"
SUBCONVERTER_URL="${SUBCONVERTER_URL:-http://${SUBCONVERTER_HOST}:${SUBCONVERTER_PORT}}"

# pref.ini：不存在则从示例生成
SUBCONVERTER_PREF="${SUBCONVERTER_PREF:-$SC_DIR/pref.ini}"
PREF_EXAMPLE_INI="$SC_DIR/pref.example.ini"

PID_FILE="$Temp_Dir/subconverter.pid"

detect_os() {
  local u
  u="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$u" in
    linux*) echo "linux" ;;
    *) echo "unsupported" ;;
  esac
}

detect_arch() {
  local m
  m="$(uname -m | tr '[:upper:]' '[:lower:]')"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    *) echo "unknown" ;;
  esac
}

pick_platform_bin() {
  local os="$1" arch="$2"
  local p="$SC_DIR/${os}-${arch}/subconverter"
  if [ -f "$p" ]; then
    echo "$p"
    return 0
  fi
  echo ""
  return 0
}

make_stable_link_or_copy() {
  local src="$1"

  # 确保可执行
  chmod +x "$src" 2>/dev/null || true

  # 清理旧入口
  rm -f "$SC_LINK" 2>/dev/null || true

  # 优先创建软链接，失败则复制
  if ln -s "$src" "$SC_LINK" 2>/dev/null; then
    :
  else
    cp -f "$src" "$SC_LINK" 2>/dev/null || return 1
    chmod +x "$SC_LINK" 2>/dev/null || true
  fi
  return 0
}

is_port_listening() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lnt | awk '{print $4}' | grep -q ":${port}\$" && return 0
  fi
  # 无检测工具则不判断
  return 1
}

main() {
  # 0) 用户主动关闭
  if [ "$SUBCONVERTER_MODE" = "off" ]; then
    Subconverter_Ready=false
    export Subconverter_Bin Subconverter_Ready SUBCONVERTER_BIN SUBCONVERTER_READY SUBCONVERTER_URL
    true
    return 0
  fi

  # 1) 选择平台二进制
  local os arch platform_bin
  os="$(detect_os)"
  arch="$(detect_arch)"

  if [ "$os" = "unsupported" ]; then
    ui_warn "不支持的操作系统: $(uname -s)，跳过 subconverter"
    Subconverter_Ready=false
    export Subconverter_Bin Subconverter_Ready SUBCONVERTER_BIN SUBCONVERTER_READY SUBCONVERTER_URL
    true
    return 0
  fi

  if [ "$arch" = "unknown" ]; then
    ui_warn "不支持的架构: $(uname -m)，跳过 subconverter"
    Subconverter_Ready=false
    export Subconverter_Bin Subconverter_Ready SUBCONVERTER_BIN SUBCONVERTER_READY SUBCONVERTER_URL
    true
    return 0
  fi

  platform_bin="$(pick_platform_bin "$os" "$arch")"
  if [ -z "$platform_bin" ]; then
    ui_warn "未找到 subconverter 二进制: $SC_DIR/${os}-${arch}/subconverter"
    Subconverter_Ready=false
    export Subconverter_Bin Subconverter_Ready SUBCONVERTER_BIN SUBCONVERTER_READY SUBCONVERTER_URL
    true
    return 0
  fi

  # 2) 创建稳定入口
  if ! make_stable_link_or_copy "$platform_bin"; then
    ui_warn "创建稳定入口失败: $SC_LINK"
    Subconverter_Ready=false
    export Subconverter_Bin Subconverter_Ready SUBCONVERTER_BIN SUBCONVERTER_READY SUBCONVERTER_URL
    true
    return 0
  fi

  Subconverter_Bin="$SC_LINK"
  Subconverter_Ready=true
  ui_info "已解析平台二进制: ${os}-${arch} -> $Subconverter_Bin"

  # 3) 生成 pref.ini（仅 daemon 模式）
  if [ "$Subconverter_Ready" = "true" ] && [ "$SUBCONVERTER_MODE" = "daemon" ]; then
    if [ ! -f "$SUBCONVERTER_PREF" ] && [ -f "$PREF_EXAMPLE_INI" ]; then
      cp -f "$PREF_EXAMPLE_INI" "$SUBCONVERTER_PREF"
    fi
  fi

  # 4) 启动 daemon
  if [ "$Subconverter_Ready" = "true" ] && [ "$SUBCONVERTER_MODE" = "daemon" ]; then
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
      :
    else
      if is_port_listening "$SUBCONVERTER_PORT"; then
        :
      else
        (
          cd "$SC_DIR"
          nohup "$Subconverter_Bin" -f "$SUBCONVERTER_PREF" >/dev/null 2>&1 &
          echo $! > "$PID_FILE"
        )
        sleep 0.2
      fi
    fi
  fi

  # 5) 导出变量
  export Subconverter_Bin
  export Subconverter_Ready
  export SUBCONVERTER_BIN="$Subconverter_Bin"
  export SUBCONVERTER_READY="$Subconverter_Ready"
  export SUBCONVERTER_URL

  true
}

main "$@"