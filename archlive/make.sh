#!/usr/bin/env bash
# ============================================================================
# make.sh —— 一条命令产出 archlinux-shorin-*.iso
#
# 必须在一台【Arch Linux】机器上运行，且以【普通用户】运行（makepkg 拒绝 root）。
# 整个流程全自动：编译 Calamares → 预编译 AUR → 自检 → 构建 ISO → 写盘
#
#   bash make.sh                    # 完整流程
#   SKIP_CALAMARES=1 bash make.sh   # 跳过编 Calamares（已编过时）
#   SKIP_AUR=1 bash make.sh         # 跳过预编译 AUR（用 skeleton 模式时）
#   SHORIN_MODE=full bash make.sh   # 连 Shorin DMS Niri dotfiles 一起装
#   PROFILE_ONLY=1 bash make.sh     # 只做编译，跳过 ISO 构建
#   BURN=/dev/sdX bash make.sh      # 构建完直接写 U 盘（会二次确认）
# ============================================================================
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$PROFILE_DIR/out}"
WORK_DIR="${WORK_DIR:-/tmp/archiso-work}"
SHORIN_MODE="${SHORIN_MODE:-skeleton}"
BURN="${BURN:-}"
SKIP_CALAMARES="${SKIP_CALAMARES:-0}"
SKIP_AUR="${SKIP_AUR:-0}"
PROFILE_ONLY="${PROFILE_ONLY:-0}"
KEEP_AUR="${KEEP_AUR:-0}"

step()  { printf '\n\033[1;36m━━━ %s\033[0m\n' "$*"; }
info()  { printf '  \033[90m·\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()   { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }

# ═══════════════════════════════════════════════════════════════════════════
# 0. 环境检查 —— 先把"跑不起来"的原因说清楚，别等半小时后才发现
# ═══════════════════════════════════════════════════════════════════════════
step "0/6  环境检查"

if [[ ! -r /etc/os-release ]] || ! grep -q '^ID=arch$' /etc/os-release; then
  echo "  当前系统: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo 未知)"
  die "必须在 Arch Linux 上构建。mkarchiso 依赖宿主 pacman 数据库，别的发行版跑不了。
      建议用 Arch 官方 ISO 启动一台虚拟机来构建。
      下载：https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
fi
ok "Arch Linux"

if [[ $EUID -eq 0 ]]; then
  die "请以普通用户运行（makepkg 拒绝 root）。需要 sudo 权限装依赖。
      提示：mkarchiso 本身需要 root，本脚本内部会自己 sudo，你不要用 sudo 跑本脚本。"
fi
ok "普通用户"

command -v sudo > /dev/null || die "没有 sudo"
sudo -n true 2>/dev/null || warn "sudo 需要密码，中途可能会停下来等你输 —— 正常"
command -v makepkg > /dev/null || die "没装 base-devel：sudo pacman -S --needed base-devel"
ok "构建工具链"

DISK_AVAIL_KB=$(df -Pk "$WORK_DIR" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
if [[ "$DISK_AVAIL_KB" -lt 15728640 ]]; then
  warn "工作目录可用空间不足 15GB（ISO 构建大约需要）"
  warn "  当前: $((DISK_AVAIL_KB / 1024 / 1024))GB   改用 WORK_DIR=/更大的路径 重新运行"
else
  ok "磁盘空间 $((DISK_AVAIL_KB / 1024 / 1024))GB"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 1. 编译 Calamares
# ═══════════════════════════════════════════════════════════════════════════
step "1/6  编译 Calamares（跳过：$SKIP_CALAMARES）"

if [[ "$SKIP_CALAMARES" == "1" ]]; then
  info "按要求跳过"
elif compgen -G "$PROFILE_DIR/airootfs/etc/pacman.d/build-repo/calamares-*.pkg.tar.zst" > /dev/null; then
  ok "已存在，跳过（要重编就设 SKIP_CALAMARES=0 并先删掉 build-repo/calamares-*）"
else
  bash "$PROFILE_DIR/build/build-calamares.sh" || die "Calamares 编译失败"
  ok "完成"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 1b. 预置 TPClash 二进制
#     目的是让【装机全程不连 GitHub】。CI 上一定能抓到。
# ═══════════════════════════════════════════════════════════════════════════
step "1b/6  预置 TPClash 二进制"
bash "$PROFILE_DIR/build/prefetch-binaries.sh" || warn "没抓到，装机时会现下（仅影响 TPClash）"

# ═══════════════════════════════════════════════════════════════════════════
# 2. 预编译 AUR 包（SHORIN_MODE=full 才需要）
# ═══════════════════════════════════════════════════════════════════════════
step "2/6  预编译 AUR 包（模式：$SHORIN_MODE）"

if [[ "$SKIP_AUR" == "1" || "$SHORIN_MODE" != "full" ]]; then
  info "skeleton 模式不需要 AUR 包（$SHORIN_MODE）"
  [[ "$SHORIN_MODE" != "full" ]] && info "想装 Shorin dotfiles：SHORIN_MODE=full bash make.sh"
else
  if compgen -G "$PROFILE_DIR/airootfs/etc/pacman.d/build-repo/shorin-dms-niri-git-*.pkg.tar.zst" > /dev/null; then
    ok "已存在，跳过"
  else
    bash "$PROFILE_DIR/build/prebuild-aur.sh" || warn "AUR 预编译失败，full 模式会退回在线 AUR（需代理）"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# 3. 自检
# ═══════════════════════════════════════════════════════════════════════════
step "3/6  自检"

# 让 preflight 能查到本地 [build] 仓库
BUILD_DB="$(ls -1 "$PROFILE_DIR"/airootfs/etc/pacman.d/build-repo/*.db.tar.gz 2>/dev/null | head -1)"
if [[ -n "$BUILD_DB" ]]; then
  if ! grep -qF "$BUILD_DB" /etc/pacman.conf 2>/dev/null; then
    info "把本地仓库挂到宿主 pacman.conf（便于 pacman 直接解析）"
    echo "Include = $BUILD_DB" | sudo tee -a /etc/pacman.conf > /dev/null
    sudo pacman -Sy --noconfirm > /dev/null 2>&1 || warn "pacman -Sy 失败，preflight 可能仍报 calamares 缺失"
  fi
  ok "本地仓库已接入宿主 pacman"
fi

if bash "$PROFILE_DIR/build/preflight.sh" "$PROFILE_DIR"; then
  ok "preflight 通过"
else
  warn "preflight 有 FAIL。先修掉再构建，否则 mkarchiso 会在取包时失败。"
  read -r -p "  仍然继续？(y/N) " ans
  [[ "${ans:-N}" == "y" || "${ans:-N}" == "Y" ]] || die "已中止"
fi

if [[ "$PROFILE_ONLY" == "1" ]]; then
  step "完成（PROFILE_ONLY=1，跳过 ISO 构建）"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# 4. 构建 ISO
# ═══════════════════════════════════════════════════════════════════════════
step "4/6  构建 ISO（10~40 分钟，下载 6~10GB 包）"

sudo pacman -S --needed --noconfirm archiso squashfs-tools libisoburn dosfstools mtools \
  || die "构建依赖安装失败"

chmod +x "$PROFILE_DIR"/airootfs/usr/local/bin/*.sh 2>/dev/null || true

sudo rm -rf "$WORK_DIR"
sudo mkdir -p "$WORK_DIR" "$OUT_DIR"

# SHORIN_MODE 必须【写进 ISO 的文件系统】才有效 ——
# 给 mkarchiso 设环境变量是没用的，它不会进到 airootfs 里，
# 装机时 post-install.sh 读的是目标系统里 /etc/shorin-build-mode 这个文件。
printf '%s\n' "$SHORIN_MODE" > "$PROFILE_DIR/airootfs/etc/shorin-build-mode"
info "已写入 /etc/shorin-build-mode = $SHORIN_MODE"
if [[ "$SHORIN_MODE" == "full" ]] \
   && ! compgen -G "$PROFILE_DIR/airootfs/etc/pacman.d/build-repo/shorin-dms-niri-git-*.pkg.tar.zst" > /dev/null; then
  warn "模式是 full 但没有预编译的 shorin-dms-niri-git 包"
  warn "装机时会退回在线 AUR，没有代理就会失败"
  warn "现在补编译还来得及：Ctrl-C 然后跑  bash build/prebuild-aur.sh"
  read -r -p "  继续？(y/N) " ans
  [[ "${ans:-N}" == "y" || "${ans:-N}" == "Y" ]] || die "已中止"
fi

sudo mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR" \
  || die "mkarchiso 失败"

ISO="$(ls -1t "$OUT_DIR"/archlinux-shorin-*.iso 2>/dev/null | head -1)"
[[ -n "$ISO" ]] || die "构建结束但没找到 ISO"
ok "ISO 产出：$(du -h "$ISO" | cut -f1)"

# ═══════════════════════════════════════════════════════════════════════════
# 5. 校验 + 虚拟机测试命令
# ═══════════════════════════════════════════════════════════════════════════
step "5/6  校验"

info "SHA256: $(sha256sum "$ISO" | cut -d' ' -f1)"
ok "$ISO"

# 用 bsdtar 验一下 ISO 结构（不挂载也能查）
if command -v bsdtar > /dev/null; then
  n=$(bsdtar -tf "$ISO" 2>/dev/null | wc -l)
  ok "ISO 目录项 $n 个"
fi
if command -v isoinfo > /dev/null; then
  label=$(isoinfo -d -i "$ISO" 2>/dev/null | grep -i "volume id" || true)
  ok "卷标: $label"
fi

step "6/6  测试"
cat <<EOF

在虚拟机里测（BIOS 和 UEFI 都要测一遍）：

  # UEFI
  qemu-system-x86_64 -enable-kvm -m 8192 -smp 4 \\
    -bios ovmf \\
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.fd \\
    -cdrom $(basename "$ISO") -boot d

  # BIOS
  qemu-system-x86_64 -enable-kvm -m 8192 -smp 4 \\
    -cdrom $(basename "$ISO") -boot d

装机后必查（详细清单见 README-修正说明.md 第 12 节）：
  1. 双击桌面「安装 Arch Linux」→ 弹出订阅输入框 → 安装器能起来
  2. 装完重启，能进 niri 桌面
  3. pacman -Q | grep -i plasma  应为空（KDE 已删）
  4. 第二次重启，仍然进 niri
  5. /var/lib/shorin-incomplete 不应存在

EOF

# ═══════════════════════════════════════════════════════════════════════════
# 6. 可选：写 U 盘
# ═══════════════════════════════════════════════════════════════════════════
if [[ -n "$BURN" ]]; then
  step "写盘"
  cat <<EOF
目标设备: $BURN

  ⚠️  这会【彻底擦除】$BURN 上的所有数据。
  ⚠️  再确认一次这个设备号 —— 写错就是整块盘没了。
EOF
  lsblk -o NAME,SIZE,MODEL,MOUNTPOINT 2>/dev/null || true
  echo
  read -r -p "确认要写入 $BURN ?（输入设备号确认）: " ans
  [[ "$ans" == "$BURN" ]] || die "输入与设备号不符，已中止"
  sudo dd if="$ISO" of="$BURN" bs=4M status=progress conv=fsync
  sudo sync
  ok "写入完成"
fi

step "全部完成 🎉"
echo "ISO: $ISO"
