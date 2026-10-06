#!/usr/bin/env bash
# ============================================================================
# shorin-remove-kde.sh —— 目标系统首次启动时删除 KDE Plasma
#
# 由 /etc/systemd/system/shorin-remove-kde.service 在 multi-user.target
# 阶段调用。触发条件：/etc/shorin-remove-kde 存在。
#
# 关于时序（与原方案的差异，理由见同目录 README-修正说明.md）：
#   原方案在 service 里写了 Before=display-manager.service + DefaultDependencies=no，
#   意图是在 sddm 启动前就把 KDE 删掉。这里【不这么做】，原因：
#     1) 在运行中的系统里 pacman -Rns 删掉当前显示管理器所在包，风险高；
#     2) 一旦脚本中途失败，用户面对的是"没有图形界面"的砖机状态；
#     3) 用户的可观测行为完全一样 —— 本次启动看到 KDE + 提示，
#        手动重启后进入 niri。既然如此，就选不会砖的那条路。
#
# 保底：若检测到目标系统不完整（/var/lib/shorin-incomplete 存在，
# 或 niri-session 不存在），本脚本【中止并保留标记】，下个开机重试。
# ============================================================================
set -uo pipefail

LOG=/var/log/shorin-remove-kde.log
MARKER=/etc/shorin-remove-kde
NEED_REBOOT=/var/lib/shorin-need-reboot
INCOMPLETE=/var/lib/shorin-incomplete

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }

# systemd journal 看不到输出时，至少留个文件
exec >> "$LOG" 2>&1
echo "===== shorin-remove-kde $(date) ====="

# --- 0. 幂等 & 触发条件 ----------------------------------------------------
[[ -f "$MARKER" ]] || { log "标记不存在，已处理过，退出"; exit 0; }
[[ -f "$NEED_REBOOT" ]] && { log "已标记过需重启，退出"; exit 0; }

# --- 1. 保底检查：目标桌面真的就位了吗 ------------------------------------
if [[ -f "$INCOMPLETE" ]]; then
  log "中止：检测到 $INCOMPLETE —— 上次安装有失败项，删 KDE 会导致无法进图形界面"
  log "      请先查看 /var/log/shorin-install.log 修复；修复后删除 $INCOMPLETE 即可重试"
  exit 0
fi

if ! command -v niri-session > /dev/null 2>&1; then
  log "中止：niri-session 不存在，删除 KDE 后将无法进入图形界面。保留 KDE。"
  exit 0
fi

# --- 2. 切换显示管理器 -----------------------------------------------------
# 注意：此时 sddm 正在运行（用户当前就在 KDE 会话里）。我们不 stop 它 ——
# stop 了当前用户的桌面会话会当场黑屏。只改"下次启动用哪个"。
log "切换显示管理器 sddm -> greetd"
systemctl disable sddm.service 2>/dev/null || log "disable sddm 返回非 0（若本就未启用可忽略）"
systemctl enable  greetd.service

# 重建 display-manager.service 别名软链
if [[ -e /usr/lib/systemd/system/greetd.service ]]; then
  ln -sf /usr/lib/systemd/system/greetd.service /etc/systemd/system/display-manager.service
  log "display-manager.service -> greetd"
else
  log "WARN: /usr/lib/systemd/system/greetd.service 不存在，greetd 没装？"
fi
systemctl daemon-reload

# --- 3. 删除 KDE -----------------------------------------------------------
# 逐个删而不是一把 -Rns plasma-meta：
#   - 可以避免连带删掉 niri/dms 需要的共享依赖（Qt6/XDG/Polkit 等）；
#   - 任一包不存在时 pacman -Rns 会整条报错，脚本会跳过继续。
# 因此这里对每个包先 --print 预览，确认存在再删。
  # ⚠️ 这里写的是【当前仓库里真实存在】的包名。
  #    Plasma 6 期间改过一批名字，旧写法现在已经查不到了：
  #      ksystemsettings        -> systemsettings
  #      kded6                  -> kded
  #      plasma-discover        -> discover
  #      locker                 -> kscreenlocker
  #      plasma-wayland         -> plasma-workspace
  #      plasma-workspace-common-> plasma-workspace
  #      breeze-icon-theme      -> breeze-icons
  #      kde-style-breeze       -> breeze
  #      sddm-greeter           -> 根本不是包（greeter 主题在 sddm 里）
  #    下面循环有 pacman -Qq 守卫，写错名字只会跳过、不会崩；
  #    但写对了才真的删得掉 —— 之前那版 KDE 删不干净就是这个原因。
  KDE_PKGS=(
    plasma-meta plasma-desktop plasma-workspace plasma-pa plasma-nm
    plasma-systemmonitor plasma-nano
    sddm sddm-kcm
    dolphin konsole kate
    systemsettings kded kded5
    kio-extras
    kscreenlocker
    discover
    breeze breeze-icons breeze-cursors oxygen-icons
    xdg-desktop-portal-kde
  )

log "删除 KDE 包（逐个删，避免误伤共享依赖）"
removed=()
for p in "${KDE_PKGS[@]}"; do
  if pacman -Qq "$p" &>/dev/null; then
    if pacman -Rns --noconfirm "$p" >>"$LOG" 2>&1; then
      removed+=("$p")
      log "  已删除 $p"
    else
      log "  删除 $p 失败，继续"
    fi
  fi
done
log "共删除 ${#removed[@]} 个包"

# --- 4. 孤立依赖清理 -------------------------------------------------------
# 默认【关闭】。原方案也说"首次测试建议禁用" —— 理由是 pacman -Rns $(pacman -Qdtq)
# 在刚装完的系统上很容易连带清掉 dms/niri 需要的、但被标为 optional 的包。
# 等你确认系统稳了，手动跑一次：
#   sudo pacman -Rns $(pacman -Qdtq)
DO_ORPHAN_CLEAN="${DO_ORPHAN_CLEAN:-0}"
if [[ "$DO_ORPHAN_CLEAN" == "1" ]]; then
  orphans="$(pacman -Qdtq 2>/dev/null)"
  if [[ -n "$orphans" ]]; then
    log "清理孤立依赖：$(echo "$orphans" | tr '\n' ' ')"
    pacman -Rns --noconfirm $orphans >>"$LOG" 2>&1 || log "孤立依赖清理返回非 0"
  fi
else
  log "跳过孤立依赖清理（DO_ORPHAN_CLEAN=0）。系统稳定后手动执行："
  log "  sudo pacman -Rns \$(pacman -Qdtq)"
fi

# --- 5. 重建引导配置 -------------------------------------------------------
log "重建 grub 配置"
grub-mkconfig -o /boot/grub/grub.cfg >>"$LOG" 2>&1 || log "WARN: grub-mkconfig 失败，请手动重建"

# --- 6. 写提示 -------------------------------------------------------------
# motd 是给重启后在 TTY 登录的人看的。
cat > /etc/motd <<'EOF'

  ============================================================
   Shorin 定制系统初始化完成
  ============================================================

   KDE Plasma 已卸载，当前桌面为 Shorin DMS Niri。

   * 提示：建议现在手动重启一次，以加载新内核与新显示管理器。
     命令：  reboot
     本脚本不会自动重启（避免打断你正在进行的操作）。

   * 若重启后未进入 niri，可临时切回：
       在 TTY 里执行  systemctl status display-manager

   * 详细日志：/var/log/shorin-remove-kde.log
   * 安装日志：/var/log/shorin-install.log
  ============================================================

EOF

touch "$NEED_REBOOT"
log "已写入 /etc/motd 与 $NEED_REBOOT"

# --- 7. 清除标记，让下次开机不再执行 ---------------------------------------
rm -f "$MARKER"
systemctl disable shorin-remove-kde.service 2>/dev/null
log "标记已清除，任务完成。不会自动重启。"
exit 0
