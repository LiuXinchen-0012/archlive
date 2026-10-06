#!/usr/bin/env bash
# ============================================================================
# common-apps.sh —— 预装常用软件（可裁剪）
#
# 由 post-install.sh 在 chroot 里调用。
#
# ⚠️ 一个踩过的坑：官方仓库里【没有 libreoffice 这个包】。
#    只有 libreoffice-fresh（当前开发版）和 libreoffice-still（保守稳定版），
#    二者互斥、装哪个都行。网上大量教程写的 `pacman -S libreoffice` 在现在的
#    Arch 上会直接报 "target not found"。
#
#    这里默认用 libreoffice-fresh + libreoffice-fresh-zh-cn（中文界面）。
#    想要更保守的版本就改这一行。
#
# 裁剪方法：直接编辑本文件里的 BASE_APPS / EXTRA_APPS 数组。
# 想加软件照着往里加就行，包名写错 preflight 会报出来。
# ============================================================================
set -uo pipefail

log() { printf '[apps] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 必装 —— 都是很小的包，但【我的配置文件直接引用了它们】
#   少装任何一个，niri 里对应的快捷键就是"按了没反应"，而且没有任何报错
# ---------------------------------------------------------------------------
BASE_APPS=(
  # —— 文本编辑 / 终端 ——
  vim                 # 用户点名要的
  alacritty           # 8 MB。config.kdl 里 Mod+Return 绑的就是它
  foot                # 812 KB，最小的 Wayland 终端，备用

  # —— 截图 —— config.kdl 里 Mod+Shift+S 用 grim+slurp+wl-copy ——
  grim
  slurp
  wl-clipboard

  # —— 文件管理 —— KDE 的 dolphin 在首次启动会被删掉，必须补一个 ——
  thunar              # 10 MB，GTK，稳

  # —— 播放器 ——
  mpv                 # 6 MB，国内用户常用

  # —— 音频控制（pipewire 装了但没 GUI 调音量）——
  pavucontrol

  # —— 解压 ——
  file-roller

  # —— 剪贴板历史（cliphist 已在 EXTRA，wl-clipboard 在上面）——
)

# ---------------------------------------------------------------------------
# 办公 ——
# ⚠️ 没有 libreoffice，只有 fresh / still
#   fresh = 当前开发版，界面新，功能全（423 MB）
#   still = 保守稳定版（422 MB），要处理老格式（.doc/.xls）时更稳
#   二者互斥，只能选一个
# ---------------------------------------------------------------------------
OFFICE_APPS=(
  libreoffice-fresh
  libreoffice-fresh-zh-cn
)

# ---------------------------------------------------------------------------
# 可选 —— 桌面 shell 增强。全部都很小，合计不到 50 MB
# 嫌多可以整段删掉
# ---------------------------------------------------------------------------
EXTRA_APPS=(
  # 命令行三件套
  ripgrep             # rg，比 grep 快
  fd                  # 找文件
  fzf                 # 模糊搜索（配 niri 的启动器很好用）
  bat                 # 带高亮的 cat

  # 现代命令行体验
  eza                 # ls 替代品，带图标和 git 状态
  zoxide              #  smarter 的 cd
  starship            # 提示符

  # 输入法增强
  fcitx5-rime

  # 剪贴板历史
  cliphist
)

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
install_list() {
  local title="$1"; shift
  local pkgs=("$@")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0

  log "安装 $title（${#pkgs[@]} 个包）"
  # --needed：已装的不重复装
  if pacman -S --noconfirm --needed "${pkgs[@]}"; then
    log "$title 完成"
  else
    # 逐个重试：某个包名不存在/冲突不该拖垮整批
    log "$title 有失败项，逐个重试以定位问题"
    local p
    for p in "${pkgs[@]}"; do
      pacman -S --noconfirm --needed "$p" >/dev/null 2>&1 \
        || log "  ✗ 装不上: $p"
    done
  fi
}

install_list "必装（配置文件依赖）"  "${BASE_APPS[@]}"
install_list "办公软件"              "${OFFICE_APPS[@]}"
install_list "命令行与桌面增强"      "${EXTRA_APPS[@]}"

# ---------------------------------------------------------------------------
# 验证并汇报
# ---------------------------------------------------------------------------
log "验证安装结果"
MISSING=()
for p in "${BASE_APPS[@]}" "${OFFICE_APPS[@]}"; do
  pacman -Qq "$p" &>/dev/null || MISSING+=("$p")
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
  log "必装 + 办公软件全部就位"
else
  log "以下没装上（不阻断，但对应的快捷键/启动器会失效）：${MISSING[*]}"
fi

# 记一份清单给用户看
cat > /var/lib/shorin-apps.txt <<EOF
预装软件清单（生成于 $(date)）
================================

【必装 —— 配置文件直接引用，缺了对应快捷键会没反应】
  vim          文本编辑器
  alacritty    终端（niri 里 Mod+Return）
  grim+slurp   截图（niri 里 Mod+Shift+S）
  thunar       文件管理器（KDE 的 dolphin 已被删除）
  mpv          播放器
  pavucontrol  音量控制

【办公】
$(for p in "${OFFICE_APPS[@]}"; do
    n=$(pacman -Q "$p" 2>/dev/null | awk '{print $2}')
    [[ -n "$n" ]] && echo "  $n"
  done)

【命令行增强】
$(for p in "${EXTRA_APPS[@]}"; do
    n=$(pacman -Q "$p" 2>/dev/null | awk '{print $2}')
    [[ -n "$n" ]] && echo "  $n"
  done)

想装更多：
  sudo pacman -S <包名>
  官方源走清华/中科大，装什么都不需要代理
EOF
log "清单已写入 /var/lib/shorin-apps.txt"
