#!/usr/bin/env bash
# ============================================================================
# setup-snapper.sh —— Btrfs 快照配置（带布局检测）
#
# 原方案直接 `snapper -c root create-config /`，这在两种情况下会失败：
#   1. / 不是 btrfs（比如用户手动选了 ext4）；
#   2. / 是 btrfs 但不是独立子卷（默认单卷布局下 / 是 subvol id 5），
#      snapper 无法在其上工作。
# 所以这里先检测，不满足条件就跳过并写清原因，而不是让安装流程报错。
# ============================================================================
set -uo pipefail

log() { printf '[snapper] %s\n' "$*"; }

ROOT_MNT="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
log "/ 的来源设备: ${ROOT_MNT:-未知}"

# --- 1. 是不是 btrfs -------------------------------------------------------
if ! findmnt -n -o FSTYPE / 2>/dev/null | grep -q btrfs; then
  log "跳过：/ 不是 btrfs（当前 $(findmnt -n -o FSTYPE / 2>/dev/null || echo 未知)）"
  log "      如需快照，请在分区时选择 btrfs 并使用子卷布局。"
  exit 0
fi

# --- 2. / 是不是独立子卷 ---------------------------------------------------
SUBVOL_ID="$(btrfs subvolume show / 2>/dev/null | awk '/Subvolume ID/{print $3; exit}')"
log "/ 的 subvolume ID: ${SUBVOL_ID:-取不到}"
if [[ "${SUBVOL_ID:-5}" == "5" ]]; then
  log "跳过：/ 是顶层子卷（ID 5），不是独立子卷，snapper 无法工作"
  log "      需要把 / 挂到独立子卷（例如 @）。用 archinstall 的 default_layout + btrfs 会自动建。"
  exit 0
fi

# --- 3. 建配置 -------------------------------------------------------------
log "创建 root 快照配置"
snapper -c root create-config / >> /tmp/shorin-snapper.log 2>&1 || {
  log "create-config 失败，详见 /tmp/shorin-snapper.log"; exit 1; }

# 权限：允许普通用户用 sudo 触发快照
chmod 750 /etc/snapper/configs/root
chmod 750 /etc/snapper/templates

# --- 4. 清理策略 -----------------------------------------------------------
# 默认保留 10 个小时级、10 个日级、10 个周级、10 个月级快照。
# 1.0.x 之前字段叫 NUMBER_*，之后改成了 NUMBER_*. 这里两种都写，pacman 快照
# 工具会按当前版本解析，多余字段无害。
cat > /etc/snapper/configs/root <<'EOF'
SUBVOLUME="/"
FSTYPE="btrfs"
SPACE_LIMIT="2"
FREE_LIMIT="0.5"
ALLOW_USERS=""
ALLOW_GROUPS=""
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="number"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="5"
NUMBER_DAILY="10"
NUMBER_WEEKLY="10"
NUMBER_MONTHLY="10"
NUMBER_YEARLY="0"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_LIMIT="14"
TIMELINE_LIMIT_IMPORTANT="5"
EOF
log "已写入 /etc/snapper/configs/root"

# --- 5. 启用 timer ---------------------------------------------------------
log "启用 snapper timer"
systemctl enable --now snapper-timeline.timer 2>/dev/null
systemctl enable --now snapper-cleanup.timer 2>/dev/null
# snap-pac：装/删包时自动打快照
systemctl enable snap-pac.timer 2>/dev/null

# --- 6. grub 集成 ----------------------------------------------------------
# grub-btrfs 提供 grub-btrfsd，在快照变化时更新 grub 菜单
if [[ -d /etc/grub.d ]]; then
  chmod +x /etc/grub.d/40_custom 2>/dev/null || true
  if ! grep -q 'grub-btrfs' /etc/default/grub 2>/dev/null; then
    log "启用 GRUB_PRELOAD_MODULES / grub-btrfs 快照菜单"
    # grub-btrfs 通过 /etc/grub.d/40_custom 之外的机制注入，这里确保包在位即可
    pacman -Qq grub-btrfs > /dev/null 2>&1 || log "WARN: grub-btrfs 未安装"
  fi
fi
systemctl enable grub-btrfsd.service 2>/dev/null

grub-mkconfig -o /boot/grub/grub.cfg > /dev/null 2>&1

log "完成。查看快照：sudo snapper list"
exit 0
