#!/usr/bin/env bash
# archiso profile definition — ARCH_SHORIN
# 由 mkarchiso 在 build.sh 环境中 source，不是可直接执行的脚本。

iso_name="archlinux-shorin"
iso_label="ARCH_SHORIN"
iso_publisher="Shorin Custom"
iso_application="Arch Linux Shorin DMS Edition"
iso_version="1.0.0"
install_dir="arch"
buildmodes=('iso')

arch="x86_64"

# ⚠️ pacman_conf 【必须】在这里定义，否则 mkarchiso 直接崩。
#    archiso 的 _read_profile() 里是这么写的：
#        packages="$(realpath -- "${packages:-${profile}/packages.${arch}}")"   ← 有兜底
#        pacman_conf="$(realpath -- "${pacman_conf}")"                          ← 【没兜底】
#    变量为空就变成 realpath -- ""，报出来的是
#        realpath: '': No such file or directory
#    ——跟"你少写了一行"八竿子打不着。（栽过）
#
#    写相对路径就行：_read_profile() 会先 cd 到 profile 目录再 source 本文件。
#    官方 releng/profiledef.sh 第 12 行也是这么写的。
pacman_conf="pacman.conf"

# ---------------------------------------------------------------------------
# bootmodes：与原方案不同。
# 原方案写的是 'bios.syslinux' / 'uefi.systemd-boot.esp'，这是老版 archiso 的
# 旧式命名。当前 archiso 已改为 <mode>.<loader>.<variant> 三段式，沿用旧名会直接
# 报 "unknown boot mode" 并中止构建。这里按现行命名给全 BIOS + UEFI 双模。
# ---------------------------------------------------------------------------
bootmodes=(
  'bios.syslinux.mbr'
  'bios.syslinux.eltorito'
  'uefi-x64.grub.esp'
  'uefi-x64.grub.eltorito'
  'uefi-x64.systemd-boot.esp'
  'uefi-x64.systemd-boot.eltorito'
)

file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/etc/sudoers.d/live"]="0:0:440"
)
