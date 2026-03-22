#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! declare -f ui_info >/dev/null 2>&1; then
  # shellcheck source=scripts/ui.sh
  source "$PROJECT_DIR/scripts/ui.sh"
fi

# 作用：
# - 将订阅内容转换为 Clash Meta / Mihomo 可用的完整 YAML 配置
# - 默认使用 subconverter HTTP /sub 接口（最稳：使用 -G + --data-urlencode）
# - 转换失败则跳过，不影响主流程
#
# 输入 / 输出约定：
# - IN_FILE：原始订阅（默认 temp/clash.yaml）
# - OUT_FILE：转换后的配置（默认 temp/clash_config.yaml）
#
# 设计原则：
# - 绝不 exit 1（失败只输出 warn 并 exit 0）
# - 如果本身已是完整 Clash 配置，则直接复制
# - 如果没有 CLASH_URL（原始订阅 URL），则不执行转换（subconverter 最稳妥的方式是 url=...）

Server_Dir="${Server_Dir:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
Temp_Dir="${Temp_Dir:-$Server_Dir/temp}"

mkdir -p "$Temp_Dir"

IN_FILE="${IN_FILE:-$Temp_Dir/clash.yaml}"
OUT_FILE="${OUT_FILE:-$Temp_Dir/clash_config.yaml}"

# 更推荐的默认目标：Clash Meta / Mihomo
SUB_TARGET="${SUB_TARGET:-clashmeta}"   # 推荐 clashmeta（兼容性最好）
SUB_URL="${CLASH_URL:-}"               # 原始订阅 URL（.env 中 export CLASH_URL=...）

# 0) 输入文件不存在则跳过
if [ ! -s "$IN_FILE" ]; then
  ui_warn "未找到输入文件: $IN_FILE"
  exit 0
fi

# 1) 如果看起来已经是完整 Clash 配置，则直接使用，不再转换
#    （包含 proxies / proxy-providers / rules / port 等任一关键字即可视为完整配置）
if grep -qE '^(proxies:|proxy-providers:|mixed-port:|port:|rules:|dns:)' "$IN_FILE"; then
  cp -f "$IN_FILE" "$OUT_FILE"
  ui_ok "输入内容已是 Clash 配置，直接使用 -> $OUT_FILE"
  exit 0
fi

# 2) subconverter 不可用则跳过
if [ "${SUBCONVERTER_READY:-false}" != "true" ] || [ -z "${SUBCONVERTER_URL:-}" ]; then
  ui_warn "subconverter 未就绪，跳过转换"
  exit 0
fi

# 3) 没有原始 URL 则不转换（subconverter 最稳妥的方式是 url=... 拉取）
if [ -z "${SUB_URL:-}" ]; then
  ui_warn "CLASH_URL 为空，无法通过 /sub 转换，已跳过"
  exit 0
fi

# 4) 调用 subconverter：使用 -G + --data-urlencode，避免 url 参数中包含 ? 和 & 导致 400
#    注意：SUB_URL 必须为原始订阅 URL（例如 https://.../subscribe?token=xxx）
TMP_OUT="${OUT_FILE}.tmp"
rm -f "$TMP_OUT" 2>/dev/null || true

set +e
curl -fsSLG "${SUBCONVERTER_URL}/sub" \
  --data-urlencode "target=${SUB_TARGET}" \
  --data-urlencode "url=${SUB_URL}" \
  -o "${TMP_OUT}"
rc=$?
set -e

if [ "$rc" -ne 0 ] || [ ! -s "$TMP_OUT" ]; then
  ui_warn "转换失败（rc=${rc}），已跳过"
  rm -f "$TMP_OUT" 2>/dev/null || true
  exit 0
fi

mv -f "$TMP_OUT" "$OUT_FILE"
ui_ok "已通过 subconverter 完成转换 -> ${OUT_FILE} (target=${SUB_TARGET})"

true