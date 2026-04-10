#!/usr/bin/env bash

_clashctl_real() {
  if command -v clashctl-bin >/dev/null 2>&1; then
    clashctl-bin "$@"
    return $?
  fi

  command clashctl "$@"
}

_clash_alias_project_dir() {
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  echo "$self_dir"
}

_clash_alias_state_file() {
  echo "$(_clash_alias_project_dir)/runtime/shell-proxy.env"
}

_clash_alias_set_persist_enabled() {
  local enabled="$1"
  local state_file
  state_file="$(_clash_alias_state_file)"

  mkdir -p "$(dirname "$state_file")"
  cat > "$state_file" <<EOF
SHELL_PROXY_PERSIST_ENABLED="${enabled}"
SHELL_PROXY_PERSIST_TIME="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
EOF
}

_clash_alias_persist_enabled() {
  local state_file enabled
  state_file="$(_clash_alias_state_file)"
  [ -f "$state_file" ] || return 1

  enabled="$(sed -nE 's/^SHELL_PROXY_PERSIST_ENABLED=\"?([^\"\r\n]+)\"?$/\1/p' "$state_file" | head -n 1)"
  [ "${enabled:-false}" = "true" ]
}

_clash_alias_print_sep() {
  echo
}

_clash_alias_proxy_on() {
  eval "$(_clashctl_real proxy on)" || return $?
}

_clash_alias_proxy_off() {
  eval "$(_clashctl_real proxy off)" || true
}

_clash_alias_proxy_show() {
  _clashctl_real proxy show 2>/dev/null || true
}

_clash_alias_status_next() {
  _clashctl_real status-next 2>/dev/null || echo "clashctl status"
}

_clash_alias_prepare_on() {
  # 这里不直接自己做 regenerate / restart / fallback，
  # 而是统一交给 clashctl on 主链处理，避免双执行链。
  # shell 层只负责“闭环体验”，不抢 runtime / build 的职责。
  return 0
}

_clash_alias_after_on() {
  _clash_alias_set_persist_enabled "true"
  _clash_alias_proxy_on || return $?

  _clash_alias_print_sep
  _clash_alias_proxy_show

  if [ "${CLASH_WRAPPER_EXEC:-0}" = "1" ]; then
    echo "⚠️ 当前通过独立命令执行，Shell 变量不会自动回写到父终端"
    echo '💡 请在当前终端执行：eval "$(clashctl proxy on)"'
  fi

  echo "👉 下一步：$(_clash_alias_status_next)"
}

_clash_alias_after_off() {
  _clash_alias_set_persist_enabled "false"
  _clash_alias_print_sep
  echo "🔴 已关闭代理环境"
  echo "🧹 当前 Shell 代理变量已清理"
  if [ "${CLASH_WRAPPER_EXEC:-0}" = "1" ]; then
    echo '💡 若当前终端仍有代理变量，请执行：eval "$(clashctl proxy off)"'
  fi
  echo "🧭 新终端默认代理：已关闭"
  echo "👉 下一步：clashctl status"
}

_clash_alias_run_on() {
  _clash_alias_prepare_on || return $?

  _clashctl_real on "$@" || return $?

  _clash_alias_after_on || return $?
}

_clash_alias_run_off() {
  _clash_alias_proxy_off
  _clash_alias_set_persist_enabled "false"
  _clashctl_real off "$@" || return $?
  _clash_alias_after_off
}

_clash_alias_auto_restore_proxy() {
  [ "${CLASH_FOR_LINUX_PROXY_AUTO_RESTORED:-0}" = "1" ] && return 0
  export CLASH_FOR_LINUX_PROXY_AUTO_RESTORED="1"

  if _clash_alias_persist_enabled; then
    _clash_alias_proxy_on >/dev/null 2>&1 || true
  fi
}

clashctl() {
  case "${1:-}" in
    on)
      shift || true
      _clash_alias_run_on "$@"
      ;;
    off)
      shift || true
      _clash_alias_run_off "$@"
      ;;
    proxy)
      case "${2:-}" in
        on)
          _clash_alias_proxy_on || return $?
          _clash_alias_print_sep
          _clash_alias_proxy_show
          ;;
        off)
          _clash_alias_proxy_off
          _clash_alias_print_sep
          echo "🧹 当前 Shell 代理变量已清理"
          ;;
        *)
          _clashctl_real "$@"
          ;;
      esac
      ;;
    ui)
      shift || true
      # ui 前如果 runtime 已运行但当前 shell 没代理，不强制注入；
      # 保持 UI 行为纯粹，只走原命令。
      _clashctl_real ui "$@"
      ;;
    status)
      shift || true
      _clashctl_real status "$@"
      ;;
    *)
      _clashctl_real "$@"
      ;;
  esac
}

# 快捷入口全部收敛到 clashctl 函数
clashon() {
  clashctl on "$@" || return $?
}

clashoff() {
  clashctl off "$@" || return $?
}

clashproxy() {
  case "${1:-show}" in
    on)
      clashctl proxy on
      ;;
    off)
      clashctl proxy off
      ;;
    show|status)
      clashctl proxy show
      ;;
    groups)
      clashctl proxy groups
      ;;
    current)
      shift || true
      clashctl proxy current "$@"
      ;;
    nodes)
      shift || true
      clashctl proxy nodes "$@"
      ;;
    select)
      shift || true
      clashctl proxy select "$@"
      ;;
    *)
      echo "🧭 用法：clashproxy [show|on|off|groups|current|nodes|select]"
      echo "💡 主路径切节点请使用：clashselect 或 clashctl select"
      return 2
      ;;
  esac
}

clashls() {
  clashctl ls "$@"
}

clashselect() {
  clashctl select "$@"
}

clashui() {
  clashctl ui "$@"
}

clashsecret() {
  clashctl secret "$@"
}

clashtun() {
  clashctl tun "$@"
}

clashupgrade() {
  clashctl upgrade "$@"
}

clashmixin() {
  case "${1:-}" in
    -e|--edit)
      clashctl mixin edit
      ;;
    -c|--raw)
      clashctl mixin raw
      ;;
    -r|--runtime)
      clashctl mixin runtime
      ;;
    "")
      clashctl mixin
      ;;
    *)
      clashctl mixin "$@"
      ;;
  esac
}

# shell 被 source 后做轻量恢复：
# 若上次 clashon 持久化开启，则新终端自动恢复当前 shell 代理变量。
_clash_alias_auto_restore_proxy
