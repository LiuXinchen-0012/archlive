# 测试与写盘 —— VMware + Ventoy 专用

> 面向：Windows + VMware Workstation/Player + Ventoy U 盘
> 本文只讲这两条路径，VirtualBox / dd 那套不用看。

---

## 一、VMware 测 ISO

### 建虚拟机

VMware Workstation / Player 都一样：

```
File → New Virtual Machine
  → I will install the operating system later
  → Guest OS: Other          Version: Other 64-bit
```

### 关键设置（默认值大部分不能用）

| 项 | 改成 | 为什么 |
|---|---|---|
| **内存** | 8192 MB 以上 | KDE Plasma + 双内核 + Calamares，4G 会 OOM |
| **处理器** | 4 核 | 装完要编译/解压大量包 |
| **硬盘** | 40 GB 以上 | 实测算过：装完约 15~20 GB |
| **固件类型** | 见下 | 决定 BIOS 还是 UEFI 启动 |
| **安全启动** | **关闭** | 我们的引导器没做 shim 签名，Secure Boot 会拦住 |
| CD/DVD | 选你的 ISO，勾 **Connect at power on** | |
| 打印机 | 移除 | 纯浪费启动时间 |
| 声卡 | 移除 | 同上 |

### BIOS / UEFI 两种固件都要测

这是**最容易漏的一步** —— 实机能不能启动取决于这个，虚拟机能测出来就省了事。

**UEFI 测法：**
```
虚拟机设置 → 选项(Options) → 固件(Firmware) → 类型: UEFI
```
UEFI 下如果 Secure Boot 默认开着，**必须关掉**：
```
虚拟机设置 → 选项 → 安全启动(Secure Boot) → 取消勾选"启用安全引导"
```

**BIOS 测法：**
```
虚拟机设置 → 选项 → 固件 → 类型: BIOS（或 Legacy）
```

### 网络用 NAT 就够

默认 NAT 就行，不用桥接。反而 **NAT 更好** —— 装系统时要在虚拟机里跑透明代理，NAT 下一切都在 NAT 后面，配代理时不容易和宿主机打架。

### 磁盘建议

反复测试的话，把硬盘设成 **Independent / Non-persistent**（独立非持久），每次关机自动丢弃改动。测坏了直接重开，不用重装。

要留快照的话记得定期删，VMware 快照会越吃越多。

---

## 二、Ventoy 写盘

### 为什么用 Ventoy 而不是 dd

Ventoy 装好之后，**加 ISO 只是复制文件**：

- 不用每次擦 U 盘
- 一个 U 盘可以放 Arch ISO、官方 Arch ISO、还有别的系统镜像
- 启动时在菜单里选要进哪个
- 写错了删掉文件重下就行

### 步骤

**① 一次性安装 Ventoy**（会清空 U 盘，仅此一次）

下载 <https://www.ventoy.net/cn/index.html> → 选 Windows 版 → 解压。

1. 插上 U 盘（**会清空，提前备份**）
2. 双击 `Ventoy2Disk.exe`
3. 设备选你的 U 盘
4. 分区方式选 **GPT**
5. 勾选「安全启动支持」或直接用默认 → 点安装

装完 U 盘会多出两个分区（一个 EFI，一个 exFAT），正常。

**② 复制 ISO 进去**

把 `archlinux-shorin-1.0.0-x86_64.iso` **直接复制到 U 盘根目录**就行。不用改名，放哪个目录都行。

**③ 启动**

重启进 U 盘，Ventoy 菜单里会列出所有 ISO，选 Arch 那个进。

### 校验（可选但建议）

复制可能损坏。进 Ventoy 菜单 → 按 `F5` 可以查看文件 hash。或者用 PowerShell 跟 `sha256sum.txt` 比对：

```powershell
Get-FileHash E:\archlinux-shorin-1.0.0-x86_64.iso -Algorithm SHA256
```

（`E:` 换成你的 U 盘盘符）

---

## 三、装完之后的检查清单

无论 BIOS 还是 UEFI，装完都要确认：

| # | 检查 | 命令 / 现象 |
|---|---|---|
| 1 | 桌面图标能拉起安装器 | 双击「安装 Arch Linux」→ 弹订阅框 |
| 2 | Live 桌面能进 | SDDM 自动登录进 KDE Plasma |
| 3 | 装完能进 niri | 重启后看到 DMS 界面 |
| 4 | KDE 删干净 | `pacman -Q \| grep -i plasma` → 空 |
| 5 | 二次重启仍进 niri | 再重启一次 |
| 6 | 没有半途失败 | `ls /var/lib/shorin-incomplete` → 文件不存在 |
| 7 | 代理按需 | 桌面「配置代理」，或看 `/tmp/shorin-proxy-setup.log` |
| 8 | 快照是否生效 | `snapper list`（布局不对时会跳过，看日志） |

### 出问题先看日志

```bash
cat /var/log/shorin-install.log        # 装机全程
cat /var/log/shorin-remove-kde.log     # 删 KDE
cat /var/log/shorin-drivers.log        # 驱动检测
cat /tmp/shorin-netcheck.txt           # 网络体检
```

### 进不去图形界面时

用 TTY 登录（开机按 `Ctrl+Alt+F2`，用户名是你装机时设的）：

```bash
systemctl status display-manager
journalctl -b -u display-manager -n 50
```

---

## 四、给正式装机的小建议

如果 VMware 里测通了，正式装机还是**先在 VMware 里把完整流程走一遍**（包括首次启动删 KDE、第二次重启进 niri），确认没问题再动真机。

真机装的时候注意两点：

1. **分区时看清楚盘符** —— VMware 里盘符是 `/dev/sda`，真机可能是 `/dev/nvme0n1` 或 `/dev/sda`，别照抄
2. **BIOS 里记得关掉 Secure Boot**（如果有这个选项）—— 我们的引导器没签名
