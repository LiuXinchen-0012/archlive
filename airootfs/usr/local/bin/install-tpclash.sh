#!/usr/bin/env bash
# ============================================================================
# install-tpclash.sh —— 安装并配置 TPClash 透明代理
#
# 修正说明（相对原方案 4.7）：
#   * tpclash 不是 pacman 包，是 Go 二进制，必须从 GitHub Releases 下载。
#     原方案把它写进 packages.x86_64 会让 mkarchiso 直接失败。
#   * tpclash install 没有 --yes 参数。真实用法：
#         tpclash install --config <url>
#     安装结果：/usr/local/bin/tpclash + /etc/systemd/system/tpclash.service
#   * 目标系统默认从 /etc/clash.yaml 读配置；订阅是远程 URL 时用 -c 指定。
#   * 装到 systemd 后，透明代理走 TUN 模式，需要 /dev/net/tun。
#
# 用法：
#   install-tpclash.sh --config <订阅URL>
#   install-tpclash.sh --config-file <本地文件>
#   install-tpclash.sh --config-file <本地文件> --enable    # 顺便开机自启
#   install-tpclash.sh --config-file <本地文件> --enable --autofix
#       # 加 --autofix：自动给订阅配置补上 TUN 段。
#       # 很多机场的订阅默认没开 TUN，不加这个参数会启动失败且原因不明显。
# ============================================================================
set -uo pipefail

TPCLASH_VERSION="${TPCLASH_VERSION:-v0.3.10}"
MIRRORS=(
  "https://github.com/mritd/tpclash/releases/download"
  "https://ghfast.top/https://github.com/mritd/tpclash/releases/download"
  "https://gh-proxy.com/https://github.com/mritd/tpclash/releases/download"
)

CONFIG_ARG=""
CONFIG_FILE=""
ENABLE=0
AUTOFIX="${AUTOFIX:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)      CONFIG_ARG="$2"; shift 2 ;;
    --config-file) CONFIG_FILE="$2"; shift 2 ;;
    --enable)      ENABLE=1; shift ;;
    --autofix)     AUTOFIX=1; shift ;;
    --version)     TPCLASH_VERSION="$2"; shift 2 ;;
    -h|--help)     sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

log() { printf '[tpclash] %s\n' "$*"; }
err() { printf '[tpclash] ERROR %s\n' "$*" >&2; }

# --- 1. 解析出最终要用的配置来源 -------------------------------------------
if [[ -n "$CONFIG_FILE" ]]; then
  [[ -s "$CONFIG_FILE" ]] || { err "配置文件为空或不存在: $CONFIG_FILE"; exit 1; }
  # 先看一眼内容是不是像 YAML/订阅，早点发现给错了 URL 的情况
  head -c 200 "$CONFIG_FILE" | grep -qiE 'proxies:|port:|proxy-groups:|^[A-Za-z0-9+/=]{40,}$' \
    || log "WARN: $CONFIG_FILE 开头不像 Clash 订阅（若是 HTML 说明 URL 填错了）"
  CONFIG_ARG="$CONFIG_FILE"
elif [[ -n "$CONFIG_ARG" ]]; then
  # 预检订阅 URL：能不能下到、下到的是不是订阅
  log "预检订阅链接 ..."
  tmp="$(mktemp)"
  # 有些机场会按 User-Agent 分发：普通请求给面板 HTML，Clash 客户端的 UA 才给配置。
  # 所以先用 Clash 的 UA 试，不行再退回默认 UA。
  if ! curl -sfL --max-time 20 -A "clash-verge/1.6.6" "$CONFIG_ARG" -o "$tmp" \
  && ! curl -sfL --max-time 20 "$CONFIG_ARG" -o "$tmp"; then
    err "订阅链接无法下载: $CONFIG_ARG"
    exit 1
  fi
  if head -c 300 "$tmp" | grep -qiE '<!doctype html|<html'; then
    err "订阅链接返回的是 HTML 网页，不是 Clash 配置。"
    err "已尝试 Clash User-Agent，仍然返回 HTML。"
    err "常见原因：① 填的是机场【面板地址】，不是【订阅链接】——订阅通常在面板的"
    err "          「订阅设置 / 复制订阅链接」那一栏，形态如 /sub?token=xxx 或 /clash/v1?token=xxx"
    err "        ② 该服务按 User-Agent 分发，但要求的 UA 不是常见的这几个"
    err "        ③ 链接需要鉴权头（Authorization），普通请求拿不到"
    err "拿到的内容前 120 字节：$(head -c 120 "$tmp")"
    rm -f "$tmp"; exit 1
  fi
  # 到这一步基本可以认定是订阅了，再做一次内容合理性检查
  if head -c 400 "$tmp" | grep -qiE 'proxies:|proxy-groups:|^[A-Za-z0-9+/]{40,}={0,2}$'; then
    log "预检通过：看起来是 Clash 订阅"
  else
    log "WARN: 下载成功但内容不像标准 Clash 订阅，先试试能不能用"
  fi
  rm -f "$tmp"
else
  err "必须给 --config 或 --config-file"
  exit 2
fi

# --- 2. 准备二进制 ---------------------------------------------------------
# 优先用【内置】的那份 —— build/prefetch-binaries.sh 会在构建时抓好放进 ISO。
# 这样装机时完全不需要访问 GitHub。
BUNDLED=/usr/local/lib/shorin/tpclash.bin
BIN=/usr/local/bin/tpclash

if [[ -x "$BIN" ]] && "$BIN" version 2>/dev/null | grep -q "$TPCLASH_VERSION"; then
  log "已安装 $TPCLASH_VERSION，跳过"
elif [[ -s "$BUNDLED" ]] && "$BUNDLED" --help > /dev/null 2>&1; then
  log "使用 ISO 内置的 TPClash 二进制（装机时无需访问 GitHub）"
  if [[ -f "$BUNDLED.sha256" ]]; then
    want="$(cut -d' ' -f1 "$BUNDLED.sha256")"
    got="$(sha256sum "$BUNDLED" | cut -d' ' -f1)"
    if [[ "$want" != "$got" ]]; then
      err "内置二进制校验不通过（$got != $want），改用现下"
    else
      log "内置二进制 SHA256 校验通过"
      install -m 0755 "$BUNDLED" "$BIN"
    fi
  else
    install -m 0755 "$BUNDLED" "$BIN"
  fi
  [[ -x "$BIN" ]] || {
    log "内置二进制不可用，改为现下"
    rm -f "$BIN"
  }
fi

if [[ ! -x "$BIN" ]]; then
  ok=0
  for base in "${MIRRORS[@]}"; do
    for asset in "tpclash-premium-linux-amd64-v3" "tpclash-premium-linux-amd64"; do
      url="$base/$TPCLASH_VERSION/$asset"
      log "尝试下载 $url"
      if curl -sfL --max-time 180 "$url" -o /tmp/tpclash.bin; then
        chmod +x /tmp/tpclash.bin
        install -m 0755 /tmp/tpclash.bin "$BIN"
        log "已安装到 $BIN"
        ok=1; break 2
      fi
    done
  done
  [[ $ok -eq 1 ]] || { err "所有镜像都下载失败，检查网络"; exit 1; }
  rm -f /tmp/tpclash.bin
fi

# --- 3. TUN 支持 ------------------------------------------------------------
modprobe tun 2>/dev/null || true
[[ -c /dev/net/tun ]] || log "WARN: /dev/net/tun 不存在，TUN 模式可能不可用（检查内核是否编入 tun 模块）"

# --- 4. 安装为 systemd 服务 -------------------------------------------------
# 真实命令：tpclash install --config <url|file>
# 该命令会：复制自身到 /usr/local/bin/tpclash，生成 /etc/systemd/system/tpclash.service
log "执行 tpclash install --config ..."
# --auto-fix=tun：让 TPClash 自动修补远程订阅配置以支持透明代理。
# 很多机场的订阅默认【没有】开启 TUN 段，直接用会起不来但看不出原因，
# 加这个参数它会自己改写配置。代价是部分参数被硬编码。
if [[ $AUTOFIX -eq 1 ]]; then
  log "启用 --auto-fix=tun（自动修补订阅配置）"
  if ! "$BIN" install --config "$CONFIG_ARG" --auto-fix=tun; then
    err "tpclash install --auto-fix=tun 失败"
    exit 1
  fi
else
  if ! "$BIN" install --config "$CONFIG_ARG"; then
    err "tpclash install 失败"
    exit 1
  fi
fi

# tpclash 自建 service 不一定 WantedBy=multi-user.target，这里显式确保
systemctl daemon-reload
grep -q 'WantedBy=multi-user.target' /etc/systemd/system/tpclash.service 2>/dev/null \
  || sed -i 's/^\[Install\]$/[Install]\nWantedBy=multi-user.target/' /etc/systemd/system/tpclash.service
systemctl daemon-reload

# --- 5. 启用 ---------------------------------------------------------------
if [[ $ENABLE -eq 1 ]]; then
  systemctl enable tpclash.service
  systemctl start tpclash.service
  sleep 3
  if systemctl is-active --quiet tpclash.service; then
    log "tpclash.service 运行中"
    # 透明代理自检：google.com 通即说明 TUN 链路正常
    if curl -sf --max-time 12 -o /dev/null https://www.google.com; then
      log "透明代理生效（google 可达）"
    else
      log "服务在跑但 google 不通 —— 检查订阅是否有效、规则是否把流量送出去了"
    fi
  else
    err "tpclash.service 启动失败。先看日志： journalctl -u tpclash -n 50"
    if [[ $AUTOFIX -eq 0 ]]; then
      err ""
      err "很可能是因为【订阅配置里没有开启 TUN】，而 TPClash 需要 TUN 才能透明代理。"
      err "加 --autofix 参数重试，它会自动修补订阅配置："
      err "    /usr/local/bin/install-tpclash.sh --config-file <你的订阅文件> --enable --autofix"
    fi
    exit 1
  fi
fi

log "完成。服务名 tpclash.service；配置见 /etc/systemd/system/tpclash.service"
