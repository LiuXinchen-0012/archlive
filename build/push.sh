#!/usr/bin/env bash
# ============================================================================
# push.sh —— 推到 GitHub，并打印该点的那个 URL
#
# 用法（仓库已经解压好，在 archlive/ 目录下）：
#   git remote add origin git@github.com:<你的用户名>/archlive.git
#   bash build/push.sh
#
# 没有 ssh key 就用 https：
#   git remote set-url origin https://github.com/<你的用户名>/archlive.git
# ============================================================================
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROFILE_DIR"

step() { printf '\n\033[1;36m━━━ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

command -v git > /dev/null || die "没装 git"

# ---- 1. 仓库信息 ----
step "准备提交"
if [[ ! -d .git ]]; then
  git init -q
  git branch -M main
  ok "已 git init（分支 main）"
fi

  # ---- 上传前自检：别把影子副本提交上去 ----
  # 解压时如果指定错了目标目录（尤其是在仓库目录里面直接 tar -xzf），
  # 打包文件的顶层目录 archlive/ 会在仓库里多套一层，变成 archlive/archlive/，
  # git add -A 会把它一起提交。结果是仓库里躺着两份 profile，
  # CI 的递归检查会抓到那份旧的，报出一堆"我明明改了代码怎么还是旧的"。栽过两次。
  if [[ -d archlive ]]; then
    echo "  ❌ 发现仓库里有嵌套的 archlive/ 目录（重复的 profile 副本）"
    echo "     原因：解压时目标目录选错了，应该指到仓库的【上一层】"
    echo ""
    echo "     清理命令：git rm -r --cached archlive && rm -rf archlive"
    echo ""
    die "先清理干净再提交"
  fi

git add -A

  # ---- 显式补回可执行位 ----
  # git 在 index 里把文件记成 100644（不可执行）还是 100755，取决于 core.fileMode
  # 和首次 add 时磁盘上的权限。Windows 上 Git for Windows / IDE 常把 core.fileMode
  # 设成 false，这时 git【完全忽略磁盘权限】，改文件也没用 —— 结果就是 ISO 里
  # .sh 全不可执行：桌面图标点了没反应、systemd 单元起不来、
  # shorin-remove-kde.sh 根本不跑（首次开机删 KDE 这个核心功能直接哑火）。
  # update-index --chmod=+x 直接改 index，绕过 core.fileMode，一定生效。
  while IFS= read -r f; do
    [[ -f "$f" ]] && git update-index --chmod=+x "$f"
  done < <(git ls-files -- '*.sh' 'airootfs/usr/local/bin/shorin-reboot-notice' 'make.sh')

if git diff --cached --quiet; then
  ok "没有改动需要提交"
else
  git commit -q -m "archlive: ARCH_SHORIN ISO profile" || true
  ok "已提交"
    # 核对：airootfs 里要是还有 100644，装出来的系统会哑火
    nx=$(git ls-files --stage -- 'airootfs/**' | grep -c ' 100644 ' || true)
    if [[ "$nx" -gt 0 ]]; then
      warn "还有 $nx 个 airootfs 文件被记成不可执行（100644）"
    else
      ok "airootfs 内文件均可执行"
    fi
fi

# ---- 2. remote ----
step "检查 remote"
if ! git remote get-url origin > /dev/null 2>&1; then
  echo
  echo "  还没有 origin。先添加："
  echo
  echo "    git remote add origin git@github.com:<你的用户名>/archlive.git"
  echo
  echo "  （先在 GitHub 上新建一个空仓库，名字随意，比如 archlive）"
  echo
  die "添加后重跑本脚本"
fi
REMOTE="$(git remote get-url origin)"
ok "origin = $REMOTE"

# ---- 3. 解析出 用户名/仓库名 ----
# ⚠️ 这里踩过坑：slug 是 host/owner/repo 三段，
#    如果直接取第一段当 owner，会得到 "github.com" 而真正的用户名在第二段。
#    结果就是打印出的 URL 变成 github.com/github.com/<user>/... —— 还把 host 拼进了 URL。
step "解析 remote"
SLUG="$(printf '%s' "$REMOTE" \
  | sed -E 's|^git@([^:]+):(.+)$|\1/\2|; s|^https?://([^/]+)/(.+)/?$|\1/\2|; s|\.git$||; s|/$||')"
ok "remote slug = $SLUG"

IFS='/' read -r HOST U1 U2 REST <<< "$SLUG"
case "$SLUG" in
  */*/*)
    # host/owner/repo
    OWNER="$U1"
    REPO="${U2%%/*}"
    ;;
  */*)
    # owner/repo（SSH 形式，去掉 host 后是这种）
    OWNER="$U1"
    REPO="$U2"
    ;;
  *)
    die "解析不出 用户名/仓库名，remote 格式可能不对：$REMOTE"
    ;;
esac

if [[ "$HOST" == *.* ]]; then          # 第一段是域名
  SCHEME="https://$HOST"
else                                    # 第一段就是用户名（SSH 的 git@user:repo 形式）
  SCHEME="https://github.com"
  OWNER="$HOST"
  REPO="$U1"
fi

[[ -n "$OWNER" && -n "$REPO" ]] || die "解析失败：host=$HOST owner=$OWNER repo=$REPO"
if [[ "$OWNER" == *.* || "$REPO" == */* || -z "$REPO" ]]; then
  die "解析结果不合理（owner=$OWNER repo=$REPO），请检查 remote：$REMOTE"
fi
ok "仓库 = $SCHEME/$OWNER/$REPO"

# ---- 3b. 推送前先探测仓库是否可达 ----
# 私有仓库 + 没授权的凭据，git 会报 "Repository not found"（GitHub 用 404 隐藏存在性）。
# 先用 ls-remote 探一下，能立刻分辨是"没权限"还是"网络/名字错"，省得白传一次。
step "检查仓库可达性"
if git ls-remote --exit-code origin > /dev/null 2>&1; then
  ok "仓库可访问"
elif git ls-remote origin > /dev/null 2>&1; then
  warn "仓库能访问但还是空的（首次推送前的正常状态）"
else
  cat <<EOF2
  ✗ 访问不到远端仓库。

  最可能的原因：仓库是 Private，但 git 拿到的凭据没有私有仓库权限
  （GitHub 对无权限的私有仓库返回 404，报错就是 "Repository not found"）。

  两种解法，二选一：

  【A】把仓库改成 Public（推荐）
      $SCHEME/$OWNER/$REPO/settings
      → 页面最下方 Danger Zone → Change repository visibility → Public
      → 改完直接重跑本脚本
      好处：立刻能用，而且 Actions 分钟数变成无限

  【B】重新授权，让凭据拿到私有仓库权限
      打开 https://github.com/settings/connections/applications
      找到 "Git Credential Manager" → Configure
      权限里勾上 Private repositories（或 Repository access 包含你的仓库）
      保存后重跑本脚本

  如果都不是，可能是仓库名写错了 —— 确认一下：
      $SCHEME/$OWNER/$REPO
EOF2
  exit 1
fi

# ---- 4. 推送 ----
step "推送"
git push -u origin HEAD || die "推送失败。远端地址：$SCHEME/$OWNER/$REPO.git"
ok "已推送"

# ---- 5. 打印 URL ----
WORKFLOW_FILE="build-iso.yml"
BASE="https://github.com/$OWNER/$REPO"

cat <<EOF

$(printf '\033[1;32m')━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(printf '\033[0m')

  下一步 —— 点这个链接，然后点右边的 "Run workflow"：

  \033[1;36m$BASE/actions/workflows/$WORKFLOW_FILE\033[0m

  然后：
    1. 分支选 main
    2. shorin_mode  —— 建议第一次先选 skeleton（快 30~60 分钟）
       想装 Shorin DMS Niri 的 dotfiles 再选 full
    3. 点绿色 "Run workflow"
    4. 等它跑完（30~90 分钟）

  跑完后在这里下载 ISO：

  \033[1;36m$BASE/actions/artifacts\033[0m

  找 archlinux-shorin-iso 那个，下载得到 .iso 和 sha256sum.txt

  看日志（出问题时）：

  \033[1;36m$BASE/actions\033[0m

$(printf '\033[1;32m')━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(printf '\033[0m')

  跑完后记得把 ISO 拉回本地：
    gh run download --repo $OWNER/$REPO -n archlinux-shorin-iso
  （没有 gh 命令的话，去 Artifacts 页面点 Download）

EOF
