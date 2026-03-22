#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! declare -f ui_info >/dev/null 2>&1; then
  # shellcheck source=scripts/ui.sh
  source "$PROJECT_DIR/scripts/ui.sh"
fi

trim_value() {
	local value="$1"
	echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# =========================
# 安全写入：避免重复块
# =========================
remove_block_if_exists() {
	local file="$1"
	local marker="$2"

	[ -f "$file" ] || return 0

	# 删除已有 block（从 marker 到文件结束）
	if grep -q "$marker" "$file"; then
		sed -i "/$marker/,\$d" "$file"
	fi
}

# =========================
# TUN 配置
# =========================
apply_tun_config() {
	local config_path="$1"

	local enable="${CLASH_TUN_ENABLE:-false}"
	[ "$enable" = "true" ] || return 0

	remove_block_if_exists "$config_path" "# ==== TUN CONFIG START ===="

	local stack="${CLASH_TUN_STACK:-system}"
	local auto_route="${CLASH_TUN_AUTO_ROUTE:-true}"
	local auto_redirect="${CLASH_TUN_AUTO_REDIRECT:-false}"
	local strict_route="${CLASH_TUN_STRICT_ROUTE:-false}"
	local device="${CLASH_TUN_DEVICE:-}"
	local mtu="${CLASH_TUN_MTU:-}"
	local dns_hijack="${CLASH_TUN_DNS_HIJACK:-}"

	{
		echo ""
		echo "# ==== TUN CONFIG START ===="
		echo "tun:"
		echo "  enable: true"
		echo "  stack: ${stack}"
		echo "  auto-route: ${auto_route}"
		echo "  auto-redirect: ${auto_redirect}"
		echo "  strict-route: ${strict_route}"

		[ -n "$device" ] && echo "  device: ${device}"
		[ -n "$mtu" ] && echo "  mtu: ${mtu}"

		if [ -n "$dns_hijack" ]; then
			echo "  dns-hijack:"
			IFS=',' read -r -a hijacks <<< "$dns_hijack"
			for item in "${hijacks[@]}"; do
				item="$(trim_value "$item")"
				[ -n "$item" ] && echo "    - ${item}"
			done
		fi

		echo "# ==== TUN CONFIG END ===="
	} >> "$config_path"
}

# =========================
# MIXIN 配置
# =========================
apply_mixin_config() {
	local config_path="$1"
	local base_dir="$2"

	local mixin_dir="${CLASH_MIXIN_DIR:-$base_dir/config/mixin.d}"
	local mixin_paths=()

	remove_block_if_exists "$config_path" "# ==== MIXIN CONFIG START ===="

	# 用户手动指定优先
	if [ -n "${CLASH_MIXIN_PATHS:-}" ]; then
		IFS=',' read -r -a mixin_paths <<< "$CLASH_MIXIN_PATHS"
	fi

	# 自动扫描目录（补充）
	if [ -d "$mixin_dir" ]; then
		while IFS= read -r -d '' file; do
			mixin_paths+=("$file")
		done < <(
			find "$mixin_dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) \
			-print0 | sort -z
		)
	fi

	# 去重
	local uniq_paths=()
	local seen=""

	for path in "${mixin_paths[@]}"; do
		path="$(trim_value "$path")"
		[ -z "$path" ] && continue

		# 相对路径转绝对
		if [ "${path:0:1}" != "/" ]; then
			path="$base_dir/$path"
		fi

		if [[ "$seen" != *"|$path|"* ]]; then
			uniq_paths+=("$path")
			seen="${seen}|$path|"
		fi
	done

	# 写入
	{
		echo ""
		echo "# ==== MIXIN CONFIG START ===="

		for path in "${uniq_paths[@]}"; do
			if [ -f "$path" ]; then
				echo ""
				echo "# ---- mixin: ${path} ----"
				cat "$path"
			else
				ui_warn "Mixin not found: $path" >&2
			fi
		done

		echo "# ==== MIXIN CONFIG END ===="
	} >> "$config_path"
}