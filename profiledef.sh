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
# bootmodes：只有两个，且这个组合是 archiso 91 唯一认的写法。
#
# 踩过的坑（一次 CI 一次报出来）：
#   1. 之前写了六个：bios.syslinux.mbr / .eltorito / uefi-x64.grub.* /
#      uefi-x64.systemd-boot.*，结果是——
#        · mbr 和 eltorito 在 91 里【已废弃】，archiso 会把它们自动删掉、
#          换成一个 bios.syslinux，写了等于没写
#        · uefi.grub 和 uefi.systemd-boot 【互斥】，两个都写会直接报
#          "cannot be used with the 'uefi.grub' bootmode!" 然后中止
#   2. bios.syslinux 要求 packages.x86_64 里有 syslinux 包，
#      缺了报 "The 'syslinux' package is missing from the package list!"
#
# 所以：BIOS 用 bios.syslinux，UEFI 用 uefi.grub（Ventoy 兼容好、有图形菜单）。
# 想换成 systemd-boot 就只留 'uefi.systemd-boot'，两个别同时写。
# ---------------------------------------------------------------------------
bootmodes=(
  'bios.syslinux'
  'uefi.grub'
)

file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/etc/sudoers.d/live"]="0:0:440"
)
