#!/usr/bin/env bash
# preflight.sh —— 在真正 mkarchiso 之前，先把 profile 里所有风险点验一遍。
# 只依赖 curl + tar + python3，不需要是 Arch 机器。
set -uo pipefail

# --fast：只跑【不依赖已编译产物】的静态检查。
#
# 为什么需要：CI 里 preflight 原本排在编译 Calamares【之后】，
# 结果就是每次都先花十几分钟编 Qt，再被包名/PKGBUILD 字段之类的低级问题打死。
# --fast 让这些检查提前到编译之前跑，几分钟内就知道对不对。
FAST=0
if [[ "${1:-}" == "--fast" ]]; then FAST=1; shift; fi
PROFILE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
MIRROR="${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/archlinux}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok()   { printf '  \033[32mok\033[0m      %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m    %s\n' "$*"; FAIL=1; }
# note = 提示性告警，【不】置 FAIL。
# warn() 会让整个 preflight 返回非 0，CI 就此中断 —— 只有真正该拦下来的
# 问题才用 warn/bad，纯信息性的（"这会导致什么后果"）用 note。
note() { printf '  \033[33mWARN\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m    %s\n' "$*"; FAIL=1; }
head_() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ---------- 仓库 DB 下载 ----------
# 必须【无条件】执行，且要放在最前面：
#   - 1b / 1c / 9d 都要拿它当基准，只在第 1 节里下的话，--fast 模式会全盘误报
#   - 以前这里是 `[[ "$db" == multilib ]] && continue`，CI 里 multilib.db 根本没下过，
#     任何 multilib 包都会被当成"不存在"。三个库都要下。
fetch_repo_dbs() {
  for db in core extra multilib; do
    if [[ ! -s "$TMP/$db.db" ]]; then
      if ! curl -sfL --max-time 120 "$MIRROR/$db/os/x86_64/$db.db" -o "$TMP/$db.db"; then
        echo "  WARN    $db.db 拉取失败，相关校验会不准" >&2
        rm -f "$TMP/$db.db"
      fi
    fi
  done
}
fetch_repo_dbs

# ---------- 1. 包名 ----------
# ---------- 0. 重复的 profile 副本 ----------
# 有一次在【仓库目录内部】解压了打包好的 tar.gz，于是多套了一层 archlive/，
# 变成：
#     <root>/build/prebuild-aur.sh            ← 新（有 --syncdeps）
#     <root>/archlive/build/prebuild-aur.sh   ← 旧（没有）
# git add -A 会把这份影子副本一起提交上去。后果：
#   - 下面的递归扫描会抓到旧副本，报出一堆"看起来很莫名"的错
#     （比如明明改了代码，检查器却说还是旧的）
#   - 仓库白白胖一圈
#判据很直接：profiledef.sh 是 profile 根目录的标志文件，出现 >1 个就说明套娃了。
head_ "0. 检查是否存在重复的 profile 副本"
mapfile -t PROFILEDIRS < <(find "$PROFILE_DIR" -name profiledef.sh -not -path '*/.git/*' 2>/dev/null | xargs -r -n1 dirname | sort)
if [[ ${#PROFILEDIRS[@]} -gt 1 ]]; then
  echo "  FAIL    发现 ${#PROFILEDIRS[@]} 份 profile（profiledef.sh 出现了 ${#PROFILEDIRS[@]} 次）:"
  for d in "${PROFILEDIRS[@]}"; do
    echo "            $d"
  done
  echo "  → 多半是在仓库目录【里面】解压过打包的 tar.gz，多套了一层"
  echo "  → 删掉多余的那层，只保留最外层："
  echo "       git rm -r --cached archlive && rm -rf archlive"
  echo "  → 以后解压用 -C 指定到仓库的【上一层】："
  echo "       tar -xzf archlive-profile.tar.gz -C ~/Desktop/archlive"
  FAIL=1
elif [[ ${#PROFILEDIRS[@]} -eq 0 ]]; then
  echo "  FAIL    一份 profile 都没找到，路径不对？"; FAIL=1
else
  echo "  ok      只有一份 profile: ${PROFILEDIRS[0]}"
fi

if [[ $FAST -eq 0 ]]; then   # 依赖已编译产物，--fast 模式跳过

head_ "1. 校验 packages.x86_64 中的包名"
[[ -s "$TMP/core.db" ]] || bad "仓库数据库没下下来，1/1b/1c 的结论都不可信"

python3 - "$TMP" "$PROFILE_DIR/packages.x86_64" <<'PY'
import re, tarfile, sys, os
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
# ⚠️ 这里【只能往上一级】。packages.x86_64 就在 profile 根目录下，
#    dirname 一次就是 profile 根。早先写成 dirname 两次，等于去找
#    "$PROFILE_DIR/../airootfs/..." —— 那个目录压根不存在，
#    于是 calamares 永远找不到，第 1 节一路 FAIL 到今天。
#    跟那个 git ls-remote -h 是同一类错：判据自己坏了，输出却看着很合理。
profile_root = os.path.dirname(os.path.abspath(pkglist))
buildrepo = os.path.join(profile_root, 'airootfs', 'etc', 'pacman.d', 'build-repo')
local = set()
if os.path.isdir(buildrepo):
    # 包名 = 文件名里"版本号之前"的那一段。
    # 用 f.split('-')[0] 不行：calamares-debug-3.4.2-10-x86_64.pkg.tar.zst
    # 会得到 calamares，跟主包混淆（ISO 里只剩 debug 包时反而判成"找到了"）。
    for f in os.listdir(buildrepo):
        if not f.endswith('.pkg.tar.zst'):
            continue
        m = re.match(r'^([a-z0-9][a-z0-9+._-]*?)-\d', f)
        if m:
            local.add(m.group(1))
else:
    print('  WARN    找不到本地 [build] 仓库目录: ' + buildrepo)

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
# ---------- 1b. workflow 自己的构建依赖也得验 ----------
# ckbcomp 这个坑就是这么栽的：它被写在官方 AUR 的 calamares PKGBUILD 的 depends 里，
# 但【它自己不在官方仓库】。在只有官方源的干净环境里 pacman -Syu ... ckbcomp 会
# target not found，job 直接挂在第 4 步 —— 看起来像"CI 环境出问题"，
# 其实就是个包名问题。所以 workflow 里手写的依赖列表也得过这一关。
fi
head_ "1b. 校验 workflow 的构建依赖列表"
WF="$PROFILE_DIR/.github/workflows/build-iso.yml"
if [[ -f "$WF" ]] && command -v python3 >/dev/null 2>&1; then
  python3 - "$TMP" "$WF" <<'PY2' || FAIL=1
import os, re, sys, tarfile

tmp, wf = sys.argv[1], sys.argv[2]

have = set()
for db in ('core', 'extra', 'multilib'):
    path = os.path.join(tmp, db + '.db')
    if not os.path.exists(path):
        continue
    with tarfile.open(path) as t:
        for m in t.getmembers():
            if not m.name.endswith('/desc'):
                continue
            L = t.extractfile(m).read().decode('utf-8', 'replace').splitlines()
            for i, line in enumerate(L):
                if line.strip() == '%NAME%':
                    have.add(L[i + 1].strip())
                    break

# 逐行读，不用正则 —— YAML 缩进和续行太容易骗过正则了
lines = open(wf, encoding='utf-8').read().splitlines()
pkgs, collecting = [], False
for raw in lines:
    line = raw.strip()
    if line.startswith('#'):
        continue
    if not collecting:
        if line.startswith('pacman -Syu'):
            collecting = True
            tail = line.split('needed', 1)[-1].strip()
            if tail:
                pkgs += tail.split()
        continue
    # 续行：以 \ 结尾说明还有下一段
    body = line[:-1] if line.endswith('\\') else line
    pkgs += body.split()
    if not line.endswith('\\'):
        break

pkgs = [p for p in pkgs if re.fullmatch(r'[a-z0-9][a-z0-9+._-]*', p)]

if not pkgs:
    print('  WARN    没能从 workflow 里解析出依赖列表（格式可能变了，跳过）')
    sys.exit(0)

missing = [p for p in pkgs if p not in have]
print(f'  解析出 {len(pkgs)} 个构建依赖，官方仓库共 {len(have)} 个包')
if missing:
    print('  FAIL    官方仓库里【不存在】: ' + ', '.join(missing))
    print('          → 官方仓库没有的包必须从 AUR 编译（prebuild-aur.sh）；')
    print('            若是运行时依赖，就靠 [build] 源进 ISO，不要写进这一步。')
    sys.exit(1)
print('  ok      全部存在于官方仓库')
PY2
else
  warn "跳过（找不到 workflow 或 python3）"
fi

# ---------- 1c. 扫脚本里内嵌的包名 ----------
# ckbcomp 这个坑栽了两次：一次在 workflow 的依赖列表，一次在
# build-calamares.sh 的 DEPS 数组。只查 packages.x86_64 抓不到它们。
#
# 这里只认两种结构（数组声明 + try_install），【不扫单行 pacman -S】：
# 正则去匹配命令行必然把 case 标签、die 的报错文案、多行引号字符串
# 全捞进来，误报多到没法用 —— 一个天天误报的检查等于没检查。
head_ "1c. 扫脚本里内嵌的包名"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$TMP" "$PROFILE_DIR" <<'PY2' || FAIL=1
import os, re, sys, tarfile

tmp, root = sys.argv[1], sys.argv[2]

have = set()
for db in ('core', 'extra', 'multilib'):
    path = os.path.join(tmp, db + '.db')
    if not os.path.exists(path):
        continue
    with tarfile.open(path) as t:
        for m in t.getmembers():
            if not m.name.endswith('/desc'):
                continue
            L = t.extractfile(m).read().decode('utf-8', 'replace').splitlines()
            for i, line in enumerate(L):
                if line.strip() == '%NAME%':
                    have.add(L[i + 1].strip())
                    break

# prebuild-aur.sh 会从 AUR 编好、放进 [build] 源的包 —— 这些是合法来源
PROVIDED = {'calamares'}
pb = os.path.join(root, 'build', 'prebuild-aur.sh')
if os.path.exists(pb):
    m = re.search(r'^PKGS=\(\s*\n(.*?)\n\s*\)', open(pb, encoding='utf-8').read(), re.S | re.M)
    if m:
        for line in m.group(1).split('\n'):
            line = line.split('#')[0].strip()
            if re.fullmatch(r'[a-z0-9][a-z0-9+._-]{1,}', line):
                PROVIDED.add(line)

PKGRE = re.compile(r'[a-z0-9][a-z0-9+._-]{1,}')
found = {}       # 包名 -> {(文件, 数组名)}
removal = set() # 属于"删除类"数组的包名


def add(tok, src, arr, is_removal):
    tok = tok.strip()
    # 纯 shell 语法一律不算包名
    if tok in ('sudo', 'pacman', 'yay', 'paru', 'true', 'false'):
        return
    if PKGRE.fullmatch(tok):
        found.setdefault(tok, set()).add((src, arr))
        if is_removal:
            removal.add(tok)


for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in ('.git', 'node_modules')]
    for fn in filenames:
        if not fn.endswith(('.sh', '.conf')):
            continue
        path = os.path.join(dirpath, fn)
        rel = os.path.relpath(path, root)
        if rel.endswith('build/preflight.sh'):
            continue   # 检查器不扫自己：里面的嵌入式 python 会污染结果
        try:
            txt = open(path, encoding='utf-8').read()
        except Exception:
            continue

        # 兼容两种写法：DEPS=(a b c\n  d e) 和 DEPS=(\n  a b c\n)
        for m in re.finditer(r'^[ \t]*([A-Z][A-Z0-9_]*)[ \t]*=[ \t]*\(([^)]*)\)',
                             txt, re.S | re.M):
            arr = m.group(1)
            # 删除类数组：包名过期只会让那个包被跳过，不会坏事
            is_rem = bool(re.search(r'KDE_PKGS|REMOVE|DELETE|PURGE|UNINSTALL', arr))
            for line in m.group(2).split('\n'):
                line = line.split('#')[0].strip()
                # 数组里一行应该【只】是包名；出现 shell 语法说明是命令或表达式
                if line and not re.search(r'[(){}=$|&;<>"\'`]', line):
                    for tok in line.split():
                        add(tok, rel, arr, is_rem)

        # try_install "pkg" "pkg"
        for m in re.finditer(r'try_install[ \t]+([^\n&|;]+)', txt):
            for a, b in re.findall(r'"([^"]+)"|\'([^\']+)\'', m.group(1)):
                add(a or b, rel, 'try_install', False)

unknown = sorted(p for p in found if p not in have and p not in PROVIDED)
hard    = [p for p in unknown if p not in removal]
soft    = [p for p in unknown if p in removal]

print(f'  扫描到 {len(found)} 个包名；官方仓库 {len(have)} 个，[build] 源另有 {len(PROVIDED - {"calamares"})} 个')
print('  [build] 源提供: ' + ', '.join(sorted(PROVIDED)))

if soft:
    print(f'  WARN    删除类数组里有 {len(soft)} 个包名在仓库中不存在:')
    for p in soft:
        for src, arr in sorted(found[p]):
            print(f'            {p}  ←  {src} [{arr}]')
    print('          这些通常被 pacman -Qq 守卫跳过，不会坏事；但该删的包可能没删掉。')

if hard:
    print('  FAIL    既不在官方仓库、也不在 prebuild-aur.sh 预编译列表:')
    for p in hard:
        for src, arr in sorted(found[p]):
            print(f'            {p}  ←  {src} [{arr}]')
    print('          → 改用官方包名，或把它加进 prebuild-aur.sh 的 PKGS 由 AUR 编译')
    sys.exit(1)

if not soft:
    print('  ok      全部可解析')
else:
    print('  ok      硬依赖全部可解析')
PY2
else
  warn "跳过（没有 python3）"
fi

head_ "1d. makepkg 调用是否漏了 --syncdeps"
# makepkg 默认【不会】自动安装依赖，只会报
#     ==> Missing dependencies:  -> go
# 然后失败。之前 dgop / xwayland-satellite / shorin-dms-niri 三个包
# 全是因为漏了 --syncdeps 而挂，一个白等好几分钟。
# 唯一允许的例外是显式写了 --nodeps（那是明知道要跳过）。
# 只认【真正的调用】：makepkg 后面跟着 -flag 的才算。
# `command -v makepkg`、注释里提到 makepkg 的都不能算，否则满屏误报。
MK_BAD=$(
  grep -rn "makepkg" --include="*.sh" "$PROFILE_DIR" 2>/dev/null \
    | sed 's/#.*//' \
    | grep -E "makepkg[[:space:]]+-" \
    | grep -vE -- "--syncdeps|--nodeps|(^|[[:space:]])-d([[:space:]]|$)" \
    | grep -v "build-calamares.sh" \
    || true
)
# build-calamares.sh 是刻意的例外：它用自己的 DEPS 数组显式装依赖，
# 【不能】用 --syncdeps —— calamares 的运行时依赖里有 ckbcomp，
# 而 ckbcomp 此刻还没编出来（要等 prebuild-aur），--syncdeps 解析不了会直接失败。
# 它靠后面那道 "--nodeps 自动降级" 兜底。
if [[ -n "$MK_BAD" ]]; then
  echo "  FAIL    这些 makepkg 调用没带 --syncdeps，会因缺依赖失败："
  echo "$MK_BAD" | sed 's/^/            /'
  echo "          → 加上 --syncdeps（运行用户需要有 sudo）"
  FAIL=1
else
  echo "  ok      所有 makepkg 调用都带 --syncdeps 或显式 --nodeps"
fi

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

  # ---------- 4b. shell 里内嵌的 Python（heredoc）----------
  # .py 文件有 py_compile 兜着，但【嵌在 shell heredoc 里的 Python】没人管。
  # 栽过：给 import 那行多打了两个空格，bash 不报错（heredoc 内容是字面量），
  # 只有真正执行到才炸，报的还是 IndentationError 这种看着像代码问题的信息。
  # 判据：把每个 <<'PY'…PY' 块抽出来 compile() 一次，纯语法检查、不执行。
  head_ "4b. 内嵌 Python（heredoc）语法"
  if command -v python3 >/dev/null 2>&1; then
    EMBED_BAD=$(python3 - "$PROFILE_DIR" <<'PYEMB' || true
import os, re, sys
root = sys.argv[1]
bad = 0
total = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in ('.git', 'node_modules')]
    for fn in filenames:
        if not fn.endswith('.sh'):
            continue
        p = os.path.join(dirpath, fn)
        try:
            txt = open(p, encoding='utf-8').read()
        except Exception:
            continue
        for tag, code in re.findall(r"<<'(PY[0-9A-Za-z_]*)'\n(.*?)\n\1", txt, re.S):
            total += 1
            try:
                compile(code, tag, "exec")
            except SyntaxError as e:
                bad += 1
                print(f'  FAIL    {os.path.relpath(p, root)} 的 {tag} 块第 {e.lineno} 行: {e.msg}')
if total == 0:
    print('  ok      没有内嵌 Python 块')
elif bad == 0:
    print(f'  ok      {total} 个内嵌 Python 块语法都正确')
sys.exit(1 if bad else 0)
PYEMB
)
    [[ -n "$EMBED_BAD" ]] && echo "$EMBED_BAD"
    if [[ -n "$EMBED_BAD" ]]; then FAIL=1; else ok "内嵌 Python 语法检查通过"; fi
  else
    warn "跳过（没有 python3）"
  fi

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
if [[ $FAST -eq 0 ]]; then   # 依赖已编译产物，--fast 模式跳过
head_ "9. 本地 [build] 仓库（自编译 Calamares）"
BUILD_REPO="$PROFILE_DIR/airootfs/etc/pacman.d/build-repo"
if [[ -d "$BUILD_REPO" ]]; then
  # ⚠️ 必须确认是【主包】calamares-<ver>-*.pkg.tar.zst，不是 calamares-debug-*。
  #    只有 debug 包的话，ISO 里根本没有安装器，mkarchiso 会直接报
  #    "target not found: calamares"。这个坑栽过一次。
  if compgen -G "$BUILD_REPO/calamares-[0-9]*.pkg.tar.zst" > /dev/null; then
    ok "ISO 内含 calamares 主包：$(basename "$(ls -1 "$BUILD_REPO"/calamares-[0-9]*.pkg.tar.zst | head -1)")"
    compgen -G "$BUILD_REPO/calamares-debug-*.pkg.tar.zst" > /dev/null \
      && ok "  （另有 debug 包，无害）"
  elif compgen -G "$BUILD_REPO/calamares-debug-*.pkg.tar.zst" > /dev/null; then
    bad "ISO 里只有 calamares-debug，没有主包 calamares —— 装出来的系统没有安装器！"
    bad "  原因多半是 build-calamares.sh 用 ls -1t 挑产物时捡到了后生成的 debug 包"
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
fi
if [[ $FAST -eq 0 ]]; then   # 依赖已编译产物，--fast 模式跳过
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
  note "⚠ 装机时仍会访问 GitHub：$GITHUB_WHY"
  note "  没代理的话，这几项会拉不动。"
fi

# ---------- 9c2. 换行符（CRLF 会让 CI 上每个脚本都炸）----------
fi
head_ "9d. PKGBUILD 字段（makepkg 会当场拒掉的那些）"
PKGB="$PROFILE_DIR/build/PKGBUILD.calamares-shorin"
if [[ -f "$PKGB" ]]; then
  # 纯文本解析，不 source —— source 会牵扯函数定义/变量展开，
  # 一旦 PKGBUILD 里引用了未定义变量就会误报"语法错误"。
  PKGREL_VAL="$(sed -n 's/^[[:space:]]*pkgrel=//p' "$PKGB" | head -1 | tr -d "'\"" )"
  PKGVER_VAL="$( sed -n 's/^[[:space:]]*pkgver=//p'  "$PKGB" | head -1 | tr -d "'\"" )"
  PKGNAME_VAL="$(sed -n 's/^[[:space:]]*pkgname=//p' "$PKGB" | head -1 | tr -d "'\"")"

  if [[ -z "$PKGNAME_VAL" ]]; then
    echo "  FAIL    读不到 pkgname"; FAIL=1
  else
    echo "  ok      pkgname = $PKGNAME_VAL"
  fi

  # pkgrel 必须是 整数[.整数]。写成 "9.shorin" 这类会被 makepkg 当场拒掉：
  #   ERROR: pkgrel must be of the form 'integer[.integer]', not 9.shorin.
  if [[ "$PKGREL_VAL" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "  ok      pkgrel  = $PKGREL_VAL  (整数[.整数])"
  else
    echo "  FAIL    pkgrel = '$PKGREL_VAL' 非法"
    echo "          → makepkg 会直接拒绝：pkgrel must be of the form 'integer[.integer]'"
    echo "          → 补丁版的身份请写进 pkgdesc；pkgrel 里【只能放数字】"
    FAIL=1
  fi

  if [[ "$PKGVER_VAL" =~ ^[0-9A-Za-z.+_~]+$ ]]; then
    echo "  ok      pkgver  = $PKGVER_VAL"
  else
    echo "  FAIL    pkgver = '$PKGVER_VAL' 非法"; FAIL=1
  fi

  # source 和 sha256sums 条数必须一致，否则 makepkg 拒绝。
  # 注意 source 可能是【单行数组】source=("a::b")，用 awk 从下一行开始数会把
  # 后面注释也数进去 —— 这里交给 python 按引号数，最省事。
  if command -v python3 >/dev/null 2>&1; then
    PKG_COUNT_OUT="$(python3 - "$PKGB" <<'PY2'
import re, sys
txt = open(sys.argv[1], encoding='utf-8').read()


def array_len(name):
    m = re.search(r'^' + name + r'=\((.*?)\)', txt, re.S | re.M)
    if not m:
        return -1
    body = m.group(1)
    body = re.sub(r'#[^\n]*', '', body)
    if not body.strip():
        return 0
    q = re.findall(r'"([^"]*)"|\'([^\']*)\'', body)
    if q:
        return len(q)
    return len([t for t in body.split() if t])


print(f'{array_len("source")} {array_len("sha256sums")}')
PY2
)"
    NSRC="${PKG_COUNT_OUT%% *}"
    NSUM="${PKG_COUNT_OUT##* }"
  else
    NSRC=-1; NSUM=-1
  fi
  if [[ "$NSRC" == "$NSUM" && "$NSRC" -gt 0 ]]; then
    echo "  ok      source($NSRC) 与 sha256sums($NSUM) 条数一致"
  else
    echo "  FAIL    source=$NSRC / sha256sums=$NSUM 条数不一致或为 0"; FAIL=1
  fi
else
  warn "跳过（找不到 PKGBUILD）"
fi

head_ "9c2. .gitattributes（防止 CRLF 破坏 CI）"
GA="$PROFILE_DIR/.gitattributes"
if [[ -f "$GA" ]]; then
  ok ".gitattributes 存在"
  if grep -q 'eol=lf' "$GA"; then ok "已声明 eol=lf"
  else bad ".gitattributes 里没有 eol=lf —— CRLF 会让 CI 上的脚本全部报错"; fi
  if grep -qE '\*\.sh.*eol=lf|\* text=auto eol=lf' "$GA"; then ok ".sh 会被强制 LF"
  else bad ".sh 没被显式指定（虽然通配规则可能覆盖，但显式更稳）"; fi
else
  bad "缺少 .gitattributes —— Windows 上 push 上去的 .sh 会是 CRLF，CI 里全崩"
fi

# ---------- 9c. 预装常用软件 ----------
if [[ $FAST -eq 0 ]]; then   # 依赖已编译产物，--fast 模式跳过
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
fi
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
