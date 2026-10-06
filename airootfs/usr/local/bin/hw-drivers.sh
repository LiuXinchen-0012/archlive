#!/usr/bin/env bash
# ============================================================================
# hw-drivers.sh —— 硬件驱动检测与安装（保守策略）
#
# 策略说明（重要）：
#   默认【只装厂商中立的开源栈】，不自动装闭源驱动。理由：
#     * 闭源驱动装错 = 黑屏，且你现在没有图形界面可用来恢复；
#     * 双内核（zen + lts）意味着闭源模块要为每个内核各编一份，复杂度翻倍；
#     * 驱动问题往往在真实硬件上才暴露，虚拟机里 hwdetect 的结论不可靠。
#   检测结果写进 /var/log/shorin-drivers.log 和 /var/lib/shorin-gpu，
#   你可以照着它手动装。
#
#   想让脚本自动装 NVIDIA/AMD 闭源驱动：装系统时预置标记文件
#     sudo touch /etc/shorin-install-proprietary-drivers
#   之后重跑本脚本。
# ============================================================================
set -uo pipefail

LOG=/var/log/shorin-drivers.log
PROPRIETARY_MARK=/etc/shorin-install-proprietary-drivers

log() { printf '[drivers] %s\n' "$*" | tee -a "$LOG"; }

: > "$LOG"
log "===== 驱动检测 $(date) ====="

# --- 1. 硬件概览 -----------------------------------------------------------
log "--- lspci 摘要 ---"
if command -v lspci > /dev/null 2>&1; then
  lspci -nn >> "$LOG" 2>&1
  GPU_INFO="$(lspci -nn | grep -iE 'vga|3d controller|display' || true)"
  NET_INFO="$(lspci -nn | grep -iE 'ethernet|network' || true)"
  AUDIO_INFO="$(lspci -nn | grep -iE 'audio' || true)"
else
  log "lspci 未安装"
  GPU_INFO=""; NET_INFO=""; AUDIO_INFO=""
fi

# --- 2. GPU 判定 -----------------------------------------------------------
GPU_VENDOR="unknown"
GPU_MODEL=""
if [[ -n "$GPU_INFO" ]]; then
  log "--- 显卡 ---"
  echo "$GPU_INFO" | tee -a "$LOG"
  if   echo "$GPU_INFO" | grep -qiE 'NVIDIA|10de:'; then GPU_VENDOR="nvidia"
  elif echo "$GPU_INFO" | grep -qiE 'AMD|ATI|1002:'; then GPU_VENDOR="amd"
  elif echo "$GPU_INFO" | grep -qiE 'Intel|8086:';  then GPU_VENDOR="intel"
  fi
  GPU_MODEL="$(echo "$GPU_INFO" | head -1 | cut -d: -f3- | sed 's/^ *//')"
fi
printf 'vendor=%s\nmodel=%s\n' "$GPU_VENDOR" "$GPU_MODEL" > /var/lib/shorin-gpu
log "GPU: $GPU_VENDOR / $GPU_MODEL"

# --- 3. 厂商中立驱动栈（始终安装）-----------------------------------------
log "安装开源图形栈"
pacman -S --noconfirm --needed \
  mesa libglvnd libglx mesa-demos \
  vulkan-icd-loader vulkan-radeon vulkan-intel \
  libva libva-intel-driver \
  intel-media-driver \

  > /dev/null 2>&1 || log "开源图形栈安装有失败项"
log "开源图形栈就绪（Mesa / Vulkan / VA-API）"

# --- 4. 内核模块：按实际硬件启用 ------------------------------------------
log "按硬件启用内核模块"
MODS=()
# 显卡
case "$GPU_VENDOR" in
  intel) MODS+=(i915) ;;
  amd)   MODS+=(amdgpu) ;;
  nvidia) MODS+=(nouveau) ;;   # 闭源未装时先有 nouveau 兜底可显示
esac
# 常见无线
if [[ -n "$NET_INFO" ]] && echo "$NET_INFO" | grep -qiE 'wireless|802\.11'; then
  for m in iwlwifi iwlmvm ath9k ath9k_seq rtl8821ce rtwnet; do MODS+=("$m"); done
fi
# 常见有线/存储/其他
MODS+=(e1000e e1000 igb ixgbe r8169 r8125 iwlwifi ahci nvme usb_storage sd_mod
       snd_hda_intel snd_hda_codec_realtek snd_hda_codec_hdmi
       kvm_intel kvm_amd vboxnetflt vboxguest virtio_net virtio_blk virtio_pci)

[[ ${#MODS[@]} -gt 0 ]] && printf '%s\n' "${MODS[@]}" | sort -u > /etc/modules-load.d/shorin.conf
log "已写 /etc/modules-load.d/shorin.conf（$(sort -u <<<"${MODS[*]}" | wc -l) 个模块）"

# --- 5. 触摸板 / 电源 / 硬件支持 ------------------------------------------
pacman -S --noconfirm --needed xf86-input-libinput 2>/dev/null
# 双内核的 headers 已随 packages 装好，这里补 DKMS 依赖
pacman -S --noconfirm --needed dkms 2>/dev/null || true

# --- 6. 闭源驱动（仅在有标记时）------------------------------------------
if [[ -f "$PROPRIETARY_MARK" ]]; then
  log "检测到 $PROPRIETARY_MARK —— 安装闭源驱动"
  case "$GPU_VENDOR" in
    nvidia)
      # 双内核：nvidia 包会为已安装的内核自动生成模块（含 DKMS 路径）
      log "安装 NVIDIA 驱动（会为 zen + lts 各编一份，可能需要 10 分钟）"
      if ! pacman -S --noconfirm --needed nvidia nvidia-utils nvidia-settings; then
        log "NVIDIA 驱动安装失败；回退到 nouveau"
        sed -i 's/^nouveau/nouveau/' /etc/modules-load.d/shorin.conf
      fi
      ;;
    amd)
      log "AMD 显卡图形走 Mesa 即可（libva-mesa-driver 已不存在，Mesa 自带 VA-API）"
      pacman -S --noconfirm --needed mesa > /dev/null 2>&1
      log "如需 ROCm 计算栈请自行安装 rocm"
      ;;
    intel)
      log "Intel 显卡驱动已由 mesa + intel-media-driver 覆盖，无需额外闭源包"
      ;;
  esac
  # 触屏/平板
  pacman -S --noconfirm --needed libwacom > /dev/null 2>&1 || true
else
  log "未发现 $PROPRIETARY_MARK —— 不装闭源驱动（默认安全策略）"
  log "  检测到的显卡：$GPU_VENDOR $GPU_MODEL"
  case "$GPU_VENDOR" in
    nvidia) log "  如需 NVIDIA 闭源驱动：sudo touch $PROPRIETARY_MARK && sudo /usr/local/bin/hw-drivers.sh" ;;
    amd)    log "  AMD 显卡用 Mesa 通常即可；如需 ROCm 请自行安装 rocm" ;;
    intel)  log "  Intel 已由 mesa + intel-media-driver 覆盖" ;;
  esac
fi

# --- 7. 重建 initramfs（模块变了）-----------------------------------------
log "重建 initramfs"
mkinitcpio -P > /dev/null 2>&1 || log "WARN: mkinitcpfs -P 失败"

log "===== 完成。完整信息见 $LOG ====="
exit 0
