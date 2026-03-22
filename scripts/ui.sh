#!/usr/bin/env bash

# ============================================
# clashctl UI library (scripts/ui.sh)
# ============================================

# ---------- color ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_CYAN=''
fi

# ---------- unicode / ascii fallback ----------
_ui_is_utf8() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf8*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "${CLASHCTL_ASCII:-0}" = "1" ] || ! _ui_is_utf8; then
  ICON_OK="OK"
  ICON_WARN="!!"
  ICON_ERR="XX"
  ICON_INFO="i"

  BOX_TL="+"
  BOX_TR="+"
  BOX_BL="+"
  BOX_BR="+"
  BOX_H="-"
  BOX_V="|"
  BOX_JL="+"
  BOX_JR="+"
else
  ICON_OK="✔"
  ICON_WARN="⚠"
  ICON_ERR="✖"
  ICON_INFO="ℹ"

  BOX_TL="╔"
  BOX_TR="╗"
  BOX_BL="╚"
  BOX_BR="╝"
  BOX_H="═"
  BOX_V="║"
  BOX_JL="╠"
  BOX_JR="╣"
fi

TAG_INFO="${C_BLUE}ℹ${C_RESET}"
TAG_OK="${C_GREEN}✔${C_RESET}"
TAG_WARN="${C_YELLOW}⚠${C_RESET}"
TAG_ERR="${C_RED}✖${C_RESET}"

UI_WIDTH="${UI_WIDTH:-60}"
UI_SUMMARY_KEY_WIDTH="${UI_SUMMARY_KEY_WIDTH:-12}"

# ---------- helpers ----------
ui_repeat() {
  local ch="$1"
  local n="$2"
  printf '%*s' "$n" '' | tr ' ' "$ch"
}

ui_line() {
  ui_repeat "-" "$UI_WIDTH"
  printf '\n'
}

ui_blank() {
  printf '\n'
}

ui_header() {
  local title="$1"
  ui_repeat "=" "$UI_WIDTH"
  printf '\n'
  printf ' %b%s%b\n' "$C_BOLD" "$title" "$C_RESET"
  ui_repeat "=" "$UI_WIDTH"
  printf '\n'
}

ui_subheader() {
  local text="$1"
  printf '%b%s%b\n' "$C_BOLD" "$text" "$C_RESET"
}

ui_step() {
  local text="$1"
  printf '%b%s%b\n' "$C_BOLD" "$text" "$C_RESET"
}

ui_info() {
  printf '%b %s\n' "$TAG_INFO" "$*"
}

ui_ok() {
  printf '%b %s\n' "$TAG_OK" "$*"
}

ui_warn() {
  printf '%b %s\n' "$TAG_WARN" "$*"
}

ui_error() {
  printf '%b %s\n' "$TAG_ERR" "$*"
}

ui_kv() {
  local key="$1"
  local value="$2"
  printf '  %-14s : %s\n' "$key" "$value"
}

# ---------- summary box ----------
_ui_summary_inner_width() {
  echo $((UI_WIDTH - 2))
}

ui_summary_begin() {
  local title="${1:-Summary}"
  local inner width
  inner="$(_ui_summary_inner_width)"
  width=$((inner - 2))

  printf '%s' "$BOX_TL"
  ui_repeat "$BOX_H" "$inner"
  printf '%s\n' "$BOX_TR"

  printf '%s %-*s %s\n' "$BOX_V" "$width" "$title" "$BOX_V"

  printf '%s' "$BOX_JL"
  ui_repeat "$BOX_H" "$inner"
  printf '%s\n' "$BOX_JR"
}

ui_summary_row() {
  local key="$1"
  local value="$2"
  local inner content_width prefix prefix_len rest chunk first_avail next_avail

  inner="$(_ui_summary_inner_width)"
  content_width=$((inner - 2))

  prefix=$(printf ' %-*s : ' "$UI_SUMMARY_KEY_WIDTH" "$key")
  prefix_len=${#prefix}

  if [ "$prefix_len" -ge "$content_width" ]; then
    prefix=" "
    prefix_len=1
  fi

  rest="$value"
  first_avail=$((content_width - prefix_len))
  next_avail=$((content_width - prefix_len))

  # 第一行
  if [ "${#rest}" -le "$first_avail" ]; then
    printf '%s %-*s %s\n' "$BOX_V" "$content_width" "${prefix}${rest}" "$BOX_V"
    return 0
  fi

  chunk="${rest:0:$first_avail}"
  printf '%s %-*s %s\n' "$BOX_V" "$content_width" "${prefix}${chunk}" "$BOX_V"
  rest="${rest:$first_avail}"

  # 后续续行
  while [ -n "$rest" ]; do
    if [ "${#rest}" -le "$next_avail" ]; then
      printf '%s %-*s %s\n' "$BOX_V" "$content_width" "$(printf '%*s%s' "$prefix_len" '' "$rest")" "$BOX_V"
      break
    fi

    chunk="${rest:0:$next_avail}"
    printf '%s %-*s %s\n' "$BOX_V" "$content_width" "$(printf '%*s%s' "$prefix_len" '' "$chunk")" "$BOX_V"
    rest="${rest:$next_avail}"
  done
}

ui_summary_end() {
  local inner
  inner="$(_ui_summary_inner_width)"

  printf '%s' "$BOX_BL"
  ui_repeat "$BOX_H" "$inner"
  printf '%s\n' "$BOX_BR"
}

# ---------- section blocks ----------
ui_next() {
  ui_blank
  ui_subheader "Next:"
  local item
  for item in "$@"; do
    printf '  %s\n' "$item"
  done
}

ui_fix_block() {
  local reason="$1"
  shift || true

  ui_blank
  ui_subheader "Reason:"
  printf '  %s\n' "$reason"

  if [ "$#" -gt 0 ]; then
    ui_blank
    ui_subheader "Fix:"
    local item
    for item in "$@"; do
      printf '  - %s\n' "$item"
    done
  fi
}

ui_debug_block() {
  [ "$#" -eq 0 ] && return 0

  ui_blank
  ui_subheader "Debug:"
  local item
  for item in "$@"; do
    printf '  %s\n' "$item"
  done
}

ui_security_block() {
  [ "$#" -eq 0 ] && return 0

  ui_blank
  ui_subheader "Security:"
  local item
  for item in "$@"; do
    printf '  - %s\n' "$item"
  done
}

# ---------- exit helpers ----------
die() {
  local msg="$1"
  shift || true
  ui_error "$msg"
  exit 1
}

die_with_reason() {
  local msg="$1"
  local reason="$2"
  shift 2 || true
  ui_error "$msg"
  ui_fix_block "$reason" "$@"
  exit 1
}