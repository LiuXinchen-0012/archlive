#!/usr/bin/env bash
# ============================================================================
# post-install.sh —— 在 chroot 内（/mnt/target）执行的目标系统装配
#
# 调用方：安装器的 exec 阶段（chroot shellprocess）
# 本脚本假定 $TARGET_MOUNT 指向目标系统根，否则退化为 /mnt/target
#
# 设计原则：
#   1. 全程 set -u 但不 set -e —— 任何一步失败都记录并继续，绝不把安装器卡死。
#   2. 每个阶段写 /var/log/shorin-install.log，装完可查。
#   3. 关键步骤（niri/dms 安装、greetd 配置）失败会留下 /var/lib/shorin-incomplete，
#      首次启动时 shorin-remove-kde.service 会看到它并拒绝删 KDE —— 保底不砖机。
# ============================================================================
set -uo pipefail

TARGET_MOUNT="${TARGET_MOUNT:-/mnt/target}"
LOG="/tmp/shorin-install.log"
INCOMPLETE="/var/lib/shorin-incomplete"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
warn() { log "WARN  $*"; }
die()  { log "ERROR $*"; touch "$INCOMPLETE"; }

[[ -d "$TARGET_MOUNT" ]] || { echo "目标挂载点 $TARGET_MOUNT 不存在" >&2; exit 1; }

# 进入 chroot 执行一条命令；打印命令，失败不中断
ch() {
  printf '\n$ %s\n' "$*" >> "$LOG"
  _chroot_cmd "$TARGET_MOUNT" /bin/bash -c "$*" >> "$LOG" 2>&1
  local rc=$?
  [[ $rc -ne 0 ]] && printf '[rc=%s]\n' "$rc" >> "$LOG"
  return $rc
}

# chroot 内交互执行（会真的等 stdin；用于可能需要确认的步骤）
ch_interactive() {
  printf '\n$ (interactive) %s\n' "$*" >> "$LOG"
  _chroot_cmd "$TARGET_MOUNT" /bin/bash -c "$*"
}

# ---------------------------------------------------------------------------
# chroot 辅助
#
# 这个脚本可能以两种身份运行，必须都支持：
#   A. live 环境里（由 shellprocess-postinstall.conf 以 dontChroot:true 调用）
#      -> 需要自己做 chroot
#   B. 已经在目标 chroot 里（有人手动 chroot 后直接跑本脚本）
#      -> 再 chroot 一次就是嵌套，会炸
#
# 判据：archiso live 环境里有 /run/archiso；目标系统里没有。
# ---------------------------------------------------------------------------
IS_LIVE=0
[[ -d /run/archiso ]] && IS_LIVE=1

MOUNTED_BY_US=0

_bind_mounts() {
  local root="$1"
  log "chroot 绑定挂载 /proc /sys /dev /run /tmp"
  mount --bind /proc   "$root/proc"   2>/dev/null
  mount --bind /sys    "$root/sys"    2>/dev/null
  mount --bind /dev    "$root/dev"    2>/dev/null
  mount --bind /run    "$root/run"    2>/dev/null
  # /dev/pts 和 /dev/shm 单独 bind，chroot 里的 tty 和 dbus 才正常
  mount -t devpts devpts "$root/dev/pts" -o mode=0620,gid=5 2>/dev/null
  mount -t tmpfs  tmpfs  "$root/dev/shm" 2>/dev/null
  MOUNTED_BY_US=1
}

_unbind_mounts() {
  local root="$1"
  [[ $MOUNTED_BY_US -eq 1 ]] || return 0
  log "解除 chroot 绑定挂载"
  umount -l "$root/dev/shm" 2>/dev/null
  umount -l "$root/dev/pts" 2>/dev/null
  umount -l "$root/run"    2>/dev/null
  umount -l "$root/dev"    2>/dev/null
  umount -l "$root/sys"    2>/dev/null
  umount -l "$root/proc"   2>/dev/null
  MOUNTED_BY_US=0
}

# 在目标系统里执行命令（自动判断要不要 chroot）
_chroot_cmd() {
  local root="$1"; shift
  if [[ $IS_LIVE -eq 1 ]]; then
    # arch-chroot 会设置好 locale/PATH 等环境，比裸 chroot 省事
    if command -v arch-chroot > /dev/null 2>&1; then
      arch-chroot "$root" "$@"
    else
      chroot "$root" "$@"
    fi
  else
    # 已经在 chroot 里了，直接跑
    "$@"
  fi
}

: > "$LOG"
log "===== post-install 开始 ====="
log "目标挂载点: $TARGET_MOUNT"
log "运行环境: $([[ $IS_LIVE -eq 1 ]] && echo 'live 环境（将自行 chroot）' || echo '已在目标 chroot 内')"

if [[ $IS_LIVE -eq 1 ]]; then
  _bind_mounts "$TARGET_MOUNT"
  # 无论后面怎么退出，都把挂载解掉，别把 live 环境搞脏
  trap '_unbind_mounts "$TARGET_MOUNT"' EXIT
fi


# ---------------------------------------------------------------------------
# 0. 准备：网络与 DNS
# ---------------------------------------------------------------------------
# chroot 默认不继承 Live 环境的 /etc/resolv.conf。这里复制 Live 的，
# 但如果 Live 正在跑透明代理（TPClash），DNS 可能被劫持到 127.0.0.1:1053 之类
# 的本地 fake-ip 监听 —— 那在 chroot 里不存在，会导致 chroot 内 DNS 全挂。
# 所以策略：优先用国内公共 DNS，不盲目复制。
log "配置 chroot DNS"
cat > "$TARGET_MOUNT/etc/resolv.conf" <<'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 180.76.76.76
EOF
chattr +i "$TARGET_MOUNT/etc/resolv.conf" 2>/dev/null && \
  chattr -i "$TARGET_MOUNT/etc/resolv.conf" 2>/dev/null || true
log "已写入国内公共 DNS（不加 chattr +i，否则 NetworkManager 之后会写不进去）"

# ---------------------------------------------------------------------------
# 1. 关闭 initramfs 触发（装 DKMS/驱动时避免反复重建内核）
# ---------------------------------------------------------------------------
log "临时关闭 mkinitcpio 钩子"
mv "$TARGET_MOUNT/etc/initramfs/"{"mkinitcpio.conf.d",".mkinitcpio.conf.d.bak"} 2>/dev/null || true
mkdir -p "$TARGET_MOUNT/etc/initramfs/mkinitcpio.conf.d"
: > "$TARGET_MOUNT/etc/initramfs/mkinitcpio.conf.d/99-shorin-noop.mkinitcpio"
echo "No triggers" > "$TARGET_MOUNT/etc/initramfs/mkinitcpio.conf.d/99-shorin-noop.install"

# ---------------------------------------------------------------------------
# 2. 更新系统 + 基础包
# ---------------------------------------------------------------------------
log "同步 pacman 数据库"
ch "pacman -Sy --noconfirm --needed archlinux-keyring" \
  || warn "keyring 更新失败（若因网络不通，见第 3 步代理配置）"

ch "pacman -Syu --noconfirm" || die "系统更新失败"

log "安装基础包"
# 包名已对 2026-10-05 官方仓库核对：
#   greetd-tuigreet 而非 tuigreet（后者无独立包）
#   wqy-microhei   而非 ttf-wqy-microhei（wqy 系无 ttf- 前缀）
#   noto-fonts-cjk 没有 -extra 变体
ch "pacman -S --noconfirm --needed \
      base-devel git curl wget jq sudo \
      niri dms-shell quickshell matugen cava wl-clipboard cliphist brightnessctl \
      accountsservice power-profiles-daemon \
      xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
      xdg-desktop-portal-wlr \
      greetd greetd-tuigreet \
      fcitx5 fcitx5-chinese-addons fcitx5-configtool fcitx5-gtk fcitx5-qt \
      fcitx5-rime fcitx5-pinyin-zhwiki \
      noto-fonts noto-fonts-cjk noto-fonts-emoji wqy-microhei wqy-zenhei \
      ttf-jetbrains-mono \
      pipewire pipewire-alsa pipewire-jack wireplumber alsa-utils \
      btrfs-progs snapper snap-pac grub-btrfs grub efibootmgr inotify-tools \
      plocate" || die "基础包安装失败"

# ---------------------------------------------------------------------------
# 3. 透明代理（TPClash）
# ---------------------------------------------------------------------------
# 时序很关键：这一步必须在第 4 步（AUR / dms 补充包）之前跑完，
# 否则 AUR 拉不动。这也是原方案强调的"必须在安装 shorin dms niri 前完成"。
# ---------------------------------------------------------------------------
SUB_FILE="/tmp/proxy_subscription"
if [[ -s "$SUB_FILE" ]]; then
  log "检测到订阅链接，开始安装 TPClash"
  # 把订阅链接也带进 chroot
  cp -f "$SUB_FILE" "$TARGET_MOUNT/tmp/proxy_subscription" 2>/dev/null || true

  if ch "/usr/local/bin/install-tpclash.sh --config-file /tmp/proxy_subscription --enable"; then
    log "TPClash 已安装并设为开机自启"
    # 验证：chroot 内不走代理测一下（TPClash 是 TUN 透明代理，chroot 共享 netns，
    # 所以 Live/目标系统里的代理对 chroot 内进程同样生效）
    if ch "systemctl is-enabled tpclash.service"; then
      log "tpclash.service 自启状态正常"
    else
      warn "tpclash.service 自启检查异常"
    fi
  else
    warn "TPClash 安装失败，继续执行（AUR 步骤可能受影响）"
  fi
else
  warn "没有订阅链接，跳过 TPClash。AUR/DMS 步骤可能因网络原因失败。"
  warn "补救：装完后在目标系统里执行  /usr/local/bin/install-tpclash.sh --config-file <你的订阅>"
fi

# ---------------------------------------------------------------------------
# 4. DMS 桌面
# ---------------------------------------------------------------------------
# 重要背景（2026-10-05 实测 shorin-dms-niri-git r142.ccf9e8d-2）：
#   * 官方仓库里已经没有 dms-shell-niri 了（1.5.3 的 split 包被移除，
#     现在只有 dms-shell，自带 dms-shell-compositor）。
#   * DMS 官方的 greeter 功能在发行版包中被 --disable，
#     所以 dms greeter / `dms greeter install` 不可用，只能 greetd-tuigreet。
#   * shorin-dms-niri-git 的 15 个核心依赖里 14 个在官方仓库（很快），
#     只有 dsearch-bin / dgop / xwayland-satellite / 它自己 需要 AUR 编译。
#   * 它的 source 是 git+https://github.com/SHORiN-KiWATA/...
#     GitHub 在国内就是"服务器在 Google" —— 装机时 clone 会挂。
#
# 因此这里的策略是【装机全程不碰 GitHub】：
#   AUR 包在构建机上由 build/prebuild-aur.sh 预编译好，放进本地 [build] 仓库，
#   这里用 pacman -U 装。全程零 AUR 网络请求。
#   退而求其次才退回在线 AUR（需要代理）。
# ---------------------------------------------------------------------------
SHORIN_MODE_DEFAULT="$(cat /etc/shorin-build-mode 2>/dev/null | tr -d '[:space:]')"
[[ -n "$SHORIN_MODE_DEFAULT" ]] || SHORIN_MODE_DEFAULT="skeleton"
SHORIN_MODE="${SHORIN_MODE:-$SHORIN_MODE_DEFAULT}"
log "SHORIN_MODE = $SHORIN_MODE（来源：${SHORIN_MODE:+$SHORIN_MODE_DEFAULT}，可被环境变量覆盖）"

case "$SHORIN_MODE" in
  full)
    log "SHORIN_MODE=full —— 安装 Shorin DMS Niri"

    # 依赖：14 个核心依赖里 13 个在官方仓库，dsearch-bin 走 [build]
    if ch "pacman -S --noconfirm --needed \\
             dms-shell niri quickshell matugen cava wl-clipboard cliphist \\
             xdg-desktop-portal-gnome xwayland-satellite libnotify \\
             power-profiles-daemon qt5-multimedia cups-pk-helper kimageformats \\
             dgop dsearch-bin"; then
      log "Shorin 运行时依赖安装完成"
    else
      warn "部分依赖安装失败，继续"
    fi

    # 预编译的 shorin-dms-niri-git 本体
    if ch "pacman -U --noconfirm --needed shorin-dms-niri-git"; then
      log "shorin-dms-niri-git（本地预编译包）安装成功"
    else
      warn "本地包安装失败 —— 回退到在线 AUR（需要代理，否则大概率失败）"
      if ch "paru -S --noconfirm --needed shorin-dms-niri-git"; then
        log "在线 AUR 安装成功"
      else
        warn "shorin-dms-niri-git 安装失败，保留官方 dms-shell + niri 方案"
      fi
    fi
    ;;

  skeleton)
    log "SHORIN_MODE=skeleton —— 官方 dms-shell + niri，不装 shorin dotfiles"
    ;;

  *)
    warn "未知 SHORIN_MODE=$SHORIN_MODE，退回 skeleton"
    ;;
esac

# ---------------------------------------------------------------------------
# 4b. 预装常用软件
# ---------------------------------------------------------------------------
# vim / LibreOffice / 终端 / 截图 / 文件管理器 等。
# 清单在 common-apps.sh 里，想裁剪直接编辑那个文件。
log "预装常用软件"
ch "/usr/local/bin/common-apps.sh" || warn "常用软件安装有失败项（不阻断）"

# ---------------------------------------------------------------------------
# 5. 用户级配置：dms + niri + fcitx5
# ---------------------------------------------------------------------------
# 关键点：这些配置必须写进 /etc/skel，因为 archinstall/calamares 的用户模块
# 是在装完系统之后才创建用户的，它会把 /etc/skel 复制成新用户家目录。
# 在 chroot 里以 root 身份直接写 /home/<user> 是错的（用户还不存在）。
log "生成 /etc/skel 下的桌面配置"
ch "/usr/local/bin/skel-config.sh" || die "skel 配置生成失败"

ch "chmod -R a+rX /etc/skel"

# ---------------------------------------------------------------------------
# 6. 硬件驱动
# ---------------------------------------------------------------------------
log "硬件驱动检测"
if ch "/usr/local/bin/hw-drivers.sh"; then
  log "驱动配置完成"
else
  warn "驱动脚本返回非 0，请检查 /var/log/shorin-drivers.log"
fi

# ---------------------------------------------------------------------------
# 7. Btrfs 快照
# ---------------------------------------------------------------------------
# 只有 / 真的是 btrfs 且是独立子卷时 snapper 才能用。
# 默认布局（btrfs 单卷）下 / 是 subvol id 5，snapper 无法工作 —— 所以这里做检测，
# 检测不通过就跳过并记录，而不是让 snapper create-config 失败拖垮安装。
log "配置 Btrfs 快照"
ch "/usr/local/bin/setup-snapper.sh" || warn "snapper 配置跳过（详见 /tmp/shorin-install.log）"

# ---------------------------------------------------------------------------
# 8. 显示管理器：sddm → greetd
# ---------------------------------------------------------------------------
log "配置 greetd + tuigreet 指向 niri"
ch "/usr/local/bin/setup-greetd.sh" || die "greetd 配置失败"

# ---------------------------------------------------------------------------
# 9. 部署首次启动删 KDE 的服务
# ---------------------------------------------------------------------------
log "部署 shorin-remove-kde"
# 脚本随 airootfs 一起被 unpackfs 复制到目标了，这里只确保权限
ch "chmod +x /usr/local/bin/shorin-remove-kde.sh"
touch "$TARGET_MOUNT/etc/shorin-remove-kde"
ch "systemctl enable shorin-remove-kde.service" \
  || die "shorin-remove-kde.service 启用失败 —— KDE 不会被清理（可接受，不砖机）"

# ---------------------------------------------------------------------------
# 10. 恢复 initramfs 钩子并重建
# ---------------------------------------------------------------------------
log "恢复 initramfs 触发并重建"
rm -f "$TARGET_MOUNT/etc/initramfs/mkinitcpio.conf.d/99-shorin-noop.mkinitcpio" \
      "$TARGET_MOUNT/etc/initramfs/mkinitcpio.conf.d/99-shorin-noop.install"
rmdir "$TARGET_MOUNT/etc/initramfs/mkinitcpio.conf.d" 2>/dev/null || true
mv "$TARGET_MOUNT/etc/initramfs/.mkinitcpio.conf.d.bak" \
   "$TARGET_MOUNT/etc/initramfs/mkinitcpio.conf.d" 2>/dev/null || true

# 双内核都要有 initramfs，否则重启后某个内核起不来。
# 版本号从 /usr/lib/modules 动态取，不写死（写死会在内核更新后失效）。
log "为双内核重建 initramfs"
ch 'for k in $(ls /usr/lib/modules 2>/dev/null | grep -E "zen|lts" | sort); do
      echo "--- mkinitramfs -P -k $k"
      mkinitramfs -P -k "$k" || echo "  失败: $k"
   done; echo "--- 现有 initramfs:"; ls -1 /boot/initramfs-* 2>/dev/null' \
  || warn "initramfs 重建返回非 0"

log "重建 grub 配置"
ch "grub-mkconfig -o /boot/grub/grub.cfg" || warn "grub-mkconfig 失败"

# ---------------------------------------------------------------------------
# 11. 收尾
# ---------------------------------------------------------------------------
rm -f "$SUB_FILE"
[[ -f "$TARGET_MOUNT/tmp/proxy_subscription" ]] && rm -f "$TARGET_MOUNT/tmp/proxy_subscription"

if [[ -f "$INCOMPLETE" ]]; then
  log "===== post-install 结束（存在失败项，见 $INCOMPLETE）====="
  ch "cat $INCOMPLETE" 2>/dev/null || true
else
  ch "rm -f $INCOMPLETE" 2>/dev/null || true
  log "===== post-install 全部成功 ====="
fi

cp -f "$LOG" "$TARGET_MOUNT/var/log/shorin-install.log" 2>/dev/null || true
log "日志已保存到目标系统 /var/log/shorin-install.log"
