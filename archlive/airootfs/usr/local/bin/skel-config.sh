#!/usr/bin/env bash
# ============================================================================
# skel-config.sh —— 生成 /etc/skel 下的桌面配置
#
# 为什么写 /etc/skel 而不是 /home/<user>：
#   安装器是在系统装配【之后】才创建用户的，创建时会把 /etc/skel 拷成新用户家目录。
#   在 chroot 里以 root 身份写 /home/xxx 是错的 —— 那时用户还不存在。
#
# 内容：
#   .config/niri/config.kdl   niri 主配置 + autostart（重启提示通知）
#   .config/quickshell/dms    DMS shell 配置指向
#   .config/environment.d/    fcitx5 环境变量
#   .config/autostart/        fcitx5 自启
#   .config/user-dirs.dirs    XDG 目录（中文）
# ============================================================================
set -uo pipefail

SKEL=/etc/skel
log() { printf '[skel] %s\n' "$*"; }

mkdir -p "$SKEL"/.config/{niri,quickshell,environment.d,autostart,gtk-3.0}
mkdir -p "$SKEL"/Desktop
mkdir -p "$SKEL"/.local/share/{applications,fonts,icons}

# --- 1. niri ---------------------------------------------------------------
# 注意：如果你后面用 `shorindms init` 或 dms 自己的 installer 生成配置，
# 它会覆盖这个文件。这里先放一份可用且自洽的最小配置，保证装完就能进 niri。
log "写 niri 配置"
cat > "$SKEL/.config/niri/config.kdl" <<'KDL'
// ARCH_SHORIN — 最小可用 niri 配置
// 若你之后跑了 shorindms init / dms installer，这个文件会被覆盖，以它们的为准。

// ---------- 输入 ----------
input {
    keyboard {
        xkb {
            layout "us"
            // 改成 "cn" 可直接用美式键位打中文
        }
    }
    touchpad {
        tap
        natural-scroll
    }
    mouse {
        accel-profile "flat"
    }
}

// ---------- 显示 ----------
output "eDP-1" {
    mode "1920x1080@60.000"
    scale 1.0
}

// ---------- 环境 ----------
environment "NIRI_SOCKET" {
    value "$WAYLAND_DISPLAY"
}

// ---------- 快捷键 ----------
binds {
    Mod+Shift+Q { close-window; quit; }
    Mod+Q       { close-window; }
    Mod+Return  { spawn "alacritty"; }
    Mod+D       { spawn "dms ipc launcher"; }   // DMS 启动器（由 dms-shell 提供）
    Mod+E       { spawn "dms ipc launcher --power"; }

    // 窗口布局
    Mod+Shift+Left  { focus-column-left; }
    Mod+Shift+Right { focus-column-right; }
    Mod+Shift+Up    { focus-window-up; }
    Mod+Shift+Down  { focus-window-down; }

    // 截图
    Mod+Shift+S { spawn "grim -g \"$(slurp)\" - | wl-copy"; }
}

// ---------- 工作区 ----------
workspaces {
    Mod+1 { workspace 1; }
    Mod+2 { workspace 2; }
    Mod+3 { workspace 3; }
    Mod+4 { workspace 4; }
}

// ---------- 自启 ----------
// 重启提示：删完 KDE 后 /var/lib/shorin-need-reboot 会存在。
// 实际逻辑在 /usr/local/bin/shorin-reboot-notice（会话无关），
// 这样第一次开机的 KDE 会话也能弹 —— 详见该脚本顶部注释。
spawn-at-startup "sh" "-c" "(sleep 8; /usr/local/bin/shorin-reboot-notice) &"

// fcitx5 必须在 GUI 之前起来
spawn-at-startup "sh" "-c" "if [ -x /usr/bin/fcitx5 ]; then (sleep 2; fcitx5 -d) & fi"
KDL
log "  .config/niri/config.kdl"

# --- 2. fcitx5 环境变量 ----------------------------------------------------
log "写 fcitx5 环境变量"
cat > "$SKEL/.config/environment.d/99-fcitx5.conf" <<'EOF'
XMODIFIERS=@im=fcitx
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
SDL_IM_MODULE=fcitx
EOF

# XDG autostart：KDE / XFCE / GNOME 等都认这个标准。
# 目的是让【第一次开机、用户还坐在 KDE 里的时候】就能看到重启提示 ——
# 只靠 niri 的 autostart 的话，得重启完才看得到，那就晚了。
cat > "$SKEL/.config/autostart/shorin-reboot-notice.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Shorin reboot notice
Comment=删掉 KDE 后提示用户手动重启（首次开机时也要能看到）
Exec=/usr/local/bin/shorin-reboot-notice
Icon=dialog-information
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

cat > "$SKEL/.config/autostart/fcitx5.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Comment=中文输入法
Exec=fcitx5
Icon=fcitx
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

# fcitx5 配置（拼音默认）
mkdir -p "$SKEL/.config/fcitx5"
cat > "$SKEL/.config/fcitx5/profile" <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=Default
EOF

# --- 3. XDG 用户目录 -------------------------------------------------------
log "写 XDG 目录配置"
cat > "$SKEL/.config/user-dirs.dirs" <<'EOF'
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOWNLOAD_DIR="$HOME/Download"
XDG_TEMPLATES_DIR="$HOME/Templates"
XDG_PUBLICSHARE_DIR="$HOME/Public"
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_MUSIC_DIR="$HOME/Music"
XDG_PICTURES_DIR="$HOME/Pictures"
XDG_VIDEOS_DIR="$HOME/Videos"
EOF
cat > "$SKEL/.config/user-dirs.conf" <<'EOF'
enabled=true
EOF
# 中文目录名（可选，不想要就删掉这两行）
mkdir -p "$SKEL"/{下载,文档,图片,视频,音乐}
cat > "$SKEL/.config/user-dirs.dirs" <<EOF
XDG_DESKTOP_DIR="\$HOME/Desktop"
XDG_DOWNLOAD_DIR="\$HOME/下载"
XDG_TEMPLATES_DIR="\$HOME/模板"
XDG_PUBLICSHARE_DIR="\$HOME/公共"
XDG_DOCUMENTS_DIR="\$HOME/文档"
XDG_MUSIC_DIR="\$HOME/音乐"
XDG_PICTURES_DIR="\$HOME/图片"
XDG_VIDEOS_DIR="\$HOME/视频"
EOF

# --- 4. DMS 相关 ----------------------------------------------------------
mkdir -p "$SKEL/.config/quickshell/dms"
cat > "$SKEL/.config/quickshell/shell.qml" <<'EOF'
// 指向 DMS shell。发行版包安装后这里会由包自带文件接管。
import Quickshell
import Quickshell.Io

ShellRoot {
    // DMS 由 dms-shell 包提供，主程序在 /usr/lib/quickshell 或 ~/.config/quickshell/dms
    // 若启动 niri 后没看到 dms 顶栏，检查此目录与 dms-shell 包内容是否匹配。
}
EOF

# --- 5. 一个自启动的说明文件 ---------------------------------------------
cat > "$SKEL/Desktop/关于这个系统.txt" <<'EOF'
ARCH_SHORIN 定制系统
===================

桌面环境 : Shorin DMS Niri（Wayland 合成器 niri + DMS 桌面 Shell）
显示管理 : greetd（开机自动登录进入 niri）
快照     : btrfs + snapper（若安装时 / 是独立子卷）
代理     : TPClash 透明代理（若安装时填写了订阅链接）

预装软件
--------
  终端      alacritty（Mod+Return）
  编辑器    vim
  办公      LibreOffice（中文界面）
  文件管理  thunar
  播放器    mpv
  截图      Mod+Shift+S
  音量      pavucontrol
  命令行    rg / fd / fzf / bat / eza / zoxide / starship
  完整清单： cat /var/lib/shorin-apps.txt

常用命令
--------
  dms ipc launcher        打开 DMS 启动器
  dms ipc notification    通知中心
  pacman -Syu             更新系统
  snapper list            查看快照
  sudo pacman -Rns $(pacman -Qdtq)    清理孤立依赖（系统稳定后再做）

遇到问题
--------
  装完 KDE 被删、但 niri 起不来时，用 TTY 登录后：
    systemctl status display-manager
    journalctl -b -u display-manager

  日志：
    /var/log/shorin-install.log      安装日志
    /var/log/shorin-remove-kde.log   删 KDE 日志
    /var/log/shorin-drivers.log      驱动检测日志
EOF

# --- 6. Shorin DMS Niri dotfiles（如果预编译包装上了）------------------------
# shorin-dms-niri-git 的 package() 把 dotfiles 放在 /usr/share/shorin-dms-niri
# 我们不跑 `shorindms init`：它会 get_aur_helper()（没装 yay/paru 直接 exit 1），
# 然后用 AUR helper 去拉 50 多个 optdepends —— 在 chroot 里既没网络也没有用户会话。
# 所以这里直接把 dotfiles 拷进 /etc/skel，让新建用户直接继承。
#
# 两处剔除：
#   .local/bin/bad-apple      17.6 MB 二进制，放 skel 里每个用户家目录都白占 17MB
#   .config/fcitx5/conf/     fcitx5 的运行时缓存，机器相关的垃圾
if [ -d /usr/share/shorin-dms-niri ]; then
  log "集成 Shorin DMS Niri dotfiles 到 /etc/skel"
  SRC=/usr/share/shorin-dms-niri
  # .config 整体拷（但排除 fcitx5/conf）
  if [ -d "$SRC/.config" ]; then
    ( cd "$SRC" && find .config -path './.config/fcitx5/conf' -prune -o -print0 ) \
      | ( cd "$SRC" && tar --null -cf - -T - 2>/dev/null ) \
      | ( cd "$SKEL" && tar -xf - 2>/dev/null ) && log "  .config 已合并"
  fi
  # .local 只拷脚本/配置，跳过大于 1MB 的二进制
  if [ -d "$SRC/.local" ]; then
    ( cd "$SRC" && find .local -type f -size -1M -print0 ) \
      | ( cd "$SRC" && tar --null -cf - -T - 2>/dev/null ) \
      | ( cd "$SKEL" && tar -xf - 2>/dev/null ) && log "  .local（<1MB 的部分）已合并"
  fi
  # 记一笔，方便用户知道还差什么
  cat > "$SKEL/Desktop/Shorin-DMS-说明.txt" <<'TXT'
Shorin DMS Niri 已安装
=====================

本次安装已完成的部分：
  ✓ dms-shell / niri / matugen / cava 等运行时依赖
  ✓ Shorin 的 dotfiles（已随系统预设，无需再跑初始化）

你可能想补装的软件（都需要联网）：
  终端        kitty / fish / starship / eza / zoxide / bat
  文件管理器   nemo 或 thunar
  截图        satty / slurp / wf-recorder
  浏览器      firefox
  应用商店     bazaar（Flatpak 前端）
  输入法词库   rime-wanxiang-gram-zh-hans

想一键拉齐，可以在联网状态下运行：
  shorindms init

注意 shorindms 会要求先装好 yay 或 paru（AUR 助手），
并且会安装 50 多个可选包，耗时较长。
TXT
  log "  已生成说明文件"
else
  log "未检测到 /usr/share/shorin-dms-niri —— 保持最小 niri 配置（SHORIN_MODE=skeleton）"
fi

# 桌面留一份订阅模板：用户填好改名，启动器就会自动读
cat > "$SKEL/Desktop/代理订阅.txt.example" <<'EX'
把这个文件复制一份，改名为「代理订阅.txt」，填入你的订阅链接，保存。
放在桌面上即可 —— 启动安装器时会自动读取，不用手打长 URL。

格式示例（只是样子，请换成你自己的）：
  http://你的面板域名/sub?token=xxxxxxxx
  https://你的面板域名/clash/v1?token=xxxxxxxx

怎么确认填对了：把链接贴到浏览器地址栏，应该下载到一个 yaml 文件，
而不是打开一个网页 —— 打开网页说明你填的是面板地址，不是订阅地址。
EX

# 代理重配入口：目标系统里也放一个，装完想改代理随时能开
# （setup-proxy-gui.sh 随 airootfs 一起被 unpackfs 复制到了目标系统）
cat > "$SKEL/Desktop/配置代理.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Version=1.0
Name=配置代理
GenericName=透明代理设置
Comment=重新配置 Clash 透明代理
Exec=/usr/local/bin/setup-proxy-gui.sh
Icon=network-server
Terminal=false
Categories=Network;
EOF2

chown -R root:root "$SKEL" 2>/dev/null || true
chmod -R go-w "$SKEL" 2>/dev/null || true
log "完成。新建用户后自动生效。"
