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

# 这里【只放编译时真正需要的包】。
#
# ⚠️ ckbcomp 【故意不在这个列表里】——
#   它是 calamares 包的运行时依赖（安装器键盘页预览键盘布局用），
#   只写在 PKGBUILD 的 depends= 里，makepkg 编译时【根本不会检查它】。
#   但它自己【不在 Arch 官方仓库】，只有 AUR 有，于是
#     pacman -S ckbcomp -> error: target not found -> 整个构建挂掉。
#   （这个坑栽过两次：workflow 的依赖列表一次，这里一次。）
#
#   ckbcomp 由 build/prebuild-aur.sh 从 AUR 编好，
#   连同 calamares 一起进 [build] 源，装机时 pacman 才去解析它。
DEPS=(base-devel cmake ninja extra-cmake-modules libglvnd
      qt6-base qt6-declarative qt6-svg qt6-tools qt6-translations
      kcoreaddons kpmcore yaml-cpp libpwquality hwinfo parted)

# 先确认这些包在仓库里【真的存在】。
# 不然 pacman -S 会只吐一句干巴巴的 "target not found"，
# 完全看不出是自己列表写错了还是仓库同步出了问题。
AVAIL="$(pacman -Slq 2>/dev/null | sort -u || true)"
if [[ -n "$AVAIL" ]]; then
  GONE=()
  for p in "${DEPS[@]}"; do
    grep -qxF -- "$p" <<<"$AVAIL" || GONE+=("$p")
  done
  if [[ ${#GONE[@]} -gt 0 ]]; then
    die "这些【构建依赖】在仓库里不存在: ${GONE[*]}
  先确认 pacman 数据库同步过（sudo pacman -Sy）。
  如果某个包其实是【运行时依赖】（典型例子: ckbcomp），
  那它就不该出现在这个列表里 —— 运行时依赖由 prebuild-aur.sh
  从 AUR 编好后放进 [build] 源，装机时 pacman 才解析。"
  fi
  say "  构建依赖全部存在于仓库 ✓"
fi

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
MAKELOG="$BUILD_DIR/makepkg.log"
set +e
( cd "$BUILD_DIR" && makepkg -f --noconfirm --clean ) 2>&1 | tee "$MAKELOG"
rc="${PIPESTATUS[0]}"
set -e

# ---- 兜底：依赖解析不过就降级重试一次 ----
# makepkg 默认会检查【运行时依赖】。ckbcomp 这种只存在于 [build] 源的包，
# 万一宿主 pacman.conf 没把本地仓库正确接进去，就会报：
#     ==> Checking runtime dependencies...
#     ==> Missing dependencies:
#       -> ckbcomp
#     ==> ERROR: Could not resolve all dependencies.
#
# 这类依赖在 ISO 构建阶段是能解析到的（那时 [build] 源已经和 calamares 一起
# 在 build-repo 目录里），所以这里允许降级到 --nodeps 再试一次，
# 而不是让整个 job 挂掉、白等 20 分钟。
if [[ $rc -ne 0 ]] && grep -q "Could not resolve all dependencies" "$MAKELOG"; then
  warn "运行时依赖在构建机上解析不了"
  warn "  → 看上面 Missing dependencies 列了哪些包"
  warn "  → 它们应该在 ISO 构建阶段由 [build] 源提供；用 --nodeps 重试"
  warn "  → 若 ISO 构建时报找不到这些包，说明 prebuild-aur.sh 漏编了它们"
  set +e
  ( cd "$BUILD_DIR" && makepkg -f --noconfirm --clean --nodeps ) 2>&1 | tee "$MAKELOG"
  rc="${PIPESTATUS[0]}"
  set -e
  [[ $rc -eq 0 ]] && warn "已用 --nodeps 编译成功（依赖将在 ISO 构建阶段解析）"
fi

[[ $rc -eq 0 ]] || { tail -40 "$MAKELOG"; die "编译失败，见上方输出"; }

# ⚠️ makepkg 会同时产出 calamares 和 calamares-debug。
#    `ls -1t`（按时间倒序）会【捡到 debug】—— 它后生成。
#    结果只把 debug 拷进 [build] 源，ISO 里根本没有 calamares 这个包，
#    mkarchiso 会直接报 "target not found: calamares"。栽过一次。
PKG=""
for cand in "$BUILD_DIR"/calamares-*.pkg.tar.zst; do
  [[ -f "$cand" ]] || continue
  case "$(basename "$cand")" in
    *-debug-*) continue ;;
  esac
  PKG="$cand"; break
done
if [[ -z "$PKG" ]]; then
  # 兜底：连 debug 都没有就随便挑一个，但要给出明确警告
  PKG="$(ls -1t "$BUILD_DIR"/calamares-*.pkg.tar.zst 2>/dev/null | head -1)"
  [[ -n "$PKG" ]] && warn "  只找到 $(basename "$PKG")，没有主包 calamares —— ISO 会装不上安装器"
fi
[[ -n "$PKG" ]] || die "没找到编译产物 .pkg.tar.zst"
echo "  主包: $(basename "$PKG")"

# ---- 3. 放进本地仓库 -------------------------------------------------------
say "安装到本地仓库 $REPO_DIR"
sudo mkdir -p "$REPO_DIR"
  # 主包和 debug 包【都】要进仓库：漏了主包 ISO 里就没有 calamares
  sudo cp "$BUILD_DIR"/calamares-*.pkg.tar.zst "$REPO_DIR"/
#  ⚠️ 库名必须叫 build.db.tar.gz，不能随便起名！
#     pacman.conf 里写的是 [build] 段，pacman 就只会去找 $repo/build.db
#     （或 build.db.tar.gz）。之前这里生成的是 arch-shorin.db.tar.gz，
#     pacman 报：
#         error: failed retrieving file 'build.db' from disk :
#         Could not open file .../build-repo/build.db
#     段名和库名对不上，就是这么个事。
sudo rm -f "$REPO_DIR/build.db.tar.gz" "$REPO_DIR/build.db"   # repo-add 不带 -f，先清旧的
sudo repo-add "$REPO_DIR/build.db.tar.gz" "$REPO_DIR"/*.pkg.tar.zst
  #  ⚠️【关键】pacman 对 file:// 源只去开 $repo/build.db（不压缩），
  #     而 repo-add 只生成 build.db.tar.gz，所以还得补一个【真正的未压缩文件】。
  #     （之前试过软链，libalpm 走 libarchive 理论上能解压，但 CI 里还是挂了。
  #       这种活儿少用花招，直接解压成真文件最稳。）
  #     这里只处理构建机仓库；ISO 仓库等第 4 节拷过去之后再补 ——
  #     因为 $ISO_REPO 到那时候才定义，set -u 下提前用会直接报错。
  if [ -f "$REPO_DIR/build.db.tar.gz" ]; then
    sudo gzip -dc "$REPO_DIR/build.db.tar.gz" > /tmp/_db.$$ && sudo mv /tmp/_db.$$ "$REPO_DIR/build.db"
  fi
  if [ -f "$REPO_DIR/build.files.tar.gz" ]; then
    sudo gzip -dc "$REPO_DIR/build.files.tar.gz" > /tmp/_fl.$$ && sudo mv /tmp/_fl.$$ "$REPO_DIR/build.files"
  fi
  rm -f /tmp/_db.$$ /tmp/_fl.$$
#  同样要补 .db / .files 软链：pacman 对 file:// 源只找 <repo>/build.db（见 prebuild-aur.sh 里的说明）

# ---- 4. 放置到 ISO 内可见的位置 --------------------------------------------
# 两种方式，二选一（见 README）：
#   A. 放进 airootfs 内  -> ISO 构建时 [build] 源指向 /etc/pacman.d/build-repo
#   B. 只在构建机宿主上配 [build] 源 -> ISO 内的这个目录用不到
say "放入 ISO 内的本地仓库目录"
ISO_REPO="$PROFILE_DIR/airootfs/etc/pacman.d/build-repo"
sudo mkdir -p "$ISO_REPO"
sudo cp "$PROFILE_DIR"/build/repo/calamares-*.pkg.tar.zst "$ISO_REPO"/ 2>/dev/null || true
#  ISO 里的仓库也要用 build.db.tar.gz，跟 [build] 段对得上
if compgen -G "$PROFILE_DIR"/build/repo/build.db.tar.gz > /dev/null; then
    sudo cp "$PROFILE_DIR"/build/repo/build.db.tar.gz "$ISO_REPO"/
    [[ -f "$PROFILE_DIR"/build/repo/build.files.tar.gz ]] && sudo cp "$PROFILE_DIR"/build/repo/build.files.tar.gz "$ISO_REPO"/ || true
    #  ISO 仓库才是 pacman 真正读的那个，必须也有未压缩的 build.db
    sudo gzip -dc "$ISO_REPO/build.db.tar.gz" > /tmp/_db.$$ && sudo mv /tmp/_db.$$ "$ISO_REPO/build.db"
    if [ -f "$ISO_REPO/build.files.tar.gz" ]; then
      sudo gzip -dc "$ISO_REPO/build.files.tar.gz" > /tmp/_fl.$$ && sudo mv /tmp/_fl.$$ "$ISO_REPO/build.files"
    fi
    rm -f /tmp/_db.$$ /tmp/_fl.$$
  say "  已复制包与数据库到 $ISO_REPO"
else
  warn "  没找到 build.db.tar.gz，请在 $PROFILE_DIR/build/repo 下跑一次 repo-add"
fi

# ---- 5. 核对 ----------------------------------------------------------------
say "验证本地包可见"
if repo-query --repo build 2>/dev/null | grep -q calamares; then
  echo "  ok  本地仓库里有 calamares"
else
  echo "  注意：当前 pacman.conf 里还没有启用 [build]（需要在构建机上加 [build] 段）"
  echo "       验证方法：临时在 /etc/pacman.conf 加一段 [build] + Server = file://… 再跑 preflight"
fi

say "完成"
echo
echo "下一步："
echo "  1) 在【构建机】的 /etc/pacman.conf 里启用本地仓库，否则 preflight 查不到 calamares："
#        注意：是 Server = file://... 【不是】Include = ...
#        pacman.conf 里 Include 的意思是「把目标当配置片段读」，
#        拿它去指向一个二进制 db 文件，pacman 会吐一屏乱码，
#        然后整个 /etc/pacman.conf 解析失败。（栽过）
cat <<TIPS
       sudo tee -a /etc/pacman.conf >/dev/null <<'XEOF'

[build]
SigLevel = Optional TrustAll
Server = file://$REPO_DIR
XEOF
       sudo pacman -Sy
TIPS
echo "  2) bash build/preflight.sh .    # 确认 calamares 能被解析"
echo "  3) bash build/build.sh          # 构建 ISO"
echo
echo "  产物：$REPO_DIR/calamares-*.pkg.tar.zst"
