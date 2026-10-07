#!/usr/bin/env bash
# ============================================================================
# prebuild-aur.sh —— 在【构建机】上预编译 AUR 包，塞进 ISO 的本地 [build] 仓库
#
# 为什么需要：
#   shorin-dms-niri-git 的 source 是 git+https://github.com/SHORiN-KiWATA/...
#   GitHub 在国内就是"服务器在 Google"，装机时 clone 基本连不上。
#   它的依赖 dgop / xwayland-satellite / dsearch-bin 也都从 GitHub Releases 下载。
#
#   所以：构建机（能连 GitHub 的那台）先把它们编好，ISO 装机时 pacman -U 即可，
#   整个安装过程【不需要访问 GitHub】。
#
# 依赖结构（2026-10-05 实测 shorin-dms-niri-git r142.ccf9e8d-2）：
#   15 个核心依赖里 14 个在官方仓库（清华/中科大源，很快）
#   真正要 AUR 编译的只有 5 个：
#     ckbcomp               Perl 脚本（键盘布局预览）—— 官方仓库【没有】，只在这
#     dsearch-bin           二进制包（GitHub Releases 下载）
#     dgop                  Go（GitHub tarball）
#     xwayland-satellite    Rust（GitHub tarball）
#     shorin-dms-niri-git   纯 dotfiles（git clone）★ 唯一必须 clone 的
#
#   ⚠️ ckbcomp 这个坑值得记一笔：它写在官方 AUR 的 calamares PKGBUILD 的
#      depends 里，但【它自己不在官方仓库】。在只有官方源的干净环境里
#      `pacman -S ckbcomp` 会直接 target not found。
#
# 用法：普通用户 + sudo
#   bash build/prebuild-aur.sh              # 全部
#   ONLY=shorin-dms-niri-git bash build/prebuild-aur.sh
# ============================================================================
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$PROFILE_DIR/build/repo"
ISO_REPO="$PROFILE_DIR/airootfs/etc/pacman.d/build-repo"
PKGDIR="${PKGDIR:-$PROFILE_DIR/build/aur-pkgs}"
ONLY="${ONLY:-}"

PKGS=(
  ckbcomp              # Calamares 运行时依赖（键盘布局预览），官方仓库没有，只在 AUR
  dsearch-bin
  dgop
  xwayland-satellite
  shorin-dms-niri-git
)

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN: %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "请用普通用户运行（makepkg 不允许 root）"

  # ---------------------------------------------------------------------------
  # -1. 给 curl 套一层 --http1.1 的壳
  #
  # ckbcomp 的源码托管在 salsa.debian.org（Debian 的 GitLab），那边会偶发
  # HTTP/2 帧错误：
  #     curl: (92) [HTTP2] [1] received invalid frame: ... error -532
  # 这是传输层问题，跟包本身无关，换成 HTTP/1.1 就稳。
  # makepkg 内部就是调 curl，把这个壳放到 PATH 前面即可全局生效。
  SHIMDIR="$HOME/.cache/archlive-bin"
  mkdir -p "$SHIMDIR"
  cat > "$SHIMDIR/curl" <<'SHIM'
#!/usr/bin/env bash
exec /usr/bin/curl --http1.1 "$@"
SHIM
  chmod +x "$SHIMDIR/curl"
  export PATH="$SHIMDIR:$PATH"

# ---------------------------------------------------------------------------
# 0. 构建机自身的网络自检 —— 提前说清楚失败在哪
# ---------------------------------------------------------------------------
  say "检查构建机到 GitHub 的连通性"
  # ⚠️ 这里【绝对不能加 -h / --heads】。
  #    --heads 把输出限制在 refs/heads/*，而 HEAD 是符号引用、不在 refs/heads/ 下面，
  #    于是永远匹配不到任何 ref；配上 --exit-code 就是恒定返回 2 ——
  #    等于不管网络通不通都会判定"GitHub 不可达"。（栽过，本地健康仓库都能复现。）
  GH_PROBE="https://github.com/SHORiN-KiWATA/shorin-dms-niri.git"
  if git ls-remote --exit-code "$GH_PROBE" HEAD &>/dev/null; then
    echo "  ok  目标仓库可达"
  elif git ls-remote --exit-code https://github.com/git/git.git HEAD &>/dev/null; then
    # GitHub 本身通、只有目标仓库拉不到 —— 是仓库改名/转私有/被删，不是网络问题
    warn "GitHub 本身可达，但目标仓库拉不到：$GH_PROBE"
    warn "  → 多半是仓库改名、转为私有或已删除（不是网络问题，别去配代理）"
    warn "  → 去 https://github.com/SHORiN-KiWATA 确认现在的仓库名，改本脚本里的 URL"
    warn "  → shorin-dms-niri 是纯 dotfiles 包，拉不到只影响 Shorin 配置，装机本身不受影响"
  else
    warn "连不上 github.com —— 构建机自己也需要代理才能编译这些包"
    warn "先给这台构建机配好代理（临时设 https_proxy，或用 clash 客户端的全局模式）"
    warn "配好后重跑本脚本"
    die "GitHub 不可达"
  fi

# ---------------------------------------------------------------------------
# 1. 拉 PKGBUILD
# ---------------------------------------------------------------------------
mkdir -p "$PKGDIR"
  FAILED=()

for p in "${PKGS[@]}"; do
  [[ -n "$ONLY" && "$p" != "$ONLY" ]] && continue

  say "===== $p ====="
  d="$PKGDIR/$p"
  rm -rf "$d"; mkdir -p "$d"

  if ! curl -sfL --max-time 30 "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=$p" -o "$d/PKGBUILD"; then
    warn "$p: 拉不到 PKGBUILD，跳过"
    continue
  fi
    # AUR 的附属文件（.install / .service / .desktop 等）要单独拉，
    # 而且【不能靠猜文件名】—— 包名和文件名经常对不上：
    #     dsearch-bin 这个包要的文件叫 dsearch.service，不是 dsearch-bin.service
    # 猜错的话 makepkg 会报 "xxx was not found in the build directory"。
    # 所以从 PKGBUILD 的 source=() 里把【非 URL 的文件名】全捞出来逐个下。
    mapfile -t AURFILES < <(
      tr '\n' ' ' < "$d/PKGBUILD" \
      | grep -oE 'source(_x86_64)?=\(.*?\)' \
      | sed -E 's/^source(_x86_64)?=\(//; s/\)$//' \
      | tr -d '"'"'" \
      | tr ' ' '\n' \
      | grep -E '^[A-Za-z0-9][A-Za-z0-9._+-]*$' \
      | sort -u
    )
    # 兜底：常见的几种命名
    AURFILES+=("$p.install" "$p.desktop" "$p.service" ".AURINFO" "${p%-bin}.service")
    mapfile -t AURFILES < <(printf '%s\n' "${AURFILES[@]}" | grep -E '^[A-Za-z0-9][A-Za-z0-9._+-]*$' | sort -u)
    got=0
    for extra in "${AURFILES[@]}"; do
      [[ -f "$d/$extra" ]] && continue
      if curl -sfL --max-time 20 "https://aur.archlinux.org/cgit/aur.git/plain/$extra?h=$p" -o "$d/$extra" 2>/dev/null; then
        got=$((got + 1))
      else
        rm -f "$d/$extra"
      fi
    done
    [[ $got -gt 0 ]] && echo "  附属文件拉到 $got 个"
  # 源码目录名未必等于包名，从 PKGBUILD 里读出来
  srcdir=$(sed -nE 's/^_?pkgname=//p' "$d/PKGBUILD" | head -1 | tr -d '"'"'"' ')
  echo "  源目录: ${srcdir:-$p}"

    # ⚠️ 必须加 --syncdeps。
    #    makepkg 默认【不会】自动装依赖，只会告诉你缺什么然后失败：
    #      dgop               缺 go
    #      xwayland-satellite 缺 xorg-xwayland
    #      shorin-dms-niri    缺 dms-shell / niri / libnotify / cava … 一堆
    #    全是这一条造成的。builder 有免密 sudo，--syncdeps 才跑得动。
    #
    # 下载类失败自动重试：传输层抽风重试就好，真编译不过就别白等。
    MKLOG="$d/makepkg-attempt.log"
    rc=1
    for attempt in 1 2 3; do
      set +e
      ( cd "$d" && makepkg -f --noconfirm --clean --syncdeps ) >"$MKLOG" 2>&1
      rc=$?
      set -e
      tail -25 "$MKLOG"
      [[ $rc -eq 0 ]] && break
      if grep -qiE "curl: \(|Failure while downloading|Could not resolve host|timed out|Connection reset" "$MKLOG"; then
        if [[ $attempt -lt 3 ]]; then
          warn "$p: 下载/网络失败，重试 ($attempt/3)"
          sleep 5
          continue
        fi
      fi
      break
    done

    if [[ $rc -ne 0 ]]; then
      if grep -qiE "Missing dependencies|Could not resolve all dependencies" "$MKLOG"; then
        warn "$p: 依赖装不上（看上面 Missing dependencies 列了哪些包）"
      else
        warn "$p: 编译失败，跳过（不阻断其它包）"
      fi
      FAILED+=("$p")
      continue
    fi
    # 优先选主包：makepkg 常同时产出 xxx 和 xxx-debug，
    # 用 `ls -1t` 按时间排会【捡到 -debug】（它后生成）。
    built=""
    for cand in "$d/$p-"*.pkg.tar.zst; do
      [[ -f "$cand" ]] || continue
      case "$(basename "$cand")" in
        *-debug-*) continue ;;
      esac
      built="$cand"; break
    done
    [[ -n "$built" ]] || built=$(ls -1t "$d"/*.pkg.tar.zst 2>/dev/null | head -1)
    if [[ -n "$built" ]]; then
      echo "  产物: $(basename "$built")  ($(du -h "$built" | cut -f1))"
      # ⚠️ 必须装进【构建机自己的 pacman 数据库】。
      #    后面的包（比如 shorin-dms-niri）makepkg --syncdeps 时会去找前面编出来的
      #    包；它们只躺在 build/repo 里的话，pacman 根本不知道，
      #    会报 "target not found: dsearch-bin" 然后连锁失败。
      if sudo pacman -U --noconfirm --nodeps "$built" >/dev/null 2>&1; then
        echo "    已装入构建机（供后续包的 --syncdeps 解析）"
      else
        warn "  $p 没能装进构建机，后续依赖它的包可能失败"
      fi
    else
      warn "$p: 没找到产物"
    fi
done

# ---------------------------------------------------------------------------
# 2. 汇总进本地仓库
# ---------------------------------------------------------------------------
say "汇总到本地仓库"
  BUILT=()
  for p in "${PKGS[@]}"; do
    [[ -n "$ONLY" && "$p" != "$ONLY" ]] && continue
    # ⚠️ 这里【必须】|| true。
    #    一个包都没产出时 `ls` 退出码是 2，而 set -e 下"赋值语句"会直接带崩脚本 ——
    #    于是本该显示的 "一个包都没编出来" 永远不会出现，
    #    用户只看到莫名其妙的 "Error: exit code 2"。（栽过）
    f=$(ls -1t "$PKGDIR/$p"/*.pkg.tar.zst 2>/dev/null | head -1) || true
    if [[ -n "$f" ]]; then
      BUILT+=("$f")
    else
      FAILED+=("$p")
    fi
  done

  # 去重（一个包可能在建循环和收集阶段各失败一次）
  mapfile -t UNIQ_FAILED < <(printf '%s\n' "${FAILED[@]-}" | awk 'NF' | sort -u)

  if [[ ${#BUILT[@]} -eq 0 ]]; then
    die "一个包都没编出来。失败清单: ${UNIQ_FAILED[*]-无}"
  fi

  if [[ ${#UNIQ_FAILED[@]} -gt 0 ]]; then
    warn "以下包没编出来: ${UNIQ_FAILED[*]}"
    warn "  → 装机时这些功能会缺，需要之后手动补装"
    case " ${UNIQ_FAILED[*]} " in
      *" ckbcomp "*)
        warn "  → ⚠️ ckbcomp 缺失会直接让 calamares 依赖解析失败"
        warn "  → ISO 构建阶段会报错，第 7 步得先把它编出来"
        ;;
    esac
  fi

sudo mkdir -p "$REPO_DIR" "$ISO_REPO"
for f in "${BUILT[@]}"; do
  sudo cp "$f" "$REPO_DIR"/
  sudo cp "$f" "$ISO_REPO"/
done

# repo-add 会重算依赖关系，所以要一起收
say "生成仓库数据库"
  # ⚠️ 不要加 -f。CI 里的 repo-add 报 "invalid option -- 'f'"，
  #    多半是 pacman 版本/实现差异。删掉旧库再生成，效果一样且不会有兼容问题。
    #  ⚠️ 库名必须是 build.db.tar.gz —— pacman.conf 里写的是 [build] 段，
    #     pacman 就只会去找 $repo/build.db（或 build.db.tar.gz）。
    #     之前这里生成的是 arch-shorin.db.tar.gz，pacman 报：
    #         error: failed retrieving file 'build.db' from disk :
    #         Could not open file .../build-repo/build.db
    #     段名和库名对不上，就是这么个事。（栽过）
    #     顺手清掉历史遗留的各种 db，避免两个库并存。
    sudo rm -f "$REPO_DIR"/*.db "$REPO_DIR"/*.db.tar.gz "$REPO_DIR"/*.files.tar.gz
    sudo repo-add "$REPO_DIR/build.db.tar.gz" "$REPO_DIR"/*.pkg.tar.zst > /dev/null
    #  ⚠️ 必须再补两个"无扩展名"的符号链接！
    #     pacman 对 file:// 源用的 db 扩展名是 .db（不压缩），
    #     它只会去开 <repo>/build.db，找不到就报：
    #         error: failed retrieving file 'build.db' from disk :
    #         Could not open file .../build-repo/build.db
    #     repo-add 只生成 build.db.tar.gz，不生成 build.db。
    #     libalpm 是用 libarchive 读库的，gzip 会被透明解压，
    #     所以指向压缩库的软链完全可用（老版 repo-add 就是这么干的）。
    sudo ln -sf build.db.tar.gz        "$REPO_DIR/build.db"
    sudo ln -sf build.files.tar.gz     "$REPO_DIR/build.files"
sudo cp "$REPO_DIR/build.db.tar.gz" "$ISO_REPO"/

echo
echo "  仓库内容："
ls -lh "$ISO_REPO"/*.pkg.tar.zst 2>/dev/null | awk '{print "    " $5, $9}'

say "完成"
echo
echo "  post-install 现在会用 pacman -U 从 [build] 源装这些包，装机全程不碰 GitHub。"
echo
echo "  注意：[build] 源里同时有 calamares 和这些 AUR 包，preflight 会一起校验。"
echo "  下一步： bash build/preflight.sh ."
