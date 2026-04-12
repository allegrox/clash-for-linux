#!/usr/bin/env bash

install_script_entry() {
  write_runtime_value "RUNTIME_BACKEND" "script"
  write_runtime_value "INSTALL_SCOPE" "$INSTALL_SCOPE"
}

remove_script_entry() {
  success "脚本运行模式无需删除服务文件"
}

script_service_start() {
  start_runtime
}

script_service_stop() {
  stop_runtime
}

script_service_restart() {
  stop_runtime || true
  start_runtime
}

script_service_status_text() {
  runtime_status_text
}

script_service_logs() {
  if [ ! -f "$LOG_DIR/mihomo.out.log" ]; then
    echo "日志文件不存在"
    return 0
  fi

  tail -n 200 "$LOG_DIR/mihomo.out.log"
}

install_runtime_entry() {
  if is_openwrt; then
    install_script_entry
    return 0
  fi

  if [ "$INSTALL_SCOPE" = "system" ] && systemd_available; then
    install_systemd_entry
    return 0
  fi

  if [ "$INSTALL_SCOPE" = "user" ] && systemd_user_available; then
    install_systemd_user_entry
    return 0
  fi

  install_script_entry
}

remove_runtime_entry() {
  local backend
  backend="$(runtime_backend)"

  case "$backend" in
    systemd)
      remove_systemd_entry
      ;;
    systemd-user)
      remove_systemd_user_entry
      ;;
    script)
      remove_script_entry
      ;;
    *)
      warn "未知运行后端：$backend，按脚本模式清理"
      remove_script_entry
      ;;
  esac
}

service_start() {
  local backend
  backend="$(runtime_backend)"

  case "$backend" in
    systemd)
      systemd_service_start
      ;;
    systemd-user)
      systemd_user_service_start
      ;;
    script)
      script_service_start
      ;;
    *)
      die "未知运行后端：$backend"
      ;;
  esac
}

service_stop() {
  local backend
  backend="$(runtime_backend)"

  case "$backend" in
    systemd)
      systemd_service_stop
      ;;
    systemd-user)
      systemd_user_service_stop
      ;;
    script)
      script_service_stop
      ;;
    *)
      die "未知运行后端：$backend"
      ;;
  esac
}

service_restart() {
  local backend
  backend="$(runtime_backend)"

  case "$backend" in
    systemd)
      systemd_service_restart
      ;;
    systemd-user)
      systemd_user_service_restart
      ;;
    script)
      script_service_restart
      ;;
    *)
      die "未知运行后端：$backend"
      ;;
  esac
}

service_is_running() {
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

service_status_text() {
  local backend
  backend="$(runtime_backend)"

  case "$backend" in
    systemd)
      systemd_service_status_text
      ;;
    systemd-user)
      systemd_user_service_status_text
      ;;
    script)
      script_service_status_text
      ;;
    *)
      echo "未知状态"
      ;;
  esac
}

service_logs() {
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
      script_service_logs
      ;;
    *)
      echo "未知运行后端，无法读取日志"
      ;;
  esac
}

wait_install_runtime_ready() {
  local max_try="${1:-4}"
  local i=0
  local runtime_ready="false"
  local controller_ready="false"

  while [ "$i" -lt "$max_try" ]; do
    if service_is_running 2>/dev/null; then
      runtime_ready="true"
    fi

    if proxy_controller_reachable 2>/dev/null; then
      controller_ready="true"
    fi

    if [ "$runtime_ready" = "true" ] && [ "$controller_ready" = "true" ]; then
      break
    fi

    sleep 1
    i=$((i + 1))
  done

  write_runtime_value "INSTALL_VERIFY_RUNTIME_READY" "$runtime_ready"
  write_runtime_value "INSTALL_VERIFY_CONTROLLER_READY" "$controller_ready"
}

post_install_verify() {
  local has_subscription="false"
  local runtime_ready="false"
  local controller_ready="false"

  if command -v clashctl >/dev/null 2>&1; then
    write_runtime_value "INSTALL_VERIFY_COMMAND_READY" "true"
  else
    write_runtime_value "INSTALL_VERIFY_COMMAND_READY" "false"
    write_runtime_event_value "RUNTIME_LAST_INSTALL_READY" "false"
    die "clashctl 安装失败，命令不可用"
  fi

  if [ -n "$(subscription_url 2>/dev/null || true)" ]; then
    has_subscription="true"
  fi

  if [ -s "$RUNTIME_DIR/config.yaml" ]; then
    write_runtime_value "INSTALL_VERIFY_CONFIG_READY" "true"
  else
    write_runtime_value "INSTALL_VERIFY_CONFIG_READY" "false"
  fi

  if [ "$has_subscription" = "true" ]; then
    if service_is_running 2>/dev/null; then
      service_restart >/dev/null 2>&1 || {
        service_stop >/dev/null 2>&1 || true
        service_start >/dev/null 2>&1 || true
      }
    else
      service_start >/dev/null 2>&1 || true
    fi
    wait_install_runtime_ready 4
  else
    write_runtime_value "INSTALL_VERIFY_RUNTIME_READY" "false"
    write_runtime_value "INSTALL_VERIFY_CONTROLLER_READY" "false"
  fi

  runtime_ready="$(install_verify_runtime_ready 2>/dev/null || true)"
  controller_ready="$(install_verify_controller_ready 2>/dev/null || true)"

  if [ "$has_subscription" = "true" ] \
    && [ "${runtime_ready:-false}" = "true" ] \
    && [ "${controller_ready:-false}" = "true" ]; then
    write_runtime_event_value "RUNTIME_LAST_INSTALL_READY" "true"
  else
    write_runtime_event_value "RUNTIME_LAST_INSTALL_READY" "false"
  fi
}
