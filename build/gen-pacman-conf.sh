#!/usr/bin/env bash
# ============================================================================
# gen-pacman-conf.sh —— 生成【profile 根目录】的 pacman.conf
#
# 为什么需要这个文件：
#   archiso 的 profile 根目录必须有一份 pacman.conf，用来把 packages.x86_64
#   里的包装进 work/x86_64/airootfs。它和 airootfs/etc/pacman.conf 是两回事：
#     - profile/pacman.conf     构建期用，给 mkarchiso
#     - airootfs/etc/pacman.conf 运行期用，装出来的系统里
#
# 少了前者，mkarchiso 会报莫名其妙的
#     realpath: '': No such file or directory
# ——因为它拿着一个空路径去 realpath 了。
#
# 关键点：[build] 源必须指向本机的绝对路径，因为 packages.x86_64 里有
# calamares 等只有本地仓库才有的包。
# ============================================================================
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$PROFILE_DIR/pacman.conf"
BUILD_REPO="$PROFILE_DIR/airootfs/etc/pacman.d/build-repo"

[[ -d "$BUILD_REPO" ]] || { echo "ERROR: 找不到本地仓库 $BUILD_REPO" >&2; exit 1; }

cat > "$OUT" <<CONF
# ============================================================================
# 这个文件由 build/gen-pacman-conf.sh 生成，【不要手改】——
# 里面塞了本机的绝对路径，重新生成才会跟着变。
#
# 它只在构建 ISO 时被 mkarchiso 使用；
# 装出来的系统用的是 airootfs/etc/pacman.conf（另一个文件）。
# ============================================================================
[options]
HoldPkg          = pacman glibc
Architecture     = auto
SigLevel         = Required DatabaseOptional
LocalFileSigLevel = Optional
CheckSpace

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[archlinuxcn]
Include = /etc/pacman.d/mirrorlist.archlinuxcn

# 自编译的 Calamares 和预编译的 AUR 包都在这儿。
# SigLevel = Optional：这些包是我们自己编的，没签名。
[build]
SigLevel = Optional TrustAll
Server  = file://$BUILD_REPO
CONF

echo "已生成 $OUT"
echo "  [build] 源 -> $BUILD_REPO"
ls -1 "$BUILD_REPO"/*.pkg.tar.zst 2>/dev/null | sed 's|.*/|    |' || echo "    (仓库里还没有包)"
