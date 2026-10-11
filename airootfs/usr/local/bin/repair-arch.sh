#!/usr/bin/env bash
# ============================================================================
# repair-arch.sh —— Live 环境里的救援工具
#
# 解决的问题：
#   我们的系统用 btrfs + snapper，每次更新前自动打快照。
#   好处是"坏了能回滚"，但如果系统开不了机，
#   光有快照没用 —— 得有个东西帮你把系统挂上、回滚、修。
#
# 能干什么：
#   1. 扫盘，找到装了 ARCH_SHORIN 的 btrfs
#   2. 列快照（读 .snapshots/*/snapshot 的元数据，不依赖目标系统能跑）
#   3. 回滚到指定快照（按子卷【ID】而不是名字 —— 这是关键，见下）
#   4. 进入 chroot 救援终端，手动修
#   5. 一键修内核 / 重建 initramfs / 重装 grub
#   6. 看上一份日志，找出到底哪一步挂的
#
# ⚠️ 为什么必须用 subvolid 而不是 subvol=@：
#   snapper 回滚会把"默认子卷"切到某个 .snapshots/<N>/snapshot 上，
#   于是原来的 @ 只剩一个 ID（256 之类），名字不再指向它。
#   用 subvol=@ 去挂会挂到一个"已经不是主系统"的旧目录上，
#   看着能进 chroot，其实是在救援一个僵尸系统。
#   正确做法是挂 subvolid=5（top-level），列出所有子卷，
#   找出 snapshot 里的 default 指向哪个，再按 ID 挂。
# ============================================================================
set -uo pipefail

LOG=/tmp/shorin-repair.log
MNT=/mnt/shorin-rescue          # 救援挂载点
: >"$LOG"

say()  { printf '\033[1;36m[救援]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
err()  { printf '\033[31m  ✗\033[0m %s\n' "$*" | tee -a"$LOG"; }
die()  { err "$*"; exit 1; }
elog() { printf '[救援] %s\n' "$*" >>"$LOG"; }

usage() {
    cat <<'EOF'

  ARCH_SHORIN 救援工具

  用法：
    repair-arch.sh                 进入菜单（推荐）
    repair-arch.sh list            扫描并列出找到的系统 + 快照
    repair-arch.sh shell           挂载系统并直接进 chroot
    repair-arch.sh rollback <N>    回滚到第 N 号快照
    repair-arch.sh fix-kernel      重装内核 + 重建 initramfs
    repair-arch.sh fix-grub        重装 grub 引导
    repair-arch.sh logs            找出一份能读的系统日志

  快照里已经坏掉进不去时，先用 logs 看上一份日志，
  确认是内核的问题再 rollback 或 fix-kernel。

EOF
}

# ---------------------------------------------------------------------------
# 1. 找出装了 ARCH_SHORIN 的 btrfs
# ---------------------------------------------------------------------------
# 为什么要找 top-level（subvolid=5）而不是直接找 @：
#   回滚过快照的系统里，"当前默认子卷"已经不是 @ 了。
#   挂 subvolid=5 能看到【所有】子卷，包括所有 .snapshots/*，
#   这是唯一在各种状态下都靠得住的入口。
find_targets() {
    local dev found=0
    say "扫描 btrfs 子卷…"
    local tmp; tmp=$(mktemp -d)
    for dev in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="part"{print $1}'; \
                 lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}') ; do
        local p="/dev/$dev"
        # btrfs 子卷要挂到已存在的空目录才能查
        mount -o subvolid=5,ro "$p" "$tmp" 2>/dev/null || continue
        local subs; subs=$(btrfs subvolume list "$tmp" 2>/dev/null)
        if printf '%s' "$subs" | grep -q "path .*\(@\|ID 5\)"; then
            local has_shorin=0
            printf '%s' "$subs" | grep -q "@home\|@log\|@pkg" && has_shorin=1
            if [ "$has_shorin" = 1 ]; then
                found=1
                ok "找到候选系统：$p"
                printf '%s\n' "$subs" | head -40 | sed 's/^/      /'
                TARGET_DEV="$p"
            fi
        fi
        umount "$tmp" 2>/dev/null
    done
    rmdir "$tmp" 2>/dev/null
    [ "$found" = 1 ] || die "没找到带 @home/@log/@pkg 子卷的 btrfs。
        * 如果你刚装完还没重启过，系统应该是能启动的
        * 如果子卷被改名了，用 lsblk -f 看一眼实际布局
        * 完整日志在 $LOG"
    echo "$TARGET_DEV"
}

# ---------------------------------------------------------------------------
# 2. 正常挂载（能启动时）
# ---------------------------------------------------------------------------
# 直接按目标系统自己的 fstab 挂 —— UUID 和 subvol 都是它自己写的，最准。
mount_normal() {
    local dev="$1"
    rm -rf "$MNT"; mkdir -p "$MNT"
    say "按目标系统的 fstab 挂载（子卷名 @ / @home …）"
    mount "$dev" "$MNT" || die "挂载 $dev 失败"
    # btrfs 一次挂载会带出所有子卷；fstab 里其余子卷靠同一 device 再挂一次
    while read -r _mp _dev _opts _rest; do
        case "$_mp" in "/$MNT"*) ;; *) continue ;; esac
        case "$_mp" in /home|/var/log|/var/cache|/swap) ;; *) continue ;; esac
        mkdir -p "$MNT$_mp"
        mount -o "$_opts" "$_dev" "$MNT$_mp" 2>/dev/null \
          && ok "挂 $_mp（$_opts）" \
          || warn "挂 $_mp 失败，跳过"
    done <"$MNT/etc/fstab"
    # EFI 分区：fstab 里没有，挂上才能重装 grub
    local esp; esp=$(findmnt -no SOURCE --target /sys/firmware/efi/efivars 2>/dev/null)
    if [ -z "$esp" ]; then
        esp=$(blkid -t TYPE=vfat -o device 2>/dev/null | head -1)
    fi
    if [ -n "$esp" ] && [ -d "$MNT/boot" ]; then
        grep -q "/boot" "$MNT/etc/fstab" || {
            mount "$esp" "$MNT/boot" 2>/dev/null && ok "挂 /boot（$esp）" || warn "EFI 分区挂不上"
        }
    fi
}

# ---------------------------------------------------------------------------
# 3. 按快照挂载（回滚前预览 / 系统已坏时）
# ---------------------------------------------------------------------------
# 走 top-level → 找 /.snapshots/<N>/snapshot → 按【ID】挂。
# 这样即使默认子卷已经切走，也能挂到任意一个历史状态。
mount_snapshot() {
    local dev="$1" num="$2"
    local top; top=$(mktemp -d)
    rm -rf "$MNT"; mkdir -p "$MNT"

    mount -o subvolid=5,ro "$dev" "$top" || die "挂 top-level 失败"
    local snapdir="$top/.snapshots/$num/snapshot"
    [ -d "$snapdir" ] || { umount "$top"; die "没有第 $num 号快照"; }

    local sid; sid=$(btrfs inspect-internal map-subvolume "$snapdir" 2>/dev/null | head -1)
    if [ -z "$sid" ]; then
        sid=$(btrfs subvolume list "$top" 2>/dev/null \
              | awk -v p="$snapdir" '$0 ~ "path "p"$" {for(i=1;i<=NF;i++) if($i=="ID") print $(i+1)}' | head -1)
    fi
    [ -n "$sid" ] || { umount "$top"; die "读不出快照 $num 的子卷 ID"; }

    say "第 $num 号快照，子卷 ID = $sid（用 ID 挂，不靠名字）"
    mount -o "subvolid=$sid,ro" "$dev" "$MNT" || { umount "$top"; die "按 ID 挂载失败"; }
    # 只读挂载预览；要真改就在 rollback 之后重新正常挂
    umount "$top"; rmdir "$top" 2>/dev/null
    ok "已以只读方式挂载快照 $num 到 $MNT"
}

# ---------------------------------------------------------------------------
# 4. chroot
# ---------------------------------------------------------------------------
# 必须绑的这些，否则 chroot 里一半命令直接报错：
#   /proc  /sys  /dev  /dev/pts  /run
#   /sys/firmware/efi/efivars —— 没这个 grub-install 装不了 EFI 引导
in_chroot() {
    mkdir -p "$MNT"/{proc,sys,dev,dev/pts,run}
    mount -t proc proc "$MNT/proc"
    mount -t sysfs sys "$MNT/sys"
    mount --bind /dev "$MNT/dev"
    mount -t devpts devpts "$MNT/dev/pts"
    mount --bind /run "$MNT/run"
    if [ -d /sys/firmware/efi/efivars ]; then
        mount --bind /sys/firmware/efi/efivars "$MNT/sys/firmware/efi/efivars" 2>/dev/null
    fi
    # resolv.conf：Live 里可能要代理，救援时网络不通
    if [ -e "$MNT/etc/resolv.conf" ] && [ ! -L "$MNT/etc/resolv.conf" ]; then
        cp -L /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
    fi
}

out_chroot() {
    umount -R "$MNT" 2>/dev/null || {
        for m in run dev/pts dev sys proc sys/firmware/efi/efivars; do
            umount "$MNT/$m" 2>/dev/null || true
        done
    }
}

chroot_do() { chroot "$MNT" /bin/bash -c "$1"; }

# ---------------------------------------------------------------------------
# 5. 各项操作
# ---------------------------------------------------------------------------
do_rollback() {
    local num="$1"
    say "回滚到第 $num 号快照"
    mount_snapshot "$TARGET_DEV" "$num" 2>/dev/null || true
    # 上面对比用的只读挂要卸掉，重新按【名字】正常挂
    umount -R "$MNT" 2>/dev/null || true
    rm -rf "$MNT"; mkdir -p "$MNT"

    mount "$TARGET_DEV" "$MNT" || die "挂载失败"
    in_chroot
    # snapper rollback 会把默认子卷切过去，/etc/fstab 不用动
    # （fstab 里写的是 subvol=@，回滚后 @ 依然存在，只是默认指向变了）
    if chroot_do "snapper -c root rollback $num" ; then
        ok "回滚完成（snapper 已把默认子卷切到第 $num 号）"
    else
        warn "snapper rollback 返回非 0，试直接切默认子卷…"
        local sid
        sid=$(btrfs inspect-internal map-subvolume "$MNT/.snapshots/$num/snapshot" 2>/dev/null | head -1)
        btrfs subvolume set-default "$sid" "$MNT" && ok "已把默认子卷切到 ID $sid" || die "切默认子卷失败"
    fi
    ok "现在可以重启回去试了。想先进去看看：repair-arch.sh shell"
    out_chroot
}

do_fix_kernel() {
    say "重装内核 + 重建 initramfs"
    mount_normal "$TARGET_DEV" || die "挂载失败"
    in_chroot

    # 优先用目标系统 pacman 缓存里的包（离线也能修）；
    # 缓存里没有再联网从官方源装。
    local pkgs
    pkgs=$(chroot_do "ls /var/cache/pacman/pkg/linux-*.pkg.tar.zst 2>/dev/null | xargs -r -n1 basename" || true)
    if [ -n "$pkgs" ]; then
        ok "用目标系统缓存里的内核包（离线可用）：$(echo "$pkgs" | tr '\n' ' ')"
        chroot_do "pacman -U --noconfirm /var/cache/pacman/pkg/linux-*.pkg.tar.zst" \
          || chroot_do "pacman -U --noconfirm \$(ls /var/cache/pacman/pkg/linux-*.pkg.tar.zst)"
    fi
    # 保证两个内核都在（救援时最怕的就是只剩一个坏掉的）
    chroot_do "pacman -S --noconfirm --needed linux-zen linux-lts linux-zen-headers linux-lts-headers" \
      || warn "联网重装内核失败（没网就靠上面缓存里的包）"

    say "重建 initramfs"
    chroot_do "mkinitcpio -P" || warn "mkinitcpio 返回非 0，看 /tmp/shorin-repair.log"
    ok "内核处理完毕"
    out_chroot
}

do_fix_grub() {
    say "重装 grub 引导"
    mount_normal "$TARGET_DEV" || die "挂载失败"
    in_chroot
    # UEFI 还是 BIOS，决定装到哪个设备
    if [ -d /sys/firmware/efi/efivars ]; then
        local esp; esp=$(findmnt -no SOURCE,OPTIONS --target /sys/firmware/efi/efivars 2>/dev/null)
        chroot_do "grub-install --target=x86_64-efi --efi-directory=/boot --recheck" \
          || chroot_do "grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck" \
          || warn "grub-install EFI 失败，看日志"
    else
        local d; d=$(chroot_do "lsblk -no PKNAME" | head -1)
        [ -n "$d" ] || d="sda"
        chroot_do "grub-install --target=i386-pc --recheck /dev/$d" || warn "grub-install BIOS 失败"
    fi
    chroot_do "grub-mkconfig -o /boot/grub/grub.cfg" || warn "生成 grub.cfg 失败"
    ok "grub 处理完毕"
    out_chroot
}

do_logs() {
    say "找一份能读的日志"
    local dev; dev=$(find_targets | tail -1)
    mount_normal "$dev" 2>/dev/null || die "挂载失败"
    # 日志在 @log 子卷里（如果 @log 挂了，就退回看 @ 里的旧日志）
    local src="$MNT/var/log"
    [ -d "$src" ] || src="$MNT"
    say "日志目录：$src"
    echo
    ls -1t "$src"/*.log "$src"/journal 2>/dev/null | head -10 | sed 's/^/    /'
    echo
    say "最近的错误（journal 优先，其次 syslog）"
    if [ -d "$src/journal" ]; then
        journalctl --directory="$src/journal" -p err -n 30 --no-pager 2>/dev/null | sed 's/^/    /' \
          || warn "读 journal 失败"
    fi
    [ -f "$src/messages" ] && tail -40 "$src/messages" | sed 's/^/    /'
    [ -f "$src/pacman.log" ] && { echo; say "最近装的包"; tail -15 "$src/pacman.log" | sed 's/^/    /'; }
    echo
    ok "看完按回车卸载"
    read -r
    out_chroot
}

# ---------------------------------------------------------------------------
# 6. 菜单
# ---------------------------------------------------------------------------
menu() {
    while :; do
        echo
        echo "  ┌────────────────────────────────────────────┐"
        echo "  │  ARCH_SHORIN 救援工具                      │"
        echo "  ├────────────────────────────────────────────┤"
        echo "  │  1) 扫描并列出系统 + 快照                   │"
        echo "  │  2) 进入救援终端（chroot）                  │"
        echo "  │  3) 回滚到指定快照                          │"
        echo "  │  4) 修内核（重装 + 重建 initramfs）         │"
        echo "  │  5) 修 grub 引导                           │"
        echo "  │  6) 看日志（先看这个，能少走弯路）           │"
        echo "  │  q) 退出                                   │"
        echo "  └────────────────────────────────────────────┘"
        printf "\n  请选择 > "
        read -r c || return
        case "$c" in
            1) TARGET_DEV=$(find_targets | tail -1)
               mount_normal "$TARGET_DEV" 2>/dev/null && {
                 say "当前子卷："
                 btrfs subvolume list "$MNT" 2>/dev/null | sed 's/^/      /'
                 ok "看完按回车"; read -r; out_chroot; } ;;
            2) TARGET_DEV=$(find_targets | tail -1)
               mount_normal "$TARGET_DEV" || continue
               in_chroot
               clear; say "已进入救援终端。exit 退出。"; echo
               chroot "$MNT" /bin/bash || true
               out_chroot ;;
            3) TARGET_DEV=$(find_targets | tail -1)
               mount "$TARGET_DEV" /tmp/_snaproot 2>/dev/null && {
                 btrfs subvolume list /tmp/_snaproot 2>/dev/null | grep snapshots | sed 's/^/    /'
                 umount /tmp/_snaproot; }
               printf "  回滚到第几号快照？> "; read -r n
               [ -n "$n" ] && do_rollback "$n" ;;
            4) TARGET_DEV=$(find_targets | tail -1); do_fix_kernel ;;
            5) TARGET_DEV=$(find_targets | tail -1); do_fix_grub ;;
            6) do_logs ;;
            q|Q) return ;;
            *) warn "看不懂" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
case "${1:-}" in
    "")       usage; menu ;;
    list)     usage; TARGET_DEV=$(find_targets | tail -1); mount_normal "$TARGET_DEV"; btrfs subvolume list "$MNT"; read -r; out_chroot ;;
    shell)    TARGET_DEV=$(find_targets | tail -1); mount_normal "$TARGET_DEV"; in_chroot; clear; chroot "$MNT" /bin/bash; out_chroot ;;
    rollback) shift; TARGET_DEV=$(find_targets | tail -1); do_rollback "$1" ;;
    fix-kernel) TARGET_DEV=$(find_targets | tail -1); do_fix_kernel ;;
    fix-grub)  TARGET_DEV=$(find_targets | tail -1); do_fix_grub ;;
    logs)     do_logs ;;
    -h|--help|help) usage ;;
    *)        usage; die "不认识：$1" ;;
esac