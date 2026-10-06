#!/usr/bin/env bash
# ============================================================================
# net-precheck.sh —— 装机【之前】的网络体检
#
# 为什么要有这个：
#   用户反馈"没代理 100% 装不上"。如果等到 post-install 阶段才发现拉不动包，
#   那时候分区已经做完、文件已经复制、用户已经等了半小时 —— 失败得非常贵。
#   所以要在【双击安装器的那一刻】就知道网络到底行不行，并给出可执行的对策。
#
# 它区分三种情况（这三种的应对完全不同，不能笼统说"网络有问题"）：
#   A. 官方源通 + GitHub 不通   -> 官方包能装，AUR/GitHub 那步需要代理
#   B. 官方源也不通              -> 镜像/ DNS / 完全没网，必须先解决网络
#   C. 全通                      -> 可以直接装
#   D. 已有透明代理              -> 一切正常
# ============================================================================
set -uo pipefail

REPORT=/tmp/shorin-netcheck.txt
: > "$REPORT"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }

CN_MIRRORS=(
  "https://mirrors.tuna.tsinghua.edu.cn/archlinux"
  "https://mirrors.ustc.edu.cn/archlinux"
  "https://mirrors.aliyun.com/archlinux"
)
GITHUB_HOSTS=(
  "https://github.com"
  "https://aur.archlinux.org"
  "https://objects.githubusercontent.com"
)

CN_OK=0
GH_OK=0
AUR_OK=0
GH_REACHABLE=0
declare -a CN_FAILED=() GH_FAILED=()

probe() {
  # $1=URL  $2=超时秒数
  curl -sf -o /dev/null --max-time "${2:-10}" -r 0-512 "$1" 2>/dev/null
}

log "===== Shorin 网络体检 $(date) ====="
log ""

# ── 1. DNS ──
log "[1/4] DNS"
if getent hosts mirrors.tuna.tsinghua.edu.cn > /dev/null 2>&1; then
  log "  ✓ DNS 解析正常"
  DNS_OK=1
else
  log "  ✗ DNS 解析失败 —— 检查 /etc/resolv.conf 或网络连接"
  DNS_OK=0
fi

# ── 2. 已有透明代理？ ──
log ""
log "[2/4] 检测已运行的透明代理"
PROXY_HINT=""
if [[ -f /tmp/shorin-proxy-ok ]]; then
  PROXY_HINT="setup-proxy-gui.sh 配置成功"
fi
if [[ -z "$PROXY_HINT" ]] && systemctl is-active --quiet tpclash.service 2>/dev/null; then
  PROXY_HINT="tpclash.service"
fi
if [[ -z "$PROXY_HINT" ]] && [[ -d /data/clash ]] && pgrep -f "clash" > /dev/null 2>&1; then
  PROXY_HINT="clash 进程"
fi
if probe "https://www.google.com" 8; then
  log "  ✓ 能直连 google —— 透明代理已经在工作"
  [[ -n "$PROXY_HINT" ]] && log "    （检测到：$PROXY_HINT）"
  ALREADY_PROXIED=1
else
  log "  · 不能直连 google —— 当前没有生效的透明代理"
  ALREADY_PROXIED=0
fi

# ── 3. 官方源（国内五源）通不通 ──
log ""
log "[3/4] 国内镜像源"
for m in "${CN_MIRRORS[@]}"; do
  if probe "$m/core/os/x86_64/core.db" 12; then
    log "  ✓ $m"
    CN_OK=$((CN_OK + 1))
  else
    log "  ✗ $m"
    CN_FAILED+=("$m")
  fi
done
log "  --> $((CN_OK + 0))/${#CN_MIRRORS[@]} 个可用"

# ── 4. GitHub / AUR ──
log ""
log "[4/4] GitHub / AUR（装 Shorin DMS Niri 和自编译包需要）"
for h in "${GITHUB_HOSTS[@]}"; do
  case "$h" in
    *aur.archlinux.org) key=AUR_WEB ;;
    *github.com)        key=GH_WEB ;;      # objects.githubusercontent.com 也是
    *)                  key=GH_WEB ;;
  esac
  if probe "$h" 12; then
    log "  ✓ $h"
    case "$key" in
      AUR_WEB) AUR_OK=1 ;;
      GH_WEB)  GH_OK=1 ;;
    esac
  else
    log "  ✗ $h"
    case "$key" in
      AUR_WEB) AUR_OK=0 ;;
      GH_WEB)  GH_OK=0 ;;
    esac
  fi
done
log "  --> github.com 源码站: $([[ $GH_OK -eq 1 ]] && echo 通 || echo 不通)"
log "  --> aur.archlinux.org: $([[ ${AUR_OK:-0} -eq 1 ]] && echo 通 || echo 不通)"

# 关键判据：github.com 能不能访问。
# AUR 站通了只能【读到 PKGBUILD】，源码 tarball 仍然从 GitHub / objects.githubusercontent.com
# 下载 —— 所以只看 aur 通不通是不够的（这曾经是个判据 bug，实跑才发现）。
GH_REACHABLE=$GH_OK

# ── 5. 结论 ──
log ""
log "===== 结论 ====="

if [[ $ALREADY_PROXIED -eq 1 ]]; then
  VERDICT="ok"
  MSG="检测到透明代理已生效，可以直接开始安装。"
  ADVICE="proxy: 已有"
elif [[ $DNS_OK -eq 0 || $CN_OK -eq 0 ]]; then
  VERDICT="blocker"
  MSG="连国内镜像都不通，装机必然失败。请先解决网络。"
  ADVICE="先检查网线/WiFi，或在 Live 环境里配好网络后再点安装。"
elif [[ $GH_REACHABLE -eq 0 ]]; then
  VERDICT="needs-proxy"
  if [[ ${AUR_OK:-0} -eq 1 ]]; then
    AUR_STATE="能访问"
  else
    AUR_STATE="也不通"
  fi
  MSG="官方包能从国内源装，但 github.com 不通。"
  MSG="${MSG}
这会直接导致：
  - 自编译的 Calamares 装不上 -> 安装器根本起不来
  - Shorin DMS Niri 装不上
  - AUR 上任何包都装不上

（aur.archlinux.org ${AUR_STATE}，但那只能读到 PKGBUILD，
  源码还是从 GitHub 下载 —— 所以 AUR 站通不代表能用。）"
  ADVICE="需要先配好透明代理，再点安装。"
  ADVICE="${ADVICE}
如果你在【构建 ISO 时】已经用 build/prebuild-aur.sh 把 AUR 包预编译进 ISO 了，
那装机时就不需要联网拉 GitHub —— 可以跳过代理继续装，
只是装完系统没有日常用的透明代理。"
else
  VERDICT="ok"
  MSG="网络全通，可以直接安装。"
  ADVICE="proxy: 不需要"
fi

log "verdict = $VERDICT"
log "$MSG"
log "建议：$ADVICE"
log ""
log "（本报告同时写入 /tmp/shorin-netcheck.txt，装完可查）"

# 供调用方读取
printf '%s\n' "$VERDICT" > /tmp/shorin-netcheck.verdict

case "$VERDICT" in
  ok)          exit 0 ;;
  needs-proxy) exit 10 ;;   # 能装但不完整
  blocker)     exit 20 ;;   # 一定装不上
esac
exit 0
