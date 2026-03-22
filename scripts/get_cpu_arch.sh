#!/bin/bash
# 作用：获取当前 Linux 系统的 CPU 架构信息，并输出到标准输出

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! declare -f ui_info >/dev/null 2>&1; then
  # shellcheck source=scripts/ui.sh
  source "$PROJECT_DIR/scripts/ui.sh"
fi

exitWithError() {
    local errorMessage="$1"
    echo -e "\033[31m[ERROR] $errorMessage\033[0m" >&2
    exit 1
}

# 获取 CPU 架构
get_cpu_arch() {
    local commands=("$@")
    for cmd in "${commands[@]}"; do
        local CpuArch
        CpuArch=$(command -v $cmd >/dev/null && $cmd 2>/dev/null || type -p $cmd 2>/dev/null)
        if [[ -n "$CpuArch" ]]; then
            echo "$CpuArch"
            return
        fi
    done
}

# 判断系统发行版
if [[ -f "/etc/os-release" ]]; then
    . /etc/os-release
    case "$ID" in
        "ubuntu"|"debian"|"linuxmint")
            # Debian 系发行版
            CpuArch=$(get_cpu_arch "dpkg-architecture -qDEB_HOST_ARCH_CPU" "dpkg-architecture -qDEB_BUILD_ARCH_CPU" "uname -m")
            ;;
        "centos"|"fedora"|"rhel")
            # Red Hat 系发行版
            CpuArch=$(get_cpu_arch "uname -m" "arch" "uname")
            ;;
        *)
            # 未明确支持的 Linux 发行版
            CpuArch=$(get_cpu_arch "uname -m" "arch" "uname")
            if [[ -z "$CpuArch" ]]; then
                exitWithError "获取 CPU 架构失败"
            fi
            ;;
    esac
elif [[ -f "/etc/redhat-release" ]]; then
    # 老版本 Red Hat 系
    CpuArch=$(get_cpu_arch "uname -m" "arch" "uname")
else
    exitWithError "不支持的 Linux 发行版"
fi

ui_info "CPU 架构: $CpuArch"