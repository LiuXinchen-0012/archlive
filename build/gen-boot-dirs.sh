#!/usr/bin/env bash
# ============================================================================
# gen-boot-dirs.sh —— 从 archiso 自带的 releng 配置拷出 syslinux/ grub/ efiboot/
#
# 为什么需要：
#   profiledef.sh 里声明了 6 种启动方式：
#       bios.syslinux.mbr / bios.syslinux.eltorito
#       uefi-x64.grub.esp  / uefi-x64.grub.eltorito
#       uefi-x64.systemd-boot.esp / uefi-x64.systemd-boot.eltorito
#   archiso 会按名字去 profile 根目录找对应的配置目录。找不到就直接中止 ——
#   而报出来的错跟"缺目录"八竿子打不着。（栽过一次）
#
#   为什么不自己写这三套配置：syslinux 的 MBR/eltorito 引导扇区、
#   GRUB 的 ESP 分区偏移、systemd-boot 的 loader 路径，
#   每个都是几十行且要跟 archiso 的版本对上。自己维护纯属找罪受 ——
#   archiso 自己就带着一份能用的官方配置，直接拿来改名字最稳。
#
# 为什么【生成】而不是放进 git：这三个目录是纯上游产物，
#   跟着 archiso 版本走，不该被我们的 profile 冻结住。
# ============================================================================
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELENG="/usr/share/archiso/configs/releng"

if [[ ! -d "$RELENG" ]]; then
  echo "ERROR: 找不到 archiso 自带的 $RELENG" >&2
  echo "  archiso 包是不是没装全？" >&2
  exit 1
fi

echo "== 准备引导配置目录 =="
for d in syslinux grub efiboot; do
  if [[ -d "$PROFILE_DIR/$d" ]]; then
    echo "  $d/ 已存在，跳过"
    continue
  fi
  cp -r "$RELENG/$d" "$PROFILE_DIR/$d"
  echo "  $d/  ← 从 releng 拷入 ($(find "$PROFILE_DIR/$d" -type f | wc -l) 个文件)"
done

# releng 里写死的是官方 ISO 的名字和标签，改成我们的。
# 只是让 U 盘插上去看到的卷标和菜单标题对得上，不改也不影响启动。
echo "== 改 ISO 名字/标签 =="
changed=0
while IFS= read -r f; do
  if grep -qE 'archlinux-yyyy\.mm\.dd|ARCH_YYYY\.MM|archlinux-[0-9]{4}\.[0-9]{2}' "$f" 2>/dev/null; then
    sed -i \
      -e 's/archlinux-yyyy\.mm\.dd/archlinux-shorin/g' \
      -e 's/ARCH_YYYY\.MM/ARCH_SHORIN/g' \
      -e 's/archlinux-[0-9]\{4\}\.[0-9]\{2\}\.[0-9]\{2\}/archlinux-shorin/g' \
      "$f" && changed=$((changed + 1))
  fi
done < <(find "$PROFILE_DIR"/{syslinux,grub,efiboot} -type f \( -name '*.cfg' -o -name '*.conf' -o -name 'grub.cfg' \) 2>/dev/null)
echo "  改写了 $changed 个配置文件"

echo
echo "== 结果 =="
for d in syslinux grub efiboot; do
  printf "  %-10s %s 个文件\n" "$d/" "$(find "$PROFILE_DIR/$d" -type f | wc -l)"
done
