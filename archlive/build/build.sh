#!/usr/bin/env bash
# ============================================================================
# build.sh —— 一键构建 ARCH_SHORIN ISO
#
# 前置条件：在一台【Arch Linux】机器上以 root 运行（必须是 Arch，
#          因为 mkarchiso 用宿主的 pacman 数据库取包）
# ============================================================================
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/archiso-work}"
OUT_DIR="${OUT_DIR:-/tmp/archiso-out}"
JOBS="${JOBS:-$(nproc)}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请以 root 运行"
[[ -r /etc/os-release ]] || die "读不到 /etc/os-release"
grep -q '^ID=arch$' /etc/os-release || die "必须在 Arch Linux 上构建（当前不是）"
command -v mkarchiso > /dev/null || die "没装 archiso：pacman -S --needed archiso"

# ---- 0. 先跑 preflight，别等 mkarchiso 挂掉才发现包名写错 -----------------
say "检查自编译的 Calamares 是否就位"
if ! compgen -G "$PROFILE_DIR/airootfs/etc/pacman.d/build-repo/calamares-*.pkg.tar.zst" > /dev/null; then
  echo "  未找到 calamares 包。"
  echo "  先用【普通用户】运行： bash build/build-calamares.sh"
  echo "  （makepkg 拒绝 root；这一步会拉 Qt6 开发包并编译 10~25 分钟）"
  die "calamares 未就绪"
fi
ls -lh "$PROFILE_DIR"/airootfs/etc/pacman.d/build-repo/calamares-*.pkg.tar.zst

say "运行 preflight 自检"
bash "$PROFILE_DIR/build/preflight.sh" "$PROFILE_DIR" || die "preflight 没过，先修上面的问题"

# ---- 1. 依赖 ---------------------------------------------------------------
say "检查构建依赖"
missing=()
for p in squashfs-tools libisoburn dosfstools mtools arch-install-scripts; do
  pacman -Qq "$p" &>/dev/null || missing+=("$p")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  say "安装缺失依赖: ${missing[*]}"
  pacman -S --needed --noconfirm "${missing[@]}"
fi

# ---- 2. 权限修正 -----------------------------------------------------------
say "修正权限"
chmod +x "$PROFILE_DIR"/airootfs/usr/local/bin/*.sh
chmod 644 "$PROFILE_DIR"/airootfs/etc/pacman.conf
chmod 600 "$PROFILE_DIR"/airootfs/etc/pacman.d/mirrorlist*
chmod 644 "$PROFILE_DIR"/profiledef.sh "$PROFILE_DIR"/packages.x86_64
# pacman 需要 mirrorlist 可读
chmod 644 "$PROFILE_DIR"/airootfs/etc/pacman.d/mirrorlist*

# ---- 3. 构建 ---------------------------------------------------------------
say "mkarchiso  （工作目录 $WORK_DIR，输出 $OUT_DIR）"
say "这一步会下载 4~6 GB 包，10~40 分钟取决于网速和镜像"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"

# ---- 4. 产物 ---------------------------------------------------------------
ISO="$(ls -1 "$OUT_DIR"/archlinux-shorin-*.iso 2>/dev/null | head -1 || true)"
[[ -n "$ISO" ]] || die "构建结束但没找到 ISO"

say "构建完成"
ls -lh "$ISO"

cat <<EOF

下一步：
  1) 在虚拟机里测试（BIOS 和 UEFI 都要测）
       qemu-system-x86_64 -enable-kvm -m 8192 -smp 4 \\
         -bios ovmf -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.fd \\
         -cdrom $ISO -boot d

  2) ISO 装机后必查（见 README-修正说明.md 第 6 节）
       - niri 能否进图形
       - greetd autologin 是否生效
       - KDE 是否被删干净、有没有残留
       - 代理是否通
       - 重启后是否进 niri

  3) 确认无误后再做成 .img 写 U 盘：
       dd if=$ISO of=/dev/sdX bs=4M status=progress conv=fsync
     ⚠️ 确认设备名，别把整块盘擦了。
EOF
