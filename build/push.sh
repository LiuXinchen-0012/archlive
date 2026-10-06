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

command -v git > /dev/null || die "没装 git"

# ---- 1. 仓库信息 ----
step "准备提交"
if [[ ! -d .git ]]; then
  git init -q
  git branch -M main
  ok "已 git init（分支 main）"
fi

git add -A
if git diff --cached --quiet; then
  ok "没有改动需要提交"
else
  git commit -q -m "archlive: ARCH_SHORIN ISO profile" || true
  ok "已提交"
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
SLUG="$(printf '%s' "$REMOTE" \
  | sed -E 's|^git@([^:]+):(.+)$|\1/\2|; s|^https?://([^/]+)/(.+?)(/)?$|\1/\2|; s|\.git$||; s|/$||')"

case "$SLUG" in
  */*) : ;;
  *) die "解析不出 用户名/仓库名，remote 格式可能不对：$REMOTE" ;;
esac

OWNER="${SLUG%%/*}"
REPO="${SLUG#*/}"
[[ -n "$OWNER" && -n "$REPO" ]] || die "解析失败：$SLUG"

# ---- 4. 推送 ----
step "推送"
git push -u origin HEAD || die "推送失败。用 https 的话：git remote set-url origin https://github.com/$OWNER/$REPO.git"
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
