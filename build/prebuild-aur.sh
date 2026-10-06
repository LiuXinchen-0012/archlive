#!/usr/bin/env bash
# ============================================================================
# prebuild-aur.sh —— 在【构建机】上预编译 AUR 包，塞进 ISO 的本地 [build] 仓库
#
# 为什么需要：
#   shorin-dms-niri-git 的 source 是 git+https://github.com/SHORiN-KiWATA/...
#   GitHub 在国内就是"服务器在 Google"，装机时 clone 基本连不上。
#   它的依赖 dgop / xwayland-satellite / dsearch-bin 也都从 GitHub Releases 下载。
#
#   所以：构建机（能连 GitHub 的那台）先把它们编好，ISO 装机时 pacman -U 即可，
#   整个安装过程【不需要访问 GitHub】。
#
# 依赖结构（2026-10-05 实测 shorin-dms-niri-git r142.ccf9e8d-2）：
#   15 个核心依赖里 14 个在官方仓库（清华/中科大源，很快）
#   真正要 AUR 编译的只有 4 个：
#     dsearch-bin           二进制包（GitHub Releases 下载）
#     dgop                  Go（GitHub tarball）
#     xwayland-satellite    Rust（GitHub tarball）
#     shorin-dms-niri-git   纯 dotfiles（git clone）★ 唯一必须 clone 的
#
# 用法：普通用户 + sudo
#   bash build/prebuild-aur.sh              # 全部
#   ONLY=shorin-dms-niri-git bash build/prebuild-aur.sh
# ============================================================================
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$PROFILE_DIR/build/repo"
ISO_REPO="$PROFILE_DIR/airootfs/etc/pacman.d/build-repo"
PKGDIR="${PKGDIR:-$PROFILE_DIR/build/aur-pkgs}"
ONLY="${ONLY:-}"

PKGS=(
  dsearch-bin
  dgop
  xwayland-satellite
  shorin-dms-niri-git
)

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN: %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "请用普通用户运行（makepkg 不允许 root）"

# ---------------------------------------------------------------------------
# 0. 构建机自身的网络自检 —— 提前说清楚失败在哪
# ---------------------------------------------------------------------------
say "检查构建机到 GitHub 的连通性"
if ! git ls-remote --exit-code -h https://github.com/SHORiN-KiWATA/shorin-dms-niri.git HEAD &>/dev/null; then
  warn "连不上 github.com —— 构建机自己也需要代理才能编译这些包"
  warn "先给这台构建机配好代理（临时设 https_proxy，或用 clash 客户端的全局模式）"
  warn "配好后重跑本脚本"
  die "GitHub 不可达"
fi
echo "  ok  GitHub 可达"

# ---------------------------------------------------------------------------
# 1. 拉 PKGBUILD
# ---------------------------------------------------------------------------
mkdir -p "$PKGDIR"

for p in "${PKGS[@]}"; do
  [[ -n "$ONLY" && "$p" != "$ONLY" ]] && continue

  say "===== $p ====="
  d="$PKGDIR/$p"
  rm -rf "$d"; mkdir -p "$d"

  if ! curl -sfL --max-time 30 "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=$p" -o "$d/PKGBUILD"; then
    warn "$p: 拉不到 PKGBUILD，跳过"
    continue
  fi
  # AUR 有时把 source 拆到 .SRCINFO 旁边的文件里；这里把常见附属文件也拉下来
  for extra in "$p.install" "$p.desktop" "$p.service" ".AURINFO"; do
    curl -sfL --max-time 20 "https://aur.archlinux.org/cgit/aur.git/plain/$extra?h=$p" -o "$d/$extra" 2>/dev/null || true
  done
  # 源码目录名未必等于包名，从 PKGBUILD 里读出来
  srcdir=$(sed -nE 's/^_?pkgname=//p' "$d/PKGBUILD" | head -1 | tr -d '"'"'"' ')
  echo "  源目录: ${srcdir:-$p}"

  if ! ( cd "$d" && makepkg -f --noconfirm --clean 2>&1 | tail -25 ); then
    warn "$p: 编译失败，跳过（不阻断其它包）"
    continue
  fi

  built=$(ls -1t "$d"/*.pkg.tar.zst 2>/dev/null | head -1)
  if [[ -n "$built" ]]; then
    echo "  产物: $(basename "$built")  ($(du -h "$built" | cut -f1))"
  else
    warn "$p: 没找到产物"
  fi
done

# ---------------------------------------------------------------------------
# 2. 汇总进本地仓库
# ---------------------------------------------------------------------------
say "汇总到本地仓库"
BUILT=()
for p in "${PKGS[@]}"; do
  [[ -n "$ONLY" && "$p" != "$ONLY" ]] && continue
  f=$(ls -1 "$PKGDIR/$p"/*.pkg.tar.zst 2>/dev/null | head -1)
  [[ -n "$f" ]] && BUILT+=("$f")
done

if [[ ${#BUILT[@]} -eq 0 ]]; then
  die "一个包都没编出来，检查上面的错误"
fi

sudo mkdir -p "$REPO_DIR" "$ISO_REPO"
for f in "${BUILT[@]}"; do
  sudo cp "$f" "$REPO_DIR"/
  sudo cp "$f" "$ISO_REPO"/
done

# repo-add 会重算依赖关系，所以要一起收
say "生成仓库数据库"
sudo repo-add -f "$REPO_DIR/arch-shorin.db.tar.gz" "$REPO_DIR"/*.pkg.tar.zst > /dev/null
sudo cp "$REPO_DIR/arch-shorin.db.tar.gz" "$ISO_REPO"/
# 旧脚本可能生成过 calamares-shorin.db.tar.gz，两个都留着
[[ -f "$REPO_DIR/calamares-shorin.db.tar.gz" ]] && \
  sudo cp "$REPO_DIR/calamares-shorin.db.tar.gz" "$ISO_REPO"/ || true

echo
echo "  仓库内容："
ls -lh "$ISO_REPO"/*.pkg.tar.zst 2>/dev/null | awk '{print "    " $5, $9}'

say "完成"
echo
echo "  post-install 现在会用 pacman -U 从 [build] 源装这些包，装机全程不碰 GitHub。"
echo
echo "  注意：[build] 源里同时有 calamares 和这些 AUR 包，preflight 会一起校验。"
echo "  下一步： bash build/preflight.sh ."
