#!/usr/bin/env bash
# ============================================================================
# build-calamares.sh —— 编译打过补丁的 Calamares，放进本地 [build] 仓库
#
# 为什么需要这一步：
#   Calamares 不在 Arch 官方仓库了，只能自己编。而 archiso 的 mkarchiso
#   是用【宿主的 pacman 数据库】取包的，不能直接列本地文件。所以要把编好的
#   .pkg.tar.zst 放进一个本地仓库目录，再在 pacman.conf 里声明 [build]，
#   packages.x86_64 里才能写 calamares。
#
# 运行方式：以【普通用户】运行（makepkg 拒绝 root），需要能 sudo
#   bash build/build-calamares.sh
# ============================================================================
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROFILE_DIR/build/calamares-build}"
REPO_DIR="${REPO_DIR:-$PROFILE_DIR/build/repo}"

warn() { printf '\033[33mWARN\033[0m %s\n' "$*"; }
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "请用普通用户运行（makepkg 不允许 root）。需要 sudo 权限装依赖。"
command -v makepkg > /dev/null || die "没装 base-devel：sudo pacman -S --needed base-devel cmake ninja"

# ---- 1. 依赖 ---------------------------------------------------------------
say "检查/安装构建依赖"
DEPS=(base-devel cmake ninja extra-cmake-modules libglvnd
      qt6-base qt6-declarative qt6-svg qt6-tools qt6-translations
      kcoreaddons kpmcore yaml-cpp libpwquality hwinfo parted ckbcomp)
MISSING=()
for p in "${DEPS[@]}"; do pacman -Qq "$p" &>/dev/null || MISSING+=("$p"); done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  say "安装: ${MISSING[*]}"
  sudo pacman -S --needed --noconfirm "${MISSING[@]}"
fi

# ---- 2. 编译 ---------------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cp "$PROFILE_DIR/build/PKGBUILD.calamares-shorin" "$BUILD_DIR/PKGBUILD"

say "makepkg（10~25 分钟，取决于 CPU）"
( cd "$BUILD_DIR" && makepkg -f --noconfirm --clean ) || die "编译失败，见上方输出"

PKG="$(ls -1t "$BUILD_DIR"/calamares-*.pkg.tar.zst 2>/dev/null | head -1)"
[[ -n "$PKG" ]] || die "没找到编译产物 .pkg.tar.zst"

# ---- 3. 放进本地仓库 -------------------------------------------------------
say "安装到本地仓库 $REPO_DIR"
sudo mkdir -p "$REPO_DIR"
sudo cp "$PKG" "$REPO_DIR"/
sudo repo-add "$REPO_DIR/calamares-shorin.db.tar.gz" "$REPO_DIR"/calamares-*.pkg.tar.zst

# ---- 4. 放置到 ISO 内可见的位置 --------------------------------------------
# 两种方式，二选一（见 README）：
#   A. 放进 airootfs 内  -> ISO 构建时 [build] 源指向 /etc/pacman.d/build-repo
#   B. 只在构建机宿主上配 [build] 源 -> ISO 内的这个目录用不到
say "放入 ISO 内的本地仓库目录"
ISO_REPO="$PROFILE_DIR/airootfs/etc/pacman.d/build-repo"
sudo mkdir -p "$ISO_REPO"
sudo cp "$PROFILE_DIR"/build/repo/calamares-*.pkg.tar.zst "$ISO_REPO"/ 2>/dev/null || true
if compgen -G "$PROFILE_DIR"/build/repo/calamares-shorin.db.tar.gz > /dev/null; then
  sudo cp "$PROFILE_DIR"/build/repo/calamares-shorin.db.tar.gz "$ISO_REPO"/
  say "  已复制包与数据库到 $ISO_REPO"
else
  warn "  没找到 .db.tar.gz，请在 $PROFILE_DIR/build/repo 下跑一次 repo-add"
fi

# ---- 5. 核对 ----------------------------------------------------------------
say "验证本地包可见"
if repo-query --repo build 2>/dev/null | grep -q calamares; then
  echo "  ok  本地仓库里有 calamares"
else
  echo "  注意：当前 pacman.conf 里还没有启用 [build]（需要在构建机上加 Include）"
  echo "       验证方法：临时加一行到 /etc/pacman.conf 的 Include 列表再跑 preflight"
fi

say "完成"
echo
echo "下一步："
echo "  1) 在【构建机】的 /etc/pacman.conf 里启用本地仓库，否则 preflight 查不到 calamares："
echo "       echo 'Include = $REPO_DIR/calamares-shorin.db.tar.gz' | sudo tee -a /etc/pacman.conf"
echo "       sudo pacman -Sy"
echo "  2) bash build/preflight.sh .    # 确认 calamares 能被解析"
echo "  3) bash build/build.sh          # 构建 ISO"
echo
echo "  产物：$REPO_DIR/calamares-*.pkg.tar.zst"
