#!/usr/bin/env bash
# ============================================================================
# github-access.sh —— 探测 GitHub 可达性，配置加速镜像
#
# 背景：用户反馈【访问不了 GitHub】。这会卡住两处：
#   · AUR 包的源码（dgop / xwayland-satellite / shorin-dms-niri-git）
#   · TPClash 二进制
# 但 Calamares 源码在 Codeberg、AUR 的 PKGBUILD 在 aur.archlinux.org，
# 官方包走国内源 —— 也就是【大部分环节本来就不需要 GitHub】。
#
# 这个脚本做两件事：
#   1. 探测 github.com 和几个加速镜像哪个能用
#   2. 可用时配置 git 的 insteadOf，让所有 github.com 的 clone 自动走镜像
#
# 用法：
#   bash build/github-access.sh check    # 只探测
#   bash build/github-access.sh setup    # 探测 + 配置 git 镜像
#   bash build/github-access.sh reset    # 撤销 git 镜像配置
# ============================================================================
set -uo pipefail

ACTION="${1:-check}"
CFG=/root/.gitconfig

DIRECT="https://github.com"
# 常见的 GitHub 加速镜像。不保证长期可用，所以每次都重新探测，不写死。
ACCELS=(
  "https://ghfast.top/https://github.com"
  "https://gh-proxy.com/https://github.com"
  "https://ghproxy.net/https://github.com"
  "https://mirror.ghproxy.com/https://github.com"
)

say() { printf '\033[1;36m%s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# reset
# ---------------------------------------------------------------------------
if [[ "$ACTION" == "reset" ]]; then
  sudo git config --global --unset-all url."${ACCELS[0]}".insteadOf 2>/dev/null || true
  sudo git config --global --unset-all url."https://gh-proxy.com/https://github.com/".insteadOf 2>/dev/null || true
  sudo git config --global --unset-all url."https://ghproxy.net/https://github.com/".insteadOf 2>/dev/null || true
  sudo git config --global --unset-all url."https://mirror.ghproxy.com/https://github.com/".insteadOf 2>/dev/null || true
  ok "已撤销 git 镜像配置"
  exit 0
fi

# ---------------------------------------------------------------------------
# 探测
# ---------------------------------------------------------------------------
say "探测 GitHub 可达性"

GH_DIRECT=0
if curl -sf --max-time 10 -o /dev/null "$DIRECT" 2>/dev/null; then
  ok "github.com 直连可用"
  GH_DIRECT=1
else
  warn "github.com 直连不通"
fi

# 真正下载资产用的是 objects.githubusercontent.com，直连判断可能是假阳性
if [[ $GH_DIRECT -eq 1 ]]; then
  if curl -sf --max-time 10 -o /dev/null "https://objects.githubusercontent.com" 2>/dev/null; then
    ok "objects.githubusercontent.com 可用（发布资产域名通）"
  else
    warn "objects.githubusercontent.com 不通 —— clone 可能行，下 release 会挂"
    GH_DIRECT=0
  fi
fi

BEST=""
say "探测加速镜像"
for a in "${ACCELS[@]}"; do
  host="${a#https://}"
  host="${host%%/*}"
  if curl -sf --max-time 12 -o /dev/null "$a" 2>/dev/null; then
    ok "$host 可用"
    [[ -z "$BEST" ]] && BEST="$a"
  else
    warn "$host 不可用"
  fi
done

say "结果"
if [[ $GH_DIRECT -eq 1 ]]; then
  ok "可以直接用 GitHub，不需要任何配置"
elif [[ -n "$BEST" ]]; then
  ok "直连不通，但找到可用镜像：$BEST"
else
  bad "直连和所有镜像都不通"
fi

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
if [[ "$ACTION" == "setup" ]]; then
  if [[ $GH_DIRECT -eq 1 ]]; then
    say "直连可用，无需配置镜像"
    exit 0
  fi
  [[ -n "$BEST" ]] || { bad "没有可用镜像，配置不了"; exit 1; }

  say "配置 git 走镜像：$BEST"
  # 注意是【用户级】还是【全局】：makepkg 以普通用户跑，
  # 但 CI/Docker 里可能是 root，两边都配一下省事
  for scope in --global; do
    sudo git config $scope "url.${BEST}/.insteadOf" "https://github.com/" 2>/dev/null || true
  done
  git config --global "url.${BEST}/.insteadOf" "https://github.com/" 2>/dev/null || true

  ok "已配置。之后所有 git clone https://github.com/... 会自动走镜像"
  echo
  warn "安全提示：镜像是第三方服务，你下载的源码会经过它。"
  warn "这些是公开的开源 tarball，没有凭据在里面，风险主要是"
  warn "【理论上】内容可能被篡改 —— 而 AUR 的 git 源经常是 sha256sums=SKIP，"
  warn "makepkg 不会校验。所以：只在你信任的环境下用；"
  warn "构建完可以核一下包的来源。"
fi