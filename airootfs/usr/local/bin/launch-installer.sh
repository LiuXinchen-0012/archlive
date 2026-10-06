#!/usr/bin/env bash
# ============================================================================
# launch-installer.sh —— Live 桌面上的"安装 Arch"启动器
#
# 为什么不是原方案里那个 PyQt5 的 proxysub 模块：
#   Calamares 3.4.x 的 Python 接口【只支持 job，不支持 view】。
#   ModuleFactory.cpp 里 type:view 只接受 interface:qtplugin（QML），
#   type:job 才接受 interface:python。而 QML 视图模块是编译进二进制的
#   ViewStep，要加自定义输入页就得写 C++ 重编。
#
#   所以改成：在这个启动器里用 kdialog 弹输入框，拿到了再 exec calamares。
#   UX 和原方案设计的一模一样（装机前弹窗填订阅），但零编译风险。
#
# 产出：订阅写到 /tmp/proxy_subscription，供 post-install 阶段读取。
#
# 用法：桌面图标双击，或终端里直接跑。不需要 sudo 权限（脚本自己提权）。
# ============================================================================
set -uo pipefail

SUB_FILE=/tmp/proxy_subscription
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/shorin"
HIST_FILE="$STATE_DIR/last-subscription"

# ---------------------------------------------------------------------------
# 网络预检 —— 在弹订阅框之前跑
#
# 用户反馈"没代理 100% 装不上"。与其等 post-install 阶段拉不动包（那时分区
# 已做完、用户已等半小时），不如在双击安装器的这一刻就知道网络行不行。
# ---------------------------------------------------------------------------
precheck() {
  local out; out="$(/usr/local/bin/net-precheck.sh 2>&1)"; local rc=$?
  case $rc in
    0)  echo "$out"; return 0 ;;                       # 全通
    10) echo "$out"                                    # 需要代理
        local buttons
        if command -v kdialog > /dev/null 2>&1; then
          kdialog --title "网络体检：GitHub 不通" \
            --text "国内镜像源正常，但 github.com 不可达。

没有代理会导致：
  · 自编译的 Calamares 装不上 —— 安装器起不来
  · Shorin DMS Niri 装不上
  · AUR 上任何包都装不上

如果你的 ISO 是用 build/prebuild-aur.sh 预编译过 AUR 包的，
装机时不需要联网拉 GitHub，可以选择继续。

完整报告在 /tmp/shorin-netcheck.txt" \
            --yesno "现在配置代理，还是直接继续安装（部分功能会缺失）？" 2>/dev/null
          [[ $? -eq 0 ]] && return 0 || return 10
        else
          printf '%s\n' "$out" >&2
          printf '继续安装？(y/N) ' >&2
          read -r a
          [[ "$a" == "y" || "$a" == "Y" ]] && return 0 || return 10
        fi
        ;;
    20) echo "$out"
        echo "launch-installer: 连国内镜像都不通，装机必然失败" >&2
        if command -v kdialog > /dev/null 2>&1; then
          kdialog --title "网络不通，装不了" --error "$out\n\n请先解决网络（网线/WiFi/DNS）再回来重试。" 2>/dev/null || true
        fi
        return 20 ;;
    *)  echo "$out"; return 0 ;;                       # 预检本身出错，不拦
  esac
}

precheck
PRECHECK_RC=$?
if [[ $PRECHECK_RC -eq 20 ]]; then
  echo "launch-installer: 网络不通，已中止" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 第一段：普通用户身份，弹窗收集订阅
# ---------------------------------------------------------------------------
collect_subscription() {
  local prev=""
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  [[ -r "$HIST_FILE" ]] && prev="$(cat "$HIST_FILE")"

  # 离线订阅：用户可以提前把链接写进这些文件之一，脚本直接读，不要求手打
  # （手打长 URL 很容易漏字符/多空格，而 URL 错了整个装机就废了）
  local f
  for f in "$HOME/Desktop/代理订阅.txt" \
           "/run/media/$(id -u)"/*/代理订阅.txt \
           "/media/$(id -u)"/*/代理订阅.txt \
           "/run/archiso/bootmnt/archlive/proxy-subscription.txt"; do
    if [[ -s "$f" ]]; then
      local val; val="$(tr -d '\r\n' < "$f" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      if [[ -n "$val" ]]; then
        echo "launch-installer: 从 $f 读到订阅链接" >&2
        printf '%s' "$val" > "$SUB_FILE"
        chmod 644 "$SUB_FILE"
        printf '%s' "$val" > "$HIST_FILE" 2>/dev/null || true
        return 0
      fi
    fi
  done

  local val=""
  if command -v kdialog > /dev/null 2>&1; then
    val="$(kdialog --title "代理订阅（可留空）" \
      --text "如果你有机场的 Clash 订阅链接，粘进来 —— 安装完成后会自动配置透明代理。\n\n没有也可以留空，只是 AUR 和部分包可能下载不了。" \
      --inputbox "订阅链接：" "$prev" 2>/dev/null)" || val=""
  elif command -v zenity > /dev/null 2>&1; then
    val="$(zenity --entry --title="代理订阅（可留空）" \
      --text "粘贴 Clash 订阅链接，没有可留空" \
      --entry-text="$prev" 2>/dev/null)" || val=""
  else
    echo "launch-installer: 没有 kdialog/zenity，跳过订阅输入" >&2
    return 0
  fi

  # 用户点了取消（kdialog 返回非 0）—— 那就当没填，不要报错退出
  [[ -n "$val" ]] || return 0

  printf '%s' "$val" > "$SUB_FILE"
  chmod 644 "$SUB_FILE"                 # 稍后 root 阶段要读
  printf '%s' "$val" > "$HIST_FILE" 2>/dev/null || true

  # 立刻验一下，别等装到一半才发现 URL 是坏的
  local probe; probe="$(mktemp)"
  if curl -sfL --max-time 20 "$val" -o "$probe" 2>/dev/null; then
    if head -c 300 "$probe" 2>/dev/null | grep -qiE '<!doctype html|<html'; then
      local msg="这个地址返回的是网页，不是 Clash 订阅。\n\n"
      msg+="多半是把管理面板地址填成了订阅地址。\n真正的订阅通常长这样：\n"
      msg+="  http://.../sub\n  http://.../clash?token=xxxx\n\n"
      msg+="仍然要继续安装的话，忽略这个提示即可。"
      if command -v kdialog > /dev/null 2>&1; then
        kdialog --error "$msg" 2>/dev/null || true
      else
        printf '%b\n' "$msg" >&2
      fi
    fi
  else
    echo "launch-installer: 订阅链接当前下载失败，仍会继续安装" >&2
  fi
  rm -f "$probe"
  return 0
}

# ---------------------------------------------------------------------------
# 分支 A：普通用户 —— 收订阅，然后带着图形环境变量提权
# ---------------------------------------------------------------------------
if [[ "${SHORIN_LAUNCHER_STAGE:-}" != "root" ]]; then
  collect_subscription

  if [[ $EUID -eq 0 ]]; then
    export SHORIN_LAUNCHER_STAGE=root
  else
    # Qt 程序要靠这几个变量连上当前图形会话，sudo 默认会把它们清掉
    exec sudo --preserve-env=SHORIN_LAUNCHER_STAGE,SHORIN_LIVE_USER \
         env "SHORIN_LAUNCHER_STAGE=root" \
             "SHORIN_LIVE_USER=$USER" \
             "DISPLAY=${DISPLAY:-}" \
             "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}" \
             "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
             "XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}" \
         "$0" "$@"
  fi
fi

# ---------------------------------------------------------------------------
# 分支 B：root —— 确认文件可读，拉起 Calamares
# ---------------------------------------------------------------------------
[[ -f "$SUB_FILE" ]] && chmod 644 "$SUB_FILE"

if [[ -s "$SUB_FILE" ]]; then
  echo "launch-installer: 订阅已填写（${#SUB_FILE} 字节文件）"
else
  echo "launch-installer: 未填写订阅 —— 跳过透明代理，AUR/DMS 步骤可能受影响"
fi

exec /usr/bin/calamares
