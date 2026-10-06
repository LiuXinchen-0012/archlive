#!/usr/bin/env bash
# ============================================================================
# setup-proxy-gui.sh —— Live 桌面上的"配置代理"图形向导
#
# 为什么需要：
#   用户的网络环境【没有代理就装不上系统】。但订阅链接得先在 Live 环境里
#   配好透明代理，Calamares 阶段和 post-install 阶段才能拉包。
#   做成图形流程，是为了用户不用记命令、也不用看终端。
#
# 流程：
#   1. 选来源：填订阅链接 / 用桌面上的 代理订阅.txt / 跳过
#   2. 立刻预检（是不是 HTML、能不能下到）
#   3. 下载安装 TPClash（带国内加速镜像）
#   4. 启用服务 + 实际连通性验证
#   5. 第一次失败时自动用 --autofix=tun 重试
#
# 成功后写 /tmp/shorin-proxy-ok，net-precheck.sh 会据此判断。
# ============================================================================
set -uo pipefail

SUB_FILE=/tmp/proxy_subscription
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/shorin"
HIST_FILE="$STATE_DIR/last-subscription"
OK_MARK=/tmp/shorin-proxy-ok

log() { printf '[代理] %s\n' "$*" | tee -a /tmp/shorin-proxy-setup.log; }

say() {
  if command -v kdialog > /dev/null 2>&1; then
    kdialog --title "Shorin 代理配置" --text "$1" 2>/dev/null || true
  else
    printf '%s\n' "$1"
  fi
}
ask() {
  if command -v kdialog > /dev/null 2>&1; then
    kdialog --title "Shorin 代理配置" \
            --text "$2" --inputbox "$1" "${3:-}" 2>/dev/null
  else
    printf '%s' "${3:-}"; read -r REPLY && printf '%s' "$REPLY"
  fi
}
yesno() {
  if command -v kdialog > /dev/null 2>&1; then
    kdialog --title "Shorin 代理配置" --text "$1" --yesno "$2" 2>/dev/null && return 0 || return 1
  else
    printf '%s [y/N] ' "$2"; read -r a; [[ "$a" == "y" || "$a" == "Y" ]]
  fi
}

: > /tmp/shorin-proxy-setup.log
mkdir -p "$STATE_DIR" 2>/dev/null || true
rm -f "$OK_MARK"

# ---------------------------------------------------------------------------
# 0. 已经配好了就直接退出
# ---------------------------------------------------------------------------
if systemctl is-active --quiet tpclash.service 2>/dev/null \
   && curl -sf --max-time 8 -o /dev/null https://www.google.com 2>/dev/null; then
  log "代理已经在工作（tpclash.service 运行中且 google 可达）"
  say "代理已经配好了，不需要重复配置。\n\n当前状态：透明代理运行中。"
  touch "$OK_MARK"
  exit 0
fi

# 需要 root 来装系统服务和改 iptables/nftables
if [[ $EUID -ne 0 ]]; then
  log "提权到 root"
  exec sudo --preserve-env=XDG_RUNTIME_DIR,DISPLAY,WAYLAND_DISPLAY,XAUTHORITY,XDG_STATE_HOME \
       env "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
           "DISPLAY=${DISPLAY:-}" "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}" \
           "XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}" \
       "$0" "$@"
fi

# ---------------------------------------------------------------------------
# 1. 拿到订阅链接
# ---------------------------------------------------------------------------
SRC=""
SUB_URL=""

# 1a. 优先用桌面上的 代理订阅.txt
for f in "$HOME/Desktop/代理订阅.txt" /home/*/Desktop/代理订阅.txt \
         /run/media/*/*/代理订阅.txt; do
  if [[ -s "$f" ]]; then
    v="$(tr -d '\r\n' < "$f" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [[ -n "$v" ]]; then
      SRC="文件"
      SUB_URL="$v"
      log "从 $f 读取订阅"
      break
    fi
  fi
done

# 1b. 弹窗问
if [[ -z "$SUB_URL" ]]; then
  prev=""
  [[ -r "$HIST_FILE" ]] && prev="$(cat "$HIST_FILE")"
  SUB_URL="$(ask "Clash 订阅链接" \
    "把机场面板里的【订阅链接】粘进来。

粘贴后会先自动验证，不对会立刻告诉你。

如果你还没有订阅链接，可以点取消直接开始安装
（但没有代理，某些包可能装不上）。" "$prev")" || SUB_URL=""
fi

# 1c. 取消 = 不配代理
if [[ -z "$SUB_URL" ]]; then
  log "用户跳过代理配置"
  say "已跳过代理配置。\n\n接下来安装时：\n  · 官方包大概率能装（走国内镜像源）\n  · 依赖 GitHub/AUR 的包可能失败\n\n装完可以再回来配。"
  exit 0
fi

printf '%s' "$SUB_URL" > "$SUB_FILE"
chmod 644 "$SUB_FILE"
printf '%s' "$SUB_URL" > "$HIST_FILE" 2>/dev/null || true
log "已保存订阅"

# ---------------------------------------------------------------------------
# 2. 预检：先确认这不是一个网页
# ---------------------------------------------------------------------------
log "预检订阅链接"
probe="$(mktemp)"
if curl -sfL --max-time 20 -A "clash-verge/1.6.6" "$SUB_URL" -o "$probe" \
   || curl -sfL --max-time 20 "$SUB_URL" -o "$probe"; then
  if head -c 300 "$probe" | grep -qiE '<!doctype html|<html'; then
    rm -f "$probe"
    log "订阅返回 HTML —— 填的是面板地址"
    say "这个地址返回的是【网页】，不是 Clash 订阅。

你多半填的是机场的【面板地址】。真正的订阅链接要在
面板里的「订阅设置 / 一键导入 / 复制订阅」那一栏找，
长这样：
    http://面板域名/sub?token=xxxxxxxx
    https://面板域名/clash/v1?token=xxxxxxxx

验证方法：把链接贴到浏览器地址栏，
应该【下载到一个 yaml 文件】，而不是打开一个网页。"
    exit 1
  fi
  rm -f "$probe"
  log "预检通过"
else
  rm -f "$probe"
  log "订阅下载失败"
  say "订阅链接现在下载失败。可能是：
  · 链接错了
  · 机场服务器暂时挂了
  · 你的网络本身需要代理才能访问（那就套娃了）"
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. 安装 TPClash（先普通模式）
# ---------------------------------------------------------------------------
try_install() {
  local autofix="$1"
  if [[ "$autofix" == "1" ]]; then
    /usr/local/bin/install-tpclash.sh --config-file "$SUB_FILE" --enable --autofix
  else
    /usr/local/bin/install-tpclash.sh --config-file "$SUB_FILE" --enable
  fi
}

log "第 1 次尝试安装（普通模式）"
if ! try_install 0; then
  say "普通模式启动失败。

很可能是订阅配置里【没有开启 TUN】，而透明代理必须靠 TUN。
可以让工具自动修补配置再试一次吗？" "自动修补并重试？"
  if [[ $? -eq 0 ]]; then
    log "第 2 次尝试：--autofix=tun"
    if try_install 1; then
      log "auto-fix 模式成功"
    else
      say "自动修补后还是失败。\n\n看下终端里的日志，或执行：\n  journalctl -u tpclash -n 50\n\n常见原因：\n  · 订阅本身是空的/已过期\n  · 机场不提供 Clash 格式（有些只给 v2ray 链接）"
      exit 1
    fi
  else
    say "已取消代理配置。"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 4. 收尾验证
# ---------------------------------------------------------------------------
log "最终验证"
if systemctl is-active --quiet tpclash.service && \
   curl -sf --max-time 12 -o /dev/null https://www.google.com 2>/dev/null; then
  touch "$OK_MARK"
  say "✅ 代理配置成功

  · 透明代理已运行
  · google 可达（说明链路通）
  · 接下来点【安装 Arch Linux】即可

装机过程中所有下载都会走这个代理。"
  log "完成"
  exit 0
fi

say "⚠ 服务在跑但 google 仍不通

这通常说明订阅里的规则把所有流量都直连了，
或者机场节点不可用。

可以先开始安装（官方包走国内源不受影响），
装完再排查。日志： journalctl -u tpclash -n 50"
exit 1
