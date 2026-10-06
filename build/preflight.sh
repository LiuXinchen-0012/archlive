#!/usr/bin/env bash
# preflight.sh —— 在真正 mkarchiso 之前，先把 profile 里所有风险点验一遍。
# 只依赖 curl + tar + python3，不需要是 Arch 机器。
set -uo pipefail

PROFILE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
MIRROR="${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/archlinux}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok()   { printf '  \033[32mok\033[0m      %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m    %s\n' "$*"; FAIL=1; }
bad()  { printf '  \033[31mFAIL\033[0m    %s\n' "$*"; FAIL=1; }
head_() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ---------- 1. 包名 ----------
head_ "1. 校验 packages.x86_64 中的包名"
for db in core extra multilib; do
  [[ "$db" == multilib ]] && continue
  curl -sfL --max-time 90 "$MIRROR/$db/os/x86_64/$db.db" -o "$TMP/$db.db" \
    || { bad "无法下载 $db.db（检查网络/镜像）"; continue; }
done

python3 - "$TMP" "$PROFILE_DIR/packages.x86_64" <<'PY'
import tarfile, sys, os
tmp, pkglist = sys.argv[1], sys.argv[2]
have = set()
for db in ('core', 'extra', 'multilib'):
    p = os.path.join(tmp, db + '.db')
    if not os.path.exists(p):
        continue
    with tarfile.open(p) as t:
        for m in t.getmembers():
            if not m.name.endswith('/desc'):
                continue
            lines = t.extractfile(m).read().decode('utf-8', 'replace').splitlines()
            for i, l in enumerate(lines):
                if l.strip() == '%NAME%':
                    have.add(lines[i + 1].strip())
                    break
if not have:
    print('  FAIL    repo 数据库为空，无法校验'); sys.exit(2)

# 额外扫描本地 [build] 仓库目录（自编译的 calamares 在那里）
buildrepo = os.path.join(os.path.dirname(os.path.dirname(pkglist)),
                         'airootfs', 'etc', 'pacman.d', 'build-repo')
local = set()
if os.path.isdir(buildrepo):
    for f in os.listdir(buildrepo):
        if f.endswith('.pkg.tar.zst'):
            # calamares-3.4.2-9.shorin-x86_64.pkg.tar.zst -> calamares
            local.add(f.split('-')[0])

seen, missing, dups, from_local = set(), [], [], []
for raw in open(pkglist):
    line = raw.split('#', 1)[0].strip()
    if not line:
        continue
    if line in seen:
        dups.append(line); continue
    seen.add(line)
    if line in have:
        continue
    if line in local:
        from_local.append(line)
    else:
        missing.append(line)

print(f'  官方仓库包总数 {len(have)}，profile 引用 {len(seen)} 个')
if from_local:
    print('  ok      以下来自本地 [build] 仓库: ' + ', '.join(from_local))
if missing:
    print('  FAIL    任何地方都找不到: ' + ', '.join(missing))
if dups:
    print('  WARN    重复条目: ' + ', '.join(dups))
if not missing and not dups:
    print('  ok      全部包名有效且无重复')
sys.exit(1 if missing else 0)
PY
[[ $? -ne 0 ]] && FAIL=1

# ---------- 2. 镜像源 ----------
head_ "2. 校验 mirrorlist 中每个源"
ML="$PROFILE_DIR/airootfs/etc/pacman.d/mirrorlist"
MLCN="$PROFILE_DIR/airootfs/etc/pacman.d/mirrorlist.archlinuxcn"
PROBE_FAIL=0
PROBE_TOTAL=0
probe_all() {
  local file="$1"
  while read -r line; do
    # 跳过注释和空行
    [[ "${line// /}" =~ ^# ]] && continue
    [[ -z "${line// /}" ]] && continue
    # 取出 URL：兼容 "Server = URL" 和裸 URL 两种写法
    local url="${line#Server=}"
    url="${url#Server = }"
    url="${url// /}"
    # 展开成真实路径：$repo -> core, $arch -> x86_64
    # 注意 core.db 位于 <repo>/os/<arch>/ 下，不在仓库根目录
    local probe="$url"
    probe="${probe//\$repo/core}"
    probe="${probe//\$arch/x86_64}"
    # archlinuxcn 的数据库文件叫 archlinuxcn.db，不叫 core.db
    local db="core.db"
    [[ "$file" == *archlinuxcn* ]] && db="archlinuxcn.db"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -r 0-1024 "$probe/$db")
    if [[ "$code" == 206 || "$code" == 200 ]]; then
      ok "$code  $url"
    else
      # 单个源挂掉是常态 —— pacman 会自动 fallback 到下一个。
      # 只有【全部】源都不可用才是真的阻塞。所以这里只 WARN。
      warn "$code  $url  (探测: $probe/$db)"
      PROBE_FAIL=$((PROBE_FAIL + 1))
    fi
    PROBE_TOTAL=$((PROBE_TOTAL + 1))
  done < "$file"
}
if [[ -f "$ML" ]]; then probe_all "$ML"; else bad "找不到 $ML"; fi
if [[ -f "$MLCN" ]]; then
  echo "  -- archlinuxcn --"
  probe_all "$MLCN"
else
  bad "找不到 $MLCN"
fi

# 汇总
if [[ $PROBE_TOTAL -gt 0 && $PROBE_FAIL -ge $PROBE_TOTAL ]]; then
  bad "全部 $PROBE_TOTAL 个镜像都不可用 —— pacman 同步会直接失败"
  bad "  换一个镜像源，或稍后重试（镜像偶尔会限流/维护）"
elif [[ $PROBE_FAIL -gt 0 ]]; then
  warn "有 $((PROBE_FAIL + 0))/$PROBE_TOTAL 个源不可用，但还有能用的 —— pacman 会自动 fallback"
else
  ok "全部 $PROBE_TOTAL 个镜像源可用"
fi

# ---------- 3. shell 语法 ----------
head_ "3. shell 脚本语法"
while IFS= read -r s; do
  [[ -f "$s" ]] || continue
  if bash -n "$s" 2>/tmp/e; then ok "$(basename "$s")"; else bad "$(basename "$s"): $(cat /tmp/e)"; fi
done < <(find "$PROFILE_DIR" -name '*.sh' -not -name preflight.sh)

# ---------- 4. python 语法 ----------
head_ "4. python 模块语法"
while IFS= read -r p; do
  if python3 -m py_compile "$p" 2>/tmp/e; then ok "$(basename "$p")"; else bad "$(basename "$p"): $(cat /tmp/e)"; fi
done < <(find "$PROFILE_DIR" -name '*.py')

# ---------- 5. shell 脚本是否带可执行位 ----------
head_ "5. 可执行位"
for s in "$PROFILE_DIR"/airootfs/usr/local/bin/*.sh; do
  [[ -f "$s" ]] || continue
  [[ -x "$s" ]] && ok "$(basename "$s")" || warn "$(basename "$s") 缺可执行位（archiso 会保留 644）"
done

# ---------- 6. 交叉引用 ----------
head_ "6. 交叉引用一致性"
for f in post-install.sh shorin-remove-kde.sh install-tpclash.sh \
         launch-installer.sh shorin-reboot-notice skel-config.sh \
         setup-greetd.sh setup-snapper.sh hw-drivers.sh; do
  [[ -f "$PROFILE_DIR/airootfs/usr/local/bin/$f" ]] || { bad "缺失 $f"; continue; }
  ok "$f 存在"
done
# shorin-remove-kde.service 引用的脚本必须存在
SD="$PROFILE_DIR/airootfs/etc/systemd/system/shorin-remove-kde.service"
if [[ -f "$SD" ]]; then
  while read -r line; do
    case "$line" in ExecStart=*)
      path="${line#ExecStart=}"; path="${path%% *}"
      if [[ -f "$PROFILE_DIR/airootfs$path" ]]; then ok "service ExecStart 目标存在: $path"
      else bad "service ExecStart 目标缺失: $path"; fi ;;
    esac
  done < "$SD"
fi

# ---------- 7. 危险项 ----------
# 注意：这些扫描只看【真正会执行的命令行】，跳过注释行和 heredoc 里的提示文本，
# 否则 /etc/motd 里那句"命令： reboot"会被误判成自动重启。
head_ "7. 危险模式扫描"
strip_noise() {
  # 去掉行注释、heredoc 内容（> EOF 之间的行）、字符串字面量里的内容
  sed -e 's/[[:space:]]*#.*$//' "$1" \
    | sed -e '/<</,/^[[:space:]]*EOF[[:space:]]*$/d'
}

REBOOT_HITS=""
for s in "$PROFILE_DIR"/airootfs/usr/local/bin/*.sh; do
  [[ -f "$s" ]] || continue
  h="$(strip_noise "$s" | grep -nE '(^|[;&|(][[:space:]]*)(systemctl[[:space:]]+(-r|--reboot|reboot)|shutdown[[:space:]]+-[rh]|reboot|poweroff)([[:space:]]|;|$)' || true)"
  [[ -n "$h" ]] && REBOOT_HITS+="$(basename "$s"):$h"$'\n'
done
if [[ -n "$REBOOT_HITS" ]]; then
  bad "脚本里出现自动重启（方案要求不自动重启）:"
  printf '%s' "$REBOOT_HITS"
else
  ok "无自动重启调用"
fi

# 孤儿依赖清理：看默认值而不是"有没有这段代码"
ORPHAN_DEFAULT="$(grep -hoE 'DO_ORPHAN_CLEAN:-[01]' "$PROFILE_DIR"/airootfs/usr/local/bin/*.sh 2>/dev/null | head -1)"
ORPHAN_DEFAULT="${ORPHAN_DEFAULT##*-}"
case "$ORPHAN_DEFAULT" in
  0|"") ok "孤立依赖清理默认关闭（DO_ORPHAN_CLEAN=$ORPHAN_DEFAULT）" ;;
  1)    warn "孤立依赖清理默认【开启】—— 首次测试建议关：shorin-remove-kde.sh 里设 DO_ORPHAN_CLEAN=0" ;;
  *)    warn "读不到 DO_ORPHAN_CLEAN 默认值" ;;
esac

# 危险包名：绝对不能出现在包列表里
head_ "8. 危险/已失效包名扫描"
# 注意：calamares 本身【不在】这个列表里 —— 它是合法的，只是来自本地 [build] 仓库
STALE="calamares-config calamares-wallpapers tuigreet mlocate gdisk \
libva-mesa-driver noto-fonts-cjk-extra ttf-wqy-microhei mkinitcpio-videomode \
mkinitcpio-firmware fcitx5-pinyin fcitx5-unicode mesa-vulkan-drivers bgrub \
plasmalnf libreoffice"
STALE_HIT=""
for p in $STALE; do
  # 只看未被注释的行
  if grep -vE '^\s*#' "$PROFILE_DIR/packages.x86_64" 2>/dev/null | grep -qx "$p"; then
    STALE_HIT+=" $p"
  fi
done
if [[ -n "$STALE_HIT" ]]; then
  bad "包列表里有已知失效/错误的包名:$STALE_HIT"
  bad "  参考 README-修正说明.md；改完重跑 preflight"
else
  ok "无失效包名"
fi

# ---------- 8b. 网络预检（代理是硬前置，必须存在且能跑）----------
head_ "8b. 网络预检脚本"
NP="$PROFILE_DIR/airootfs/usr/local/bin/net-precheck.sh"
if [[ -f "$NP" ]]; then
  ok "net-precheck.sh 存在"
  bash -n "$NP" 2>/dev/null && ok "语法正确" || bad "语法错误"
  # 判据正确性：不能只看 aur 站通不通
  if grep -q 'GH_REACHABLE' "$NP"; then
    ok "判定依据是 github.com 可达性（不是 AUR 站，已修过这个 bug）"
  else
    bad "判定依据可疑 —— 应该是 github.com 可达性，不是 AUR 站"
  fi
else
  bad "缺少 net-precheck.sh —— 用户会在装机失败前很久才知道网络不行"
fi
# 启动器必须调用预检
if grep -q 'net-precheck' "$PROFILE_DIR/airootfs/usr/local/bin/launch-installer.sh" 2>/dev/null; then
  ok "启动器已接入网络预检"
else
  bad "启动器没有调用 net-precheck.sh"
fi
# 图形化代理配置入口
if [[ -x "$PROFILE_DIR/airootfs/usr/local/bin/setup-proxy-gui.sh" ]]; then
  ok "setup-proxy-gui.sh 存在且可执行"
  bash -n "$PROFILE_DIR/airootfs/usr/local/bin/setup-proxy-gui.sh" 2>/dev/null \
    && ok "语法正确" || bad "语法错误"
else
  bad "缺少可执行的 setup-proxy-gui.sh —— 用户没有图形化的代理配置入口"
fi
if compgen -G "$PROFILE_DIR/airootfs/etc/skel/Desktop/setup-proxy.desktop" > /dev/null; then
  ok "Live 桌面有「配置代理」图标"
else
  bad "Live 桌面缺少 setup-proxy.desktop"
fi
# --autofix 兜底（订阅没开 TUN 时救命）
if grep -q 'autofix' "$PROFILE_DIR/airootfs/usr/local/bin/install-tpclash.sh"; then
  ok "install-tpclash.sh 支持 --autofix（订阅未开 TUN 时自动修补）"
else
  warn "install-tpclash.sh 没有 --autofix，很多机场订阅会因此启动失败"
fi
# net-precheck 要认 gui 配置成功的标记
if grep -q 'shorin-proxy-ok' "$PROFILE_DIR/airootfs/usr/local/bin/net-precheck.sh"; then
  ok "net-precheck 认 setup-proxy-gui 的成功标记"
else
  warn "net-precheck 认不到 gui 配置的代理，会误报网络不通"
fi
# 离线订阅支持
if grep -q '代理订阅.txt' "$PROFILE_DIR/airootfs/usr/local/bin/launch-installer.sh" 2>/dev/null; then
  ok "支持离线订阅文件（桌面放 代理订阅.txt 即可）"
else
  warn "没有离线订阅支持，用户只能手打长 URL"
fi

# ---------- 9. 本地 [build] 仓库（自编译 Calamares）----------
head_ "9. 本地 [build] 仓库（自编译 Calamares）"
BUILD_REPO="$PROFILE_DIR/airootfs/etc/pacman.d/build-repo"
if [[ -d "$BUILD_REPO" ]]; then
  if compgen -G "$BUILD_REPO/calamares-*.pkg.tar.zst" > /dev/null; then
    ok "ISO 内含 calamares 包：$(basename "$(ls -1 "$BUILD_REPO"/calamares-*.pkg.tar.zst | head -1)")"
  else
    warn "ISO 内 build-repo 目录里没有 calamares 包"
    warn "  跑 build/build-calamares.sh 生成（需普通用户 + sudo）"
    warn "  或在构建机宿主上配 [build] 源，让 pacman 直接解析 calamares"
  fi
  if compgen -G "$BUILD_REPO"/*.db.tar.gz > /dev/null; then
    ok "仓库数据库已生成：$(basename "$(ls -1 "$BUILD_REPO"/*.db.tar.gz 2>/dev/null | head -1)")"
  else
    warn "缺少 repo-add 生成的 .db.tar.gz 数据库"
  fi
  # 预编译的 AUR 包（SHORIN_MODE=full 时需要）
  for p in dsearch-bin dgop xwayland-satellite shorin-dms-niri-git; do
    if compgen -G "$BUILD_REPO/$p-*.pkg.tar.zst" > /dev/null; then
      ok "预编译 AUR 包: $p"
    else
      warn "未预编译 $p —— SHORIN_MODE=full 时装机需要它"
    fi
  done
else
  bad "缺少 $BUILD_REPO 目录"
fi
if grep -q '^\[build\]' "$PROFILE_DIR/airootfs/etc/pacman.conf"; then
  ok "pacman.conf 含 [build] 段"
  [[ -f "$PROFILE_DIR/airootfs/etc/pacman.d/build-repo.conf" ]] \
    && ok "build-repo.conf 存在" \
    || bad "pacman.conf 引用了 build-repo.conf，但该文件不存在"
else
  bad "pacman.conf 里没有 [build] 段，calamares 无法安装"
fi

# 重启提示：只在 niri 里挂是不够的（第一次开机用户还在 KDE 会话里）
SK_ETC="$PROFILE_DIR/airootfs/usr/local/bin/skel-config.sh"
if grep -q 'autostart/shorin-reboot-notice.desktop' "$SK_ETC" 2>/dev/null; then
  ok "重启提示已挂 XDG autostart（KDE 会话能弹）"
else
  bad "重启提示没有挂 XDG autostart —— 第一次开机用户坐在 KDE 里会看不到提示"
fi
if grep -q 'shorin-reboot-notice' "$SK_ETC" 2>/dev/null; then
  ok "niri autostart 也指向同一脚本"
else
  warn "niri autostart 未指向 shorin-reboot-notice"
fi

# ---------- 9b. 是否真的"装机零 GitHub" ----------
head_ "9b. 装机零 GitHub 自检（决定你到底需不需要代理）"
BUNDLED_TP="$PROFILE_DIR/airootfs/usr/local/lib/shorin/tpclash.bin"
GITHUB_FREE=1
GITHUB_WHY=""
if [[ -s "$BUNDLED_TP" ]]; then
  ok "TPClash 二进制已内置"
else
  GITHUB_FREE=0
  GITHUB_WHY="${GITHUB_WHY}TPClash 未内置(装机时现下); "
fi
for p in dgop dsearch-bin xwayland-satellite shorin-dms-niri-git; do
  if compgen -G "$PROFILE_DIR/airootfs/etc/pacman.d/build-repo/$p-*.pkg.tar.zst" > /dev/null; then
    ok "AUR 包已预编译: $p"
  else
    GITHUB_FREE=0
    GITHUB_WHY="${GITHUB_WHY}$p 未预编译; "
  fi
done
if [[ $GITHUB_FREE -eq 1 ]]; then
  ok "✅ 装机全程不需要代理 —— 官方包走国内源，其余都预置在 ISO 里了"
else
  warn "⚠ 装机时仍会访问 GitHub：$GITHUB_WHY"
  warn "  没代理的话，这几项会拉不动。"
fi

# ---------- 9c. 预装常用软件 ----------
head_ "9c. 预装常用软件"
CA="$PROFILE_DIR/airootfs/usr/local/bin/common-apps.sh"
if [[ -f "$CA" ]]; then
  ok "common-apps.sh 存在"
  bash -n "$CA" 2>/dev/null && ok "语法正确" || bad "语法错误"
  grep -q 'common-apps.sh' "$PROFILE_DIR/airootfs/usr/local/bin/post-install.sh" \
    && ok "post-install 已调用" || bad "post-install 没调用 common-apps.sh"
  # libreoffice 是个坑：官方没有这个包，只有 fresh / still
  if grep -qE "^\s+libreoffice\s*$" "$CA"; then
    bad "common-apps.sh 里写了 'libreoffice' —— 官方仓库【没有】这个包，会装不上"
    bad "  正确的是 libreoffice-fresh 或 libreoffice-still"
  else
    ok "没踩 libreoffice 的坑（用的是 fresh/still）"
  fi
  # niri 配置里绑定的可执行文件，必须在预装列表里
  NIRI="$PROFILE_DIR/airootfs/usr/local/bin/skel-config.sh"
  # niri 配置里绑定的可执行文件必须在【某个地方】被装上：
  #   common-apps.sh 预装，或 post-install 的步骤 2/4 已经装
  POST="$PROFILE_DIR/airootfs/usr/local/bin/post-install.sh"
  for exe in alacritty grim slurp wl-copy; do
    grep -q "$exe" "$NIRI" 2>/dev/null || continue
    if grep -q "$exe" "$CA" 2>/dev/null; then
      ok "niri 引用 $exe -> common-apps.sh 预装"
    elif grep -q "$exe" "$POST" 2>/dev/null; then
      ok "niri 引用 $exe -> post-install 已装"
    else
      bad "niri 引用了 $exe，但哪都没装（对应快捷键按了没反应）"
    fi
  done
  # dms 二进制来自 dms-shell 包，由 post-install 步骤 4 装，不在 common-apps 里
  if grep -q 'dms ipc' "$NIRI" 2>/dev/null; then
    if grep -q 'dms-shell' "$POST" 2>/dev/null; then
      ok "niri 引用 dms -> post-install 步骤4 装 dms-shell 提供"
    else
      bad "niri 用了 dms ipc，但 post-install 没装 dms-shell"
    fi
  fi
else
  bad "缺少 common-apps.sh"
fi

# ---------- 10. Calamares 配置 ----------
head_ "10. Calamares 配置"
CAL_DIR="$PROFILE_DIR/airootfs/etc/calamares"
[[ -f "$CAL_DIR/settings.conf" ]] && ok "settings.conf 存在" || bad "缺少 settings.conf"
if [[ -f "$CAL_DIR/settings.conf" ]] && grep -qE '^\s*-\s*plasmalnf' "$CAL_DIR/settings.conf"; then
  bad "settings.conf 里还有 plasmalnf（本方案不需要 Plasma 主题模块）"
else
  ok "sequence 中无 plasmalnf"
fi
for d in "$PROFILE_DIR"/airootfs/etc/skel/Desktop/*.desktop; do
  [[ -f "$d" ]] || continue
  exec_line="$(grep -m1 '^Exec=' "$d" | cut -d= -f2-)"
  case "$exec_line" in
    /usr/local/bin/*)
      target="$PROFILE_DIR/airootfs$exec_line"
      [[ -f "$target" ]] && ok "$(basename "$d") -> $exec_line 存在" \
                         || bad "$(basename "$d") -> $exec_line 不存在" ;;
    *) ok "$(basename "$d") -> $exec_line" ;;
  esac
done
if grep -q 'sudo --preserve-env' "$PROFILE_DIR/airootfs/usr/local/bin/launch-installer.sh" 2>/dev/null; then
  ok "launch-installer.sh 提权时保留了图形环境变量"
else
  warn "launch-installer.sh 未见 preserve-env，Qt 弹窗可能连不上显示"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  printf '\033[32mPREFLIGHT PASS\033[0m —— 可以尝试 mkarchiso\n'
else
  printf '\033[31mPREFLIGHT 有告警/失败\033[0m —— 先修上面标 FAIL 的项\n'
fi
exit $FAIL
