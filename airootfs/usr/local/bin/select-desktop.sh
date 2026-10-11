#!/usr/bin/env bash
# ============================================================================
# select-desktop.sh —— 在【Live 环境】里选"装完要用哪个桌面"
#
# 为什么要有这个：
#   原方案是固定的"装 KDE → 首次启动删 KDE → 第二次启动进 Niri"。
#   问题是 KDE 白装一遍、又白删一遍，而且用户要点两次重启才看到结果。
#   现在改成：装之前先选，post-install.sh 在 chroot 里（系统还没跑起来，
#   最安全的时机）把目标桌面换好，【首次开机直接进选中的桌面】。
#
# 它跑在 Live 环境里（不在 chroot 里），把结果写到：
#     /tmp/shorin-desktop-choice      ← 只有一个 key，如 dms-niri
# post-install.sh 会读它，并写进目标系统的 /etc/shorin-desktop。
#
# 不选也能装：默认 dms-niri（原方案的行为）。
#
# 选项只用【官方源里真的有包】的桌面 —— Live 环境不保证能连 AUR/构建源，
# 塞需要 AUR 的选项进去等于给用户埋雷。
# ============================================================================
set -uo pipefail

CHOICE_FILE=/tmp/shorin-desktop-choice
DEFAULT_KEY="dms-niri"

# 每行格式：key|显示名|说明
OPTIONS=(
  "dms-niri|Shorin DMS Niri|作者 SHORiN 的完整 DMS 桌面 + niri（推荐，功能最全）"
  "niri|Niri（纯净）|上游官方 niri，不装 DMS 那套，最轻量"
  "shorin-niri|Shorin Niri（无 DMS）|作者的 niri 配置/键位/动画，但不装 DMS 外壳，进纯 niri"
  "kde|KDE Plasma|保留现在的 Plasma，不删除任何东西"
  "gnome|GNOME|gnome-shell + GDM，最通用的传统桌面"
  "hyprland|Hyprland|纯 Wayland 动画桌面，配置门槛较高"
  "sway|Sway|i3 风格纯 Wayland 窗口管理器，适合喜欢平铺的人"
)

log() { printf '[选择桌面] %s\n' "$*"; }

field() {   # $1=key  $2=字段号(1=名字 2=说明)
  local o
  for o in "${OPTIONS[@]}"; do
    [[ "${o%%|*}" == "$1" ]] || continue
    if [[ "$2" == 1 ]]; then echo "$o" | cut -d'|' -f2; else echo "$o" | cut -d'|' -f3; fi
    return
  done
}

current() { [[ -f "$CHOICE_FILE" ]] && tr -d '[:space:]' < "$CHOICE_FILE" || echo ""; }

valid() {
  local o
  for o in "${OPTIONS[@]}"; do [[ "${o%%|*}" == "$1" ]] && return 0; done
  return 1
}

usage() {
  echo "可选的桌面环境："
  local i=1 o
  for o in "${OPTIONS[@]}"; do
    printf '  %d) %-18s %s\n' "$i" "$(echo "$o" | cut -d'|' -f2)" "$(echo "$o" | cut -d'|' -f3)"
    i=$((i+1))
  done
  echo
  echo "用法: select-desktop.sh [序号或 key]"
}

usage_and_exit() { usage; exit "${1:-1}"; }

pick_by_cli() {
  local want="$1" i=1 o
  for o in "${OPTIONS[@]}"; do
    if [[ "$want" == "$i" || "$want" == "${o%%|*}" ]]; then echo "${o%%|*}"; return 0; fi
    i=$((i+1))
  done
  return 1
}

# 图形界面下弹单选框；没有图形就退回命令行
choose_gui() {
  command -v kdialog >/dev/null 2>&1 || return 1
  [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || return 1

  local items=() o cur idx=0 i=1
  for o in "${OPTIONS[@]}"; do
    items+=("$(echo "$o" | cut -d'|' -f2)  ——  $(echo "$o" | cut -d'|' -f3)" "${o%%|*}")
    i=$((i+1))
  done

  cur="$(current)"
  if [[ -n "$cur" ]]; then
    i=1
    for o in "${OPTIONS[@]}"; do
      [[ "${o%%|*}" == "$cur" ]] && idx=$((i-1))
      i=$((i+1))
    done
  fi

  kdialog --title "选择要安装的桌面环境" \
          --text "装完之后你要用哪个桌面？\n\n现在不选也能继续安装，默认是 <b>Shorin DMS Niri</b>（原方案）。\n选 KDE 就是保留现在的 Plasma，不会删任何东西。" \
          --radiolist "桌面环境" "${items[@]}" "$idx" 2>/dev/null
}

choose() {
  local key
  if key="$(choose_gui)" && [[ -n "$key" ]] && valid "$key"; then
    echo "$key"; return 0
  fi
  echo "--- 没有图形界面（或取消了），用命令行选 ---" >&2
  usage
  read -r -p "输入序号（直接回车 = 1 = $(field "$DEFAULT_KEY" 1)）：" ans
  ans="${ans:-1}"
  pick_by_cli "$ans"
}

main() {
  mkdir -p /tmp
  local key=""
  local cur; cur="$(current)"

  if [[ -n "${1:-}" ]]; then
    key="$(pick_by_cli "$1")" || usage_and_exit 1
  else
    key="$(choose)" || usage_and_exit 1
    [[ -z "$key" ]] && key="$DEFAULT_KEY"     # 点了取消 → 用默认
  fi

  valid "$key" || usage_and_exit 1
  printf '%s' "$key" > "$CHOICE_FILE"

  local name; name="$(field "$key" 1)"
  log "已选择：$name（$key）"
  echo
  echo "  ✅ 桌面环境：$name"
  echo "     现在点桌面上的【安装 Arch Linux】继续。"
  [[ -n "$cur" && "$cur" != "$key" ]] && echo "     （之前选的是 $(field "$cur" 1)，已改成 $name）"
  echo

  command -v kdialog >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && \
    kdialog --title "已选择" --text "桌面环境已选定：\n\n<b>$name</b>\n\n接下来点桌面上的【安装 Arch Linux】开始安装。" \
            --button "好" >/dev/null 2>&1
  exit 0
}

main "$@"