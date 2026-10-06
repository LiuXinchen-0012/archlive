#!/usr/bin/env bash
# ============================================================================
# use-mirror.sh —— 切换 profile 用的镜像源
#
# 为什么需要：
#   profile 默认用国内五源（清华/中科大/阿里/华为/北大），在国内构建最快。
#   但如果在 GitHub Actions（美国 runner）上构建，走国内源反而慢 —— 每次 pacman
#   -Sy 要跨境往返十几个包。CI 里应该用官方/就近的西方镜像。
#
# 用法：
#   bash build/use-mirror.sh cn      # 国内五源（默认）
#   bash build/use-mirror.sh official # 官方主源 + 少量镜像
#   bash build/use-mirror.sh auto     # 探测延迟自动选
# ============================================================================
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ML="$PROFILE_DIR/airootfs/etc/pacman.d/mirrorlist"
MLCN="$PROFILE_DIR/airootfs/etc/pacman.d/mirrorlist.archlinuxcn"
MODE="${1:-cn}"

# —— 候选列表：延迟探测用 ——
CN_MIRRORS=(
  "https://mirrors.tuna.tsinghua.edu.cn/archlinux"
  "https://mirrors.ustc.edu.cn/archlinux"
  "https://mirrors.aliyun.com/archlinux"
  "https://mirrors.huaweicloud.com/archlinux"
  "https://mirrors.pku.edu.cn/archlinux"
)
CN_CN_MIRRORS=(
  "https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn"
  "https://mirrors.ustc.edu.cn/archlinuxcn"
  "https://mirrors.aliyun.com/archlinuxcn"
  "https://mirrors.huaweicloud.com/archlinuxcn"
)

# ⚠️ 这几个是 2026-10-06 实测过的。
#    geo.mirror.pkgbuild.com 已经被 Arch 官方下线（404），
#    ftp.jaist.ac.jp 也没了，mirror.leaseweb.com 常年 503 —— 三个都别再用。
#    留着死源的后果：pacman 会先卡在那儿超时，才 fallback 到能用的源，
#    CI 里表现为"莫名其妙的慢"，ISO 里表现为首次同步卡几十秒。
OFFICIAL_MIRRORS=(
  "https://mirror.rackspace.com/archlinux"
  "https://mirror.arizona.edu/archlinux"
  "https://mirrors.mit.edu/archlinux"
  "https://mirror.math.princeton.edu/pub/archlinux"
  "https://mirror.nju.edu.cn/archlinux"
)
OFFICIAL_CN_MIRRORS=(
  "https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn"
  "https://mirror.iscas.ac.cn/archlinuxcn"
  "https://mirrors.bfsu.edu.cn/archlinuxcn"
)

pick_cn() {
  for m in "${CN_MIRRORS[@]}"; do
    echo "Server = $m/\$repo/os/\$arch"
  done
}
pick_cn_cn() {
  for m in "${CN_CN_MIRRORS[@]}"; do
    echo "Server = \$m/\$arch" | sed "s|\\\$m|$m|"
  done
}
pick_official() {
  for m in "${OFFICIAL_MIRRORS[@]}"; do
    echo "Server = $m/\$repo/os/\$arch"
  done
}
pick_official_cn() {
  for m in "${OFFICIAL_CN_MIRRORS[@]}"; do
    echo "Server = $m/\$arch" | sed "s|\\\$m|$m|"
  done
}

case "$MODE" in
  cn)
    header="## 国内镜像源 —— 2026-10-05 实测全部可达"
    { echo "$header"; echo
      pick_cn; } > "$ML"
    { echo "## archlinuxcn 专用源（路径结构不同）"; echo
      pick_cn_cn; } > "$MLCN"
    ;;
  official)
    header="## 官方/西方镜像源 —— 用于 CI 构建机（美国等）"
    { echo "$header"; echo
      pick_official; } > "$ML"
    { echo "## archlinuxcn"; echo
      pick_official_cn; } > "$MLCN"
    ;;
  auto)
    # 拿国内源打个包，看往返延迟；超过 1.5 秒就判定"不在国内"
    t0=$(date +%s%N)
    curl -sf -o /dev/null --max-time 10 "https://mirrors.tuna.tsinghua.edu.cn/archlinux/core/os/x86_64/core.db" 2>/dev/null || true
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))
    if [[ $ms -gt 1500 ]]; then
      echo "国内源延迟 ${ms}ms，判定为境外网络 -> 用官方源" >&2
      MODE=official
      "$0" official
      exit 0
    fi
    echo "国内源延迟 ${ms}ms，判定为国内网络 -> 保留国内源" >&2
    exit 0
    ;;
  *)
    echo "用法: $0 {cn|official|auto}" >&2; exit 2 ;;
esac

echo "已切换到 $MODE 模式"
echo "--- $ML"; head -5 "$ML"
echo "--- $MLCN"; head -5 "$MLCN"
