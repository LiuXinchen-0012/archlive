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
# bootmodes：跟【官方 Arch ISO 完全一致】。
#
# ⚠️ 之前这里写的是 'uefi.grub'，ISO 构建出来、文件也齐、GRUB 也能引导内核，
#    但 initramfs 一直 "Failed to start Switch Root"。
#    archiso 在 GRUB 模式下有一套额外的定位机制（靠 /boot/<uuid>.uuid 标记文件
#    + archisosearchuuid=），和 systemd-boot 那条路不是一回事。
#    我们没必要冒这个险 —— 官方 releng 用的就是下面这个组合，
#    是被全世界验证过的配置。（栽过，ISO 白等了两轮）
# ---------------------------------------------------------------------------
bootmodes=(
  'bios.syslinux'
  'uefi.systemd-boot'
)

file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/etc/sudoers.d/live"]="0:0:440"
)
