#!/usr/bin/env bash
# ============================================================================
# setup-greetd.sh —— 把 greetd 指向 niri，sddm 设为停用
#
# 为什么不用 dms-greeter：
#   DMS 官方（danklinux）在 make dist 构建的发行版包里【禁用了 greeter 功能】，
#   源码里明确写着 "Includes the greeter functionality (disabled in distro packages)"。
#   也就是说 Arch 官方仓库的 dms-shell 包里没有 dms greeter，
#   `dms greeter install` 在发行版包上不可用。
#   → 只能用 greetd + greetd-tuigreet。
#
# 顺便实现"开机自启进 niri"：greetd 的 [security] initial_session 会跳过
# greeter 直接以指定用户跑指定命令 —— 正是 niri 要的效果。
# ============================================================================
set -uo pipefail

log() { printf '[greetd] %s\n' "$*"; }

# --- 1. 找出一个真实用户（UID >= 1000，排除系统账号）------------------------
TARGET_USER=""
while read -r u _ uid _; do
  if [[ "$uid" =~ ^[0-9]+$ ]] && (( uid >= 1000 )) && [[ "$u" != "nobody" ]]; then
    TARGET_USER="$u"; break
  fi
done < /etc/passwd

if [[ -z "$TARGET_USER" ]]; then
  log "WARN: /etc/passwd 里没有 UID>=1000 的普通用户"
  log "      装完系统后请手动执行："
  log "        sed -i 's/^user = .*/user = <你的用户名>/' /etc/greetd/config.toml"
  log "        sed -i 's/^initial_session = .*/initial_session = \"niri-session\"/' /etc/greetd/config.toml"
  exit 0
fi
log "目标用户: $TARGET_USER"

# --- 2. 写 greetd 配置 -----------------------------------------------------
mkdir -p /etc/greetd
cat > /etc/greetd/config.toml <<EOF
# 由 ARCH_SHORIN post-install 生成

[terminal]
vt = 1

[default_session]
# autologin 生效时，greetd 以这个用户身份拉起 initial_session。
# 若把下面 [security] 的 initial_session 注释掉，这里就变成 greeter 用的账号，
# 登录界面会显示 tuigreet 并允许切换会话。
user = "$TARGET_USER"
command = "tuigreet --time --remember --remember-user --cmd niri-session"

[security]
# 跳过 greeter，开机直接进 niri。target 用户由上面的 default_session.user 决定。
# 想恢复登录界面：注释掉下面这行。
initial_session = "niri-session"
EOF
log "已写 /etc/greetd/config.toml"

# --- 3. PAM：允许无密码自动登录 -------------------------------------------
# tuigreet 走 pam 认证，autologin 路径下 greetd 直接拉起 session，
# 但仍建议确保 pam_unix 支持 nullok，否则某些配置下会卡在认证。
if [[ -f /etc/pam.d/greetd ]]; then
  cp -n /etc/pam.d/greetd /etc/pam.d/greetd.shorin-bak 2>/dev/null || true
  log "已备份 /etc/pam.d/greetd"
fi

# --- 4. 停 sddm，启 greetd -------------------------------------------------
systemctl disable sddm.service 2>/dev/null || true
systemctl enable  greetd.service

# display-manager.service 别名
if [[ -e /usr/lib/systemd/system/greetd.service ]]; then
  ln -sf /usr/lib/systemd/system/greetd.service /etc/systemd/system/display-manager.service
  log "display-manager.service -> greetd"
fi

systemctl daemon-reload
log "完成。重启后将以 $TARGET_USER 自动进入 niri。"
log "想改回登录界面：注释掉 config.toml 里的 initial_session 行"
