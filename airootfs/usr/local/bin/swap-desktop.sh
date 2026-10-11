#!/usr/bin/env bash
# ============================================================================
# swap-desktop.sh —— 在【chroot 里】把目标系统换成用户选定的桌面
#
# 由 post-install.sh 调用。此时系统还没启动过，是最安全的时机 ——
# 比原来"首次开机时删 KDE"安全得多（那次是在运行中的系统里
# pacman -Rns 删当前显示管理器所在的包，失败就砖）。
#
# 关键设计：
#   1. 目标桌面从 /etc/shorin-desktop 读（post-install 写进去的）。
#   2. 选 kde 时什么都不做 —— Plasma 原样留着。
#   3. 其余选项：删 Plasma 核心（保留 dolphin/kate/okular 这些
#      通用 KDE 应用，任何桌面下都好用），装上目标桌面，
#      把 greetd 的 initial_session 指过去。
#   4. 每一步都记日志到 /var/log/shorin-desktop-swap.log。
#
# 用法：swap-desktop.sh            （在目标系统里跑，chroot 已就绪）
#       swap-desktop.sh --dry-run  （只打印要做什么，不动系统）
# ============================================================================
set -uo pipefail

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

DE_FILE=/etc/shorin-desktop
LOG=/var/log/shorin-desktop-swap.log

# 会话名：写进 greetd 的 initial_session
SESSION=""
DM=""          # 要启用的显示管理器（空 = 沿用现有设置）

say() { printf '[换桌面] %s\n' "$*"; }
elog() { printf '[换桌面] %s\n' "$*" >>"$LOG" 2>/dev/null || true; }
run() {
  elog "  \$ $*"
  $DRY && { say "  [dry-run] $*"; return 0; }
  "$@" >>"$LOG" 2>&1
}

# --- 要删的 Plasma 核心 ----------------------------------------------------
# 刻意【不删】dolphin / konsole / kate / okular / gwenview / spectacle 这类
# KDE 应用：它们在 niri/hyprland 下照样能跑（Niri 生态里很常见），
# 删了反而少一堆日常工具。只有 Plasma 的"外壳"才必须走。
# ⚠️ 包名必须是【官方源里真实存在的名字】，不是"听起来该叫"的。
#    我第一版写了三个不存在的，被 preflight 1c 当场抓出来：
#      plasma-discover          → 实际叫 discover
#      plasma-workspace-common  → 不是独立包，是 plasma-workspace 的依赖
#      xdg-desktop-portal-plasma→ 实际叫 xdg-desktop-portal-kde
#    这三个写错的后果不是报错，是 pacman -Qq 查不到 → 静默跳过 → 删不干净。
PLASMA_CORE=(
  plasma-meta plasma-desktop plasma-workspace
  plasma-pa plasma-nm plasma-systemmonitor plasma-nano
  systemsettings kded kscreenlocker kwin
  discover
  breeze breeze-icons breeze-cursors oxygen-icons
  xdg-desktop-portal-kde
)
# 图形界面本身（sddm）单独处理，因为选了 KDE 之外的都要换掉它
PLASMA_DM=(sddm sddm-kcm)

# --- 各目标桌面的包与设置 ---------------------------------------------------
# 在 main() 里按选择结果填这几个变量。
# 这里的包必须全部在【官方源】里。Live 环境不保证能连 AUR/构建源，
# 塞需要 AUR 的包进去 = 给用户埋雷。
SESSION=""        # 写进 greetd 的 initial_session
DM=""             # 要启用的显示管理器（空 = 沿用 greetd）
INSTALL_PKGS=""   # 要装/保留的包
NEEDS_LIVE_REPO=0 # 是否需要 [build] 源里的 AUR 预编译包

# ---------------------------------------------------------------------------
main() {
  local de=""
  [[ -f "$DE_FILE" ]] && de="$(tr -d '[:space:]' <"$DE_FILE")"
  case "$de" in
    dms-niri|shorin-niri|niri|kde|gnome|hyprland|sway) ;;
    *) de="kde" ;;   # 读不到就当"保留 KDE"，最保守
  esac

  # 覆盖上面对应的设置
  case "$de" in
    dms-niri) SESSION="dms-session"; DM=""
      INSTALL_PKGS="dms-shell niri quickshell matugen cava wl-clipboard cliphist xdg-desktop-portal-gnome xwayland-satellite libnotify power-profiles-daemon qt5-multimedia cups-pk-helper kimageformats dgop dsearch-bin shorin-dms-niri-git"
      NEEDS_LIVE_REPO=1 ;;
    niri)      SESSION="niri-session"; DM=""
      INSTALL_PKGS="niri xwayland-satellite xdg-desktop-portal-gnome xdg-desktop-portal libnotify wl-clipboard grim slurp mako swaybg swaylock foot fuzzel qt5-multimedia"
      NEEDS_LIVE_REPO=0 ;;
    shorin-niri) SESSION="niri-session"; DM=""
      # 跟 dms-niri 装一样的包 —— shorin-dms-niri-git 里有作者的 dotfiles，
      # 而它是硬依赖 dms-shell 的，pacman 会顺带把 dms-shell 装上。
      # 区别只在【不启用 DMS 外壳】：会话是纯 niri-session，
      # 而且 skel-config.sh 会把 dotfiles 里的 dms/ 目录剔掉。
      INSTALL_PKGS="dms-shell niri quickshell matugen cava wl-clipboard cliphist xdg-desktop-portal-gnome xwayland-satellite libnotify power-profiles-daemon qt5-multimedia cups-pk-helper kimageformats dgop dsearch-bin shorin-dms-niri-git"
      NEEDS_LIVE_REPO=1 ;;
    kde)       SESSION="plasma"; DM=""
      INSTALL_PKGS=""; NEEDS_LIVE_REPO=0 ;;
    gnome)     SESSION="gnome"; DM="gdm"
      INSTALL_PKGS="gnome-shell gnome-control-center gnome-tweaks gnome-keyring gnome-terminal gdm metacity mutter xdg-desktop-portal-gnome xdg-desktop-portal xdg-desktop-portal-gtk"
      NEEDS_LIVE_REPO=0 ;;
    hyprland)  SESSION="Hyprland"; DM=""
      INSTALL_PKGS="hyprland hyprland-qtutils hyprlock hypridle hyprpaper waybar wofi mako grim slurp wl-clipboard foot xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-hyprland"
      NEEDS_LIVE_REPO=0 ;;
    sway)      SESSION="sway"; DM=""
      INSTALL_PKGS="sway swaylock swaybg swayidle waybar wofi dmenu mako grim slurp foot xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-wlr"
      NEEDS_LIVE_REPO=0 ;;
  esac

  say "目标桌面 = $de（会话 $SESSION${DM:+, 显示管理器 $DM}）"
  elog "=== 换桌面开始: $de / $SESSION ==="

  # --- kde：什么都不动 ----------------------------------------------------
  if [[ "$de" == "kde" ]]; then
    say "选的是 KDE —— 原样保留 Plasma，不做任何删改"
    elog "选 kde，跳过全部操作"
    $DRY || touch /var/lib/shorin-desktop-ok
    exit 0
  fi

  # --- 1. 装目标桌面（先装后删，避免中间态没有桌面）-----------------------
  if [[ -n "$INSTALL_PKGS" ]]; then
    say "安装目标桌面的包…"
    if run pacman -S --noconfirm --needed $INSTALL_PKGS; then
      elog "目标桌面包安装完成"
    else
      elog "!! 部分包安装失败（继续往下走，至少保证 KDE 还在）"
    fi
  fi

  # --- 2. 换显示管理器 ----------------------------------------------------
  if [[ -n "$DM" ]]; then
    say "切换显示管理器 → $DM"
    run systemctl enable "$DM.service"
    run systemctl disable sddm.service
  else
    # 非 KDE 选项都要把 sddm 停掉，改用 greetd（已装）
    if command -v systemctl >/dev/null 2>&1; then
      run systemctl disable sddm.service
      run systemctl enable greetd.service
    fi
  fi

  # --- 3. 删 Plasma 外壳 --------------------------------------------------
  say "删除 Plasma 外壳（保留 dolphin/kate 等通用应用）…"
  local p
  for p in "${PLASMA_CORE[@]}" "${PLASMA_DM[@]}"; do
    if pacman -Qq "$p" >/dev/null 2>&1; then
      run pacman -Rns --noconfirm "$p"
    fi
  done

  # --- 4. 首次开机别再跑 shorin-remove-kde -------------------------------
  # 桌面已经在 chroot 里换好了，那个 service 现在是多余的。
  # 不禁掉它的话，它会在首次开机时对着一个没有 Plasma 的系统
  # 再跑一遍删除逻辑，虽然有幂等守卫，但纯属多余动作。
  if $DRY; then
    say "  [dry-run] systemctl disable shorin-remove-kde.service"
  else
    systemctl disable shorin-remove-kde.service 2>/dev/null || true
    elog "已禁用 shorin-remove-kde.service（桌面已在 chroot 里换好）"
  fi

  $DRY || touch /var/lib/shorin-desktop-ok
  elog "=== 换桌面结束: $de ==="
  say "完成。首次开机直接进 $SESSION。"
}

main "$@"