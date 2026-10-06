#!/usr/bin/env bash
# ============================================================================
# build.sh —— profile 根目录的构建钩子
#
# archiso 在装完包、做好 initramfs 之后会 source 这个文件，
# 让你能对 ISO 内容做最后加工。
#
# 我们这里的活儿：
#   1. 把本项目的脚本权限和解释器头再确认一遍
#   2. 清掉 pacman 缓存，让 ISO 小一点
#
# 注意：这个文件【必须存在】。archiso 会 source 它，缺了虽然不一定立刻报错，
# 但配套的 pacman.conf 一起缺的话，mkarchiso 会拿空路径去 realpath，
# 报 "realpath: '': No such file or directory" 这种完全看不出所以然的错。
# ============================================================================
echo "[mkarchiso] profile build.sh：开始收尾"

profile_dir="${profile_dir:?profile_dir 未设置}"

# 脚本权限兜底 —— 万一 git 的 mode 位或打包过程把它弄丢了
if [[ -d "${profile_dir}/airootfs/usr/local/bin" ]]; then
  chmod +x "${profile_dir}/airootfs/usr/local/bin"/*.sh 2>/dev/null || true
  chmod +x "${profile_dir}/airootfs/usr/local/bin"/shorin-reboot-notice 2>/dev/null || true
fi

# 包缓存白占地方，清掉能省几百 MB
if [[ -d "${profile_dir}/airootfs/var/cache/pacman/pkg" ]]; then
  rm -f "${profile_dir}/airootfs/var/cache/pacman/pkg"/*.pkg.tar.* 2>/dev/null || true
fi

echo "[mkarchiso] profile build.sh：收尾完成"
