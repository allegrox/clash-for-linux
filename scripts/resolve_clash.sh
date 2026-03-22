PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! declare -f ui_info >/dev/null 2>&1; then
  # shellcheck source=scripts/ui.sh
  source "$PROJECT_DIR/scripts/ui.sh"
fi

resolve_clash_arch() {
	local raw_arch="$1"
	case "$raw_arch" in
		x86_64|amd64) echo "linux-amd64" ;;
		aarch64|arm64) echo "linux-arm64" ;;
		armv7*|armv7l) echo "linux-armv7" ;;
		*) echo "linux-${raw_arch}" ;;
	esac
}

get_latest_mihomo_version() {
	local url="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url" \
			| grep '"tag_name"' \
			| sed -E 's/.*"([^"]+)".*/\1/' \
			| head -n 1
	elif command -v wget >/dev/null 2>&1; then
		wget -qO- "$url" \
			| grep '"tag_name"' \
			| sed -E 's/.*"([^"]+)".*/\1/' \
			| head -n 1
	fi
}

download_clash_bin() {
	local server_dir="$1"
	local detected_arch="$2"

	local resolved_arch
	local version
	local download_url

	local download_target
	local archive_file
	local tmp_bin

	resolved_arch="$(resolve_clash_arch "$detected_arch")"

	if [ -z "$resolved_arch" ]; then
		ui_warn "无法识别 CPU 架构" >&2
		return 1
	fi

	version="${MIHOMO_VERSION:-}"
	if [ -z "$version" ]; then
		version="$(get_latest_mihomo_version || true)"
	fi

	if [ -z "$version" ]; then
		ui_error "无法获取 Mihomo 版本" >&2
		return 1
	fi

	if [ -z "${CLASH_DOWNLOAD_URL_TEMPLATE:-}" ]; then
		ui_error "CLASH_DOWNLOAD_URL_TEMPLATE 未设置" >&2
		return 1
	fi

	download_url="${CLASH_DOWNLOAD_URL_TEMPLATE//\{arch\}/${resolved_arch}}"
	download_url="${download_url//\{version\}/${version}}"

	download_target="${server_dir}/bin/clash-${resolved_arch}"
	archive_file="${server_dir}/runtime/.clash_download.tmp"
	tmp_bin="${server_dir}/runtime/.clash_bin.tmp"

	mkdir -p "${server_dir}/bin" "${server_dir}/runtime"

	rm -f "$archive_file" "$tmp_bin"

	ui_info "downloading: $download_url"

	# =========================
	# 下载
	# =========================
	if command -v curl >/dev/null 2>&1; then
		if ! curl -fL -sS -o "$archive_file" "$download_url"; then
			ui_error "下载失败: $download_url" >&2
			return 1
		fi
	elif command -v wget >/dev/null 2>&1; then
		if ! wget -q -O "$archive_file" "$download_url"; then
			ui_error "下载失败: $download_url" >&2
			return 1
		fi
	else
		ui_error "未找到 curl 或 wget" >&2
		return 1
	fi

	# =========================
	# 基础校验（防 404 / HTML）
	# =========================
	if [ ! -s "$archive_file" ]; then
		ui_error "下载文件为空" >&2
		return 1
	fi

	if head -c 200 "$archive_file" | grep -qiE "not found|html"; then
		ui_error "下载内容疑似错误页面（404/HTML）" >&2
		return 1
	fi

	# =========================
	# 解压 / 直写
	# =========================
	if gzip -t "$archive_file" >/dev/null 2>&1; then
		if ! gzip -dc "$archive_file" > "$tmp_bin"; then
			ui_error "gzip 解压失败" >&2
			return 1
		fi
	else
		cp "$archive_file" "$tmp_bin"
	fi

	# =========================
	# ELF 校验（关键）
	# =========================
	if ! file "$tmp_bin" | grep -q "ELF"; then
		ui_error "非有效 ELF 二进制" >&2
		echo "[DEBUG] file result: $(file "$tmp_bin")" >&2
		return 1
	fi

	chmod +x "$tmp_bin"
	mv "$tmp_bin" "$download_target"

	rm -f "$archive_file"

	ui_ok "downloaded: $download_target"
	echo "$download_target"
}

resolve_clash_bin() {
	local server_dir="$1"
	local detected_arch="$2"

	local resolved_arch
	local candidates=()
	local candidate
	local downloaded_bin
	local mode

	if [ -n "${CLASH_BIN:-}" ]; then
		if [ -x "$CLASH_BIN" ]; then
			echo "$CLASH_BIN"
			return 0
		fi
		ui_error "CLASH_BIN 不可执行: $CLASH_BIN" >&2
		return 1
	fi

	resolved_arch="$(resolve_clash_arch "$detected_arch")"

	if [ -n "$resolved_arch" ]; then
		candidates+=("${server_dir}/bin/clash-${resolved_arch}")
	fi

	candidates+=(
		"${server_dir}/bin/clash-${detected_arch}"
		"${server_dir}/bin/clash"
	)

	mode="${CLASH_AUTO_DOWNLOAD:-auto}"

	case "$mode" in
		false)
			for candidate in "${candidates[@]}"; do
				if [ -x "$candidate" ]; then
					echo "$candidate"
					return 0
				fi
			done
			;;

		auto)
			for candidate in "${candidates[@]}"; do
				if [ -x "$candidate" ]; then
					echo "$candidate"
					return 0
				fi
			done

			if downloaded_bin="$(download_clash_bin "$server_dir" "$detected_arch")"; then
				echo "$downloaded_bin"
				return 0
			fi
			;;

		true)
			if downloaded_bin="$(download_clash_bin "$server_dir" "$detected_arch")"; then
				echo "$downloaded_bin"
				return 0
			fi

			for candidate in "${candidates[@]}"; do
				if [ -x "$candidate" ]; then
					echo "$candidate"
					return 0
				fi
			done
			;;

		*)
			ui_error "CLASH_AUTO_DOWNLOAD 非法值: $mode" >&2
			return 1
			;;
	esac

	ui_error "未找到可用 Mihomo 内核" >&2
	echo "请放入: ${server_dir}/bin/" >&2
	return 1
}