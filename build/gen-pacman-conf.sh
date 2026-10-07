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

# ⚠️ [archlinuxcn] 这段是【有就写、没有就跳过】的。
#    之前写死成 Include = /etc/pacman.d/mirrorlist.archlinuxcn，
#    但 CI 的「选镜像源」步骤只建了 /etc/pacman.d/mirrorlist（官方源），
#    那个文件根本不存在。pacman 读不到就直接中断整个配置文件解析：
#        error: config file /etc/pacman.d/mirrorlist.archlinuxcn could not be read
#        error: no usable package repositories configured.
#    ——注意 [core]/[extra] 本来是好的，被这一行连坐了。
#    本机自己构建时想用国内源，手动放一个 mirrorlist.archlinuxcn 进去就会被自动识别。
{
  cat <<'CONF'
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
CONF

  if [[ -f /etc/pacman.d/mirrorlist.archlinuxcn ]]; then
    cat <<'CONF'

[archlinuxcn]
Include = /etc/pacman.d/mirrorlist.archlinuxcn
CONF
    echo "  （检测到 mirrorlist.archlinuxcn，已加入国内源）"
  else
    echo "  （没有 mirrorlist.archlinuxcn，跳过国内源）"
  fi

  # 自编译的 Calamares 和预编译的 AUR 包都在这儿。
  # SigLevel = Optional TrustAll：这些包是我们自己编的，没签名。
  # 注意用 Server = file://，不是 Include —— Include 是「当配置读」的。
  cat <<CONF

[build]
SigLevel = Optional TrustAll
Server = file://$BUILD_REPO
CONF
} > "$OUT"

echo "已生成 $OUT"
echo "  [build] 源 -> $BUILD_REPO"
ls -1 "$BUILD_REPO"/*.pkg.tar.zst 2>/dev/null | sed 's|.*/|    |' || echo "    (仓库里还没有包)"
