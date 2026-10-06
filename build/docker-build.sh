#!/usr/bin/env bash
# ============================================================================
# docker-build.sh —— 在 Docker 容器里构建 ISO（宿主机不需要是 Arch）
#
# 原理：拉官方 archlinux:base 容器当构建环境，容器里就是 Arch，
#       再加 --privileged 让它能 mount / 做 loop 设备操作（mkarchiso 需要）。
#
# 宿主机要求：装了 Docker 或 Docker Desktop。Windows / macOS / Linux 均可。
#
# 用法：
#   bash build/docker-build.sh                    # skeleton
#   SHORIN_MODE=full bash build/docker-build.sh   # 连 Shorin dotfiles
#   BURN=/dev/sdX bash build/docker-build.sh      # 导出 ISO 后可写盘（宿主机执行）
# ============================================================================
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_DIR="$(cd "$PROFILE_DIR" && pwd)"

IMAGE="${IMAGE:-archlinux:shorin-builder}"
SHORIN_MODE="${SHORIN_MODE:-skeleton}"
PREBUILD_AUR="${PREBUILD_AUR:-1}"
MEM="${MEM:-8g}"
CPUS="${CPUS:-4}"
DISK_BIN="$PROFILE_DIR/build/docker-out"

step()  { printf '\n\033[1;36m━━━ %s\033[0m\n' "$*"; }
info()  { printf '  \033[90m·\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

command -v docker > /dev/null || die "没找到 docker。
  Windows/macOS: 装 Docker Desktop  https://docs.docker.com/desktop/
  Linux: sudo apt install docker.io   或  sudo pacman -S docker"

docker info > /dev/null 2>&1 || die "docker 守护进程没跑起来，或者当前用户没权限。
  Linux 上试试: sudo usermod -aG docker \$USER   然后重新登录"

step "环境"
info "profile : $PROFILE_DIR"
info "模式    : $SHORIN_MODE"
info "资源    : $CPUS 核 / $MEM"
info "镜像    : $IMAGE"

# ── Docker Hub 可达性（国内几乎都被墙，必须先解决）────────────────────────
step "探测 Docker Hub"
DOCKERHUB_OK=0
if curl -sf --max-time 10 -o /dev/null https://registry-1.docker.io/v2/ 2>/dev/null; then
  ok "registry-1.docker.io 直连可用"
  DOCKERHUB_OK=1
else
  warn "registry-1.docker.io 直连不通（国内常态）"
  # 401 是 /v2/ 未认证时的【正常】应答，说明镜像站在工作
  for m in docker.m.daocloud.io hub.rat.dev docker.1ms.run; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$m/v2/" 2>/dev/null)"
    if [[ "$code" =~ ^(200|401|403)$ ]]; then
      ok "镜像源可用: $m (HTTP $code)"
    else
      warn "镜像源不可用: $m (HTTP ${code:-000})"
    fi
  done
  cat <<'EOF2'

  在 Docker Desktop 里配置镜像源（Settings → Docker Engine，粘贴后 Apply & Restart）：

    {
      "registry-mirrors": [
        "https://docker.m.daocloud.io",
        "https://hub.rat.dev"
      ]
    }

  配完再跑本脚本。不配的话 docker pull 会一直卡住。
EOF2
fi

# ── 关键站点探测：决定这个 ISO 能做到什么程度 ────────────────────────────
step "探测关键站点"
CB_OK=0; AUR_OK=0; GH_OK=0
curl -sf --max-time 12 -o /dev/null https://codeberg.org 2>/dev/null && CB_OK=1
curl -sf --max-time 12 -o /dev/null https://aur.archlinux.org 2>/dev/null && AUR_OK=1
curl -sf --max-time 12 -o /dev/null https://github.com 2>/dev/null && GH_OK=1
[[ $CB_OK -eq 1 ]] && ok "codeberg.org 可达（Calamares 能编）" || bad "codeberg.org 不通 —— Calamares 编不出来，ISO 里就没有安装器"
[[ $AUR_OK -eq 1 ]] && ok "aur.archlinux.org 可达（能拉 PKGBUILD）" || warn "aur.archlinux.org 不通 —— AUR 包编不了"
if [[ $GH_OK -eq 1 ]]; then
  ok "github.com 可达（AUR 包源码 + TPClash 能下）"
else
  warn "github.com 不通 —— 这会影响："
  warn "    · dgop / xwayland-satellite / shorin-dms-niri-git 的源码"
  warn "    · TPClash 二进制"
  warn "  应对：先跑 bash build/github-access.sh setup 试试加速镜像"
  warn "  实在不行就 SHORIN_MODE=skeleton —— 那个模式【完全不需要 GitHub】"
fi

mkdir -p "$DISK_BIN"

# ---------------------------------------------------------------------------
# 准备容器镜像：装齐构建依赖
# ---------------------------------------------------------------------------
step "准备构建容器（首次约 5~10 分钟）"

docker run --rm --privileged -i \
  -v "$PROFILE_DIR:/work/archlive" \
  -v "$DISK_BIN:/work/out" \
  "$IMAGE" bash -euxo pipefail -c '
    pacman-key --init
    pacman-key --populate archlinux
    pacman -Syu --noconfirm --needed \
      git curl wget sudo rsync tar \
      base-devel cmake ninja extra-cmake-modules libglvnd \
      qt6-base qt6-declarative qt6-svg qt6-tools qt6-translations \
      kcoreaddons kpmcore yaml-cpp libpwquality hwinfo parted ckbcomp \
      archiso squashfs-tools libisoburn dosfstools mtools

    # 缓存镜像层，下次不用重装
    echo "=== 基础依赖就绪 ==="
  ' || die "容器准备失败"

# 提交成新镜像，省得每次重装依赖
if docker run --rm "$IMAGE" bash -c 'command -v mkarchiso' > /dev/null 2>&1; then
  info "依赖已装好，直接进入构建"
else
  docker build -t "$IMAGE" - <<'DOCKERFILE' || true
FROM archlinux:base
RUN pacman-key --init && pacman-key --populate archlinux && \
    pacman -Syu --noconfirm --needed \
      git curl wget sudo rsync tar base-devel cmake ninja \
      extra-cmake-modules libglvnd qt6-base qt6-declarative qt6-svg \
      qt6-tools qt6-translations kcoreaddons kpmcore yaml-cpp libpwquality \
      hwinfo parted ckbcomp archiso squashfs-tools libisoburn dosfstools mtools && \
    pacman -Scc --noconfirm
DOCKERFILE
fi

# ---------------------------------------------------------------------------
# 容器内：编译 + 预编译 + 自检 + 构建
# ---------------------------------------------------------------------------
step "容器内构建（30~90 分钟）"

docker run --rm --privileged -it \
  -v "$PROFILE_DIR:/work/archlive" \
  -v "$DISK_BIN:/work/out" \
  -e "SHORIN_MODE=$SHORIN_MODE" \
  -e "PREBUILD_AUR=$PREBUILD_AUR" \
  -e "MAKEFLAGS=-j$((CPUS > 2 ? CPUS - 1 : 1))" \
  "$IMAGE" bash -euxo pipefail -c '
    set -e
    cd /work/archlive

    # makepkg 不能以 root 跑
    id builder >/dev/null 2>&1 || { useradd -m -G wheel builder; echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder; }
    chown -R builder:builder /work

    # 容器在宿主所在网络 —— 探测后自动选镜像源
    bash build/use-mirror.sh auto

    # 1) 编译 Calamares
    if ! ls archlive/build-repo 2>/dev/null; then :; fi
    if ls airootfs/etc/pacman.d/build-repo/calamares-*.pkg.tar.zst >/dev/null 2>&1; then
      echo ">>> Calamares 已存在，跳过"
    else
      sudo -u builder bash build/build-calamares.sh
    fi

    # 1b) 预置 TPClash —— GitHub 不通就跳过，不阻断
    if bash build/prefetch-binaries.sh; then
      echo ">>> TPClash 已预置"
    else
      echo "::warning::TPClash 没抓到 —— 装完系统后在桌面「配置代理」里现配即可"
    fi

    # 2) 预编译 AUR —— GitHub 不通就【自动降级为 skeleton】，不阻断构建
    GH_REACH=0
    curl -sf --max-time 12 -o /dev/null https://github.com 2>/dev/null && GH_REACH=1
    if [ "$SHORIN_MODE" = full ] && [ "$PREBUILD_AUR" = 1 ]; then
      if [ "$GH_REACH" = 1 ]; then
        sudo -u builder bash build/prebuild-aur.sh \
          || echo "::warning::AUR 预编译失败，将退回 skeleton"
      else
        echo "::error::GitHub 不通，无法编译 Shorin DMS Niri 的 AUR 依赖"
        echo "::error::自动降级为 skeleton 模式（ISO 仍然可用，只是没有 Shorin 的 dotfiles）"
        echo skeleton > airootfs/etc/shorin-build-mode
      fi
    fi
    echo ">>> 最终模式: $(cat airootfs/etc/shorin-build-mode 2>/dev/null || echo 未设置)"

    # 3) 挂本地仓库 + 自检
    db=$(ls -1 airootfs/etc/pacman.d/build-repo/*.db.tar.gz 2>/dev/null | head -1)
    if [ -n "$db" ]; then
      real=$(realpath "$db")
      echo "Include = $real" >> /etc/pacman.conf
      pacman -Sy --noconfirm || true
    fi
    bash build/preflight.sh . || echo "::warning::preflight 有问题，继续"

    # 4) 写模式 + 构建（如果上面已经降级成 skeleton，就别覆盖回去）
    [ -s airootfs/etc/shorin-build-mode ] || echo "$SHORIN_MODE" > airootfs/etc/shorin-build-mode
    chmod +x airootfs/usr/local/bin/*.sh
    rm -rf /work/w; mkdir -p /work/w /work/out
    mkarchiso -v -w /work/w -o /work/out /work/archlive

    iso=$(ls -1 /work/out/archlinux-shorin-*.iso | head -1)
    echo "=== 构建完成 ==="
    ls -lh "$iso"
    sha256sum "$iso" | tee /work/out/sha256sum.txt
  ' || die "容器内构建失败（上面的日志里有具体原因）"

# ---------------------------------------------------------------------------
# 产物确认
# ---------------------------------------------------------------------------
step "ISO 已导出到宿主机"
ls -lh "$DISK_BIN"/*.iso 2>/dev/null || die "没找到 ISO，看上面的日志"

ISO_PATH="$(ls -1 "$DISK_BIN"/archlinux-shorin-*.iso | head -1)"
cat "$DISK_BIN/sha256sum.txt" 2>/dev/null || true

cat <<EOF

在虚拟机里测（BIOS / UEFI 都要测）：

  # UEFI
  qemu-system-x86_64 -enable-kvm -m 8192 -smp 4 \\
    -bios ovmf \\
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.fd \\
    -cdrom $(basename "$ISO_PATH") -boot d

  # BIOS
  qemu-system-x86_64 -enable-kvm -m 8192 -smp 4 \\
    -cdrom $(basename "$ISO_PATH") -boot d

EOF
