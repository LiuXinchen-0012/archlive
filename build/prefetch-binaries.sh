#!/usr/bin/env bash
# ============================================================================
# prefetch-binaries.sh —— 把"装机时才要下载"的小二进制提前塞进 ISO
#
# 背景：让整个装机流程【完全不依赖 GitHub】。
#   装机时需要联网下载的东西本来有 3 类：
#     ① 官方包      -> 走国内五源，本来就不需要代理
#     ② AUR 包      -> prebuild-aur.sh 已提前编译好
#     ③ TPClash 二进制 -> 原本要在装机时从 GitHub Releases 现下
#   ③ 是最后的缺口。把二进制也在构建时抓好，装机就彻底零 GitHub 依赖。
#
# 抓不到不致命（会让装机时退回"现下"那条路），所以这里只警告不失败。
#
# 用法：普通用户即可，不需要 root
#   bash build/prefetch-binaries.sh
# ============================================================================
set -uo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINDIR="$PROFILE_DIR/airootfs/usr/local/lib/shorin"
TPCLASH_VERSION="${TPCLASH_VERSION:-v0.3.10}"

MIRRORS=(
  "https://github.com/mritd/tpclash/releases/download"
  "https://ghfast.top/https://github.com/mritd/tpclash/releases/download"
  "https://gh-proxy.com/https://github.com/mritd/tpclash/releases/download"
)
ASSETS=("tpclash-premium-linux-amd64-v3" "tpclash-premium-linux-amd64")

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }

mkdir -p "$BINDIR"

# ── 1. GitHub 的【下载域名】通吗 ──
# 注意：不要用 `curl github.com` 判断可达性 —— 实测那是假阳性：
# 首页可能返回一个空壳页面（HTTP 200），但 release 资产实际托管在
# objects.githubusercontent.com，那才是国内被墙的那个。
# 这里直接探真正要用的下载域名。
say "检查 GitHub 下载域名可达性"
GH_DOWNLOAD_OK=1
for h in "https://github.com" "https://objects.githubusercontent.com"; do
  if curl -sf --max-time 12 -o /dev/null "$h"; then
    ok "$h"
  else
    warn "$h  不通"
    [[ "$h" == *objects.githubusercontent.com ]] && GH_DOWNLOAD_OK=0
  fi
done
if [[ $GH_DOWNLOAD_OK -eq 0 ]]; then
  warn "GitHub 的下载域名不通 —— 这一步必须在【能访问 GitHub 的地方】跑"
  warn "（GitHub Actions runner 可以；国内机器需要先配代理）"
  warn "抓不到的后果：装机时现下 TPClash，装机就还需要 GitHub。"
  warn ""
  warn "不过这只影响【要不要预置 TPClash】，不影响其余部分 ——"
  warn "Calamares 和 AUR 包都还有各自的预编译流程兜底。"
fi

# ── 2. 抓 TPClash ──
say "抓取 TPClash $TPCLASH_VERSION"
GOT=0
for base in "${MIRRORS[@]}"; do
  for asset in "${ASSETS[@]}"; do
    url="$base/$TPCLASH_VERSION/$asset"
    printf '  试 %s\n' "$url"
    if curl -sfL --max-time 180 "$url" -o "$BINDIR/tpclash.bin"; then
      chmod 0755 "$BINDIR/tpclash.bin"
      if [[ ! -s "$BINDIR/tpclash.bin" ]]; then
        rm -f "$BINDIR/tpclash.bin"; continue
      fi
      GOT=1; break 2
    fi
  done
done

if [[ $GOT -eq 1 ]]; then
  SZ=$(du -h "$BINDIR/tpclash.bin" | cut -f1)
  ok "已保存 $BINDIR/tpclash.bin（$SZ）"
  # 记个 sha，装机时可以校验完整性
  ( cd "$BINDIR" && sha256sum tpclash.bin > tpclash.bin.sha256 )
  ok "校验和: $(cut -d' ' -f1 "$BINDIR/tpclash.bin.sha256")"
  # 顺手验证它真的是 tpclash 而不是错误页
  if ! "$BINDIR/tpclash.bin" --help >/dev/null 2>&1; then
    warn "二进制跑不起来（可能下载到了错误页），装机时会退回现下"
    rm -f "$BINDIR/tpclash.bin" "$BINDIR/tpclash.bin.sha256"
  else
    ok "二进制自检通过"
  fi
else
  warn "所有镜像都没抓到。装机时会退回现下（需要 GitHub）。"
fi

# ── 3. 汇报 ──
say "结果"
echo "  装机时需要的 GitHub 下载："
echo "    AUR 包        → 已预编译（prebuild-aur.sh）"
echo "    Calamares     → 已预编译（build-calamares.sh）"
if [[ -f "$BINDIR/tpclash.bin" ]]; then
  echo "    TPClash       → ✅ 已内置，装机零 GitHub 依赖"
else
  echo "    TPClash       → ✗ 未内置，装机时会现下（需要 GitHub）"
fi
echo
echo "  提示：代理本身仍然可以在装好后单独配置"
echo "       （桌面上的「配置代理」图标，或目标系统里的同名图标）"
echo "       但它不再是【装机的前提条件】了。"
