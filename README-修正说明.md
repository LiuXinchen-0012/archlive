# ARCH_SHORIN — 修正说明

> 原方案：`arch方案.docx`
> 本次核对日期：**2026-10-05**（所有外部事实均当日实测）
> 核对方式：下载官方 `core.db` / `extra.db` 逐包名比对 + 实际 HTTP 探测 + 查上游仓库

---

## 0. 一句话结论

原方案**不能直接构建**。有 1 个致命阻断、5 个会静默失败的错误、若干包名已失效。
下面按"必须改 → 会坏 → 建议改"三级列出，附实测证据。

---

## 1. 🔴 致命：Calamaras 已不在 Arch 官方仓库

**实测证据（2026-10-05）：**

```
下载 mirrors.tuna.tsinghua.edu.cn/archlinux/{core,extra,multilib}/os/x86_64/*.db
  core:     0 个匹配 "calamares"
  extra:    0 个匹配 "calamares"
  multilib: 0 个匹配 "calamares"

archlinux.org/packages/?q=calamares  →  0 results（含 testing 仓库）
```

原方案第 2 节的整个架构（`Calamares 自定义页面`、`settings.conf` 的
`sequence`、`modules/proxysub/main.py`、`shellprocess*.conf`）都建立在这个前提上。

**当前可用选项：**

| 路线 | 状态 | 代价 |
|---|---|---|
| A. AUR 的 `calamares` | 存在（maintainer `gyfooya`，6 votes，未 orphan） | 需源码编译塞进 ISO；Qt6/C++ 构建链重 |
| B. **`archinstall`** | ✅ 官方 extra，`archinstall 4.5-1` | 专为无人值守自动安装设计 |
| C. 纯 AUR 直装 | ⚠️ 见下方安全提示 | 需逐包审 PKGBUILD |

**AUR 当前安全状态（必须知道）：**

- 2026-07-30 Arch 官方因**恶意 takeover 事件**停用了 AUR 领养机制（截至本文写作仍停用）
- 2026-06-12 Arch 披露过一轮大规模恶意包更新
- 原方案第 7 节写"使用 AUR 快照而非实时 clone"来防 AUR 投毒 —— 方向对，但当下
  "AUR 快照"本身也可能是被污染的快照。**逐个审 PKGBUILD 是绕不开的。**

**决定：走 A（自编译 Calamares）。** 已按此实现，下面是代价与做法。
（此前我建议过 B，见第 1 节末尾的对比表；用户选择保留原设计的图形化流程。）

A 路的真实成本：

1. 官方仓库内的包，不碰 AUR
2. 它就是为"脚本化自动安装"设计的，覆盖原方案 Calamares 要做的每一件事
3. 配置文件是 JSON schema 化的（仓库里有 `schema.json`），不靠手写 YAML 碰运气

**关于体积（先纠正一个常见误解）：** Calamares 本体只有约 2 MB，而且你的 ISO 本来就
装了 `plasma-meta`（Qt6 全家桶都在里面），**增量很小**。"Calamares 会把 ISO 撑爆"
是误解 —— 走 A 路的真实成本不在体积，而在下面两条：

| 你原稿里写的 | 实际 | 我们的处理 |
|---|---|---|
| `bootmodes=('bios.syslinux' 'uefi.systemd-boot.esp')` | 老版 archiso 旧式命名 | 改为 `<mode>.<loader>.<variant>` 三段式 |
| `proxysub` PyQt5 模块 | **Calamares 3.4.x 不支持 Python view** | 改为桌面启动器用 kdialog 弹窗（见 5b 节） |
| `plasmalnf` | 是真模块，但在本方案无意义 | 移除（见第 5 节） |
| exec 里没有 `hwdetect` | 方案第 1 节要求"硬件驱动检测" | 已补进 exec 序列 |
| `partition`（手动分区） | 与"自动全盘安装"矛盾 | 改为 `defaultFileSystemType: btrfs` + 子卷布局，用户只选盘 |

原方案想要的 UX 一样能保住：Live 桌面放个图标 → 跑 `archinstall --script`。

> ⚠️ **本目录当前状态**：`post-install.sh` 及全部 chroot 脚本是**安装器无关**的，
> 两条路线都能直接用。缺的是安装器那一层（Calamares 的 `settings.conf` +
> `proxysub/main.py`），因为它取决于你选哪条路 —— 所以我没写。
>
> `packages.x86_64` 里那三行 `calamares*` 已注释掉；走 archinstall 时删掉注释即可
> （`archinstall` 本身在官方 extra，不需要额外处理）。

---

## 2. 🔴 会静默失败：订阅链接 `http://18.162.158.218:80` 不是订阅

**实测：**

```
$ curl -s -w "HTTP:%{http_code} size:%{size_download} type:%{content_type}" http://18.162.158.218:80
HTTP:200 size:693 type:text/html

$ curl -s http://18.162.158.218:80 | head -c 200
<!doctype html><html lang="en"><head><meta charset="UTF-8"/><link rel="icon" href="/favicon.ico"/>...
```

返回的是 **693 字节的 HTML 网页**（看 favicon 和 `<div id="root">` 像是个 React 管理面板），
不是 Clash 配置。TPClash 拿到这个会解析失败，**透明代理一步都走不了**。

原方案 4.4 / 4.5 把它当默认订阅链接，4.7 直接 `tpclash install --config "$SUB"`。
按原样做出来的 ISO，代理功能是死的。

**已做的处理：**

`install-tpclash.sh` 加了预检 —— 检测到 HTML 直接报错退出，并提示
"多半是把管理面板地址填成了订阅地址"，同时打印拿到的前 80 字节便于你排查。

**你需要做的：** 找到真正的订阅 URL（通常是 `/sub`、`/clash`、`?token=` 之类路径），
在安装界面填进去。别再用这个地址。

---

## 3. 🔴 会静默失败：TPClash 的用法全是错的

原方案 4.2 把 `tpclash` 写进 `packages.x86_64` 当成 pacman 包 —— **会让 `mkarchiso`
直接失败**（仓库里没有这个包，我下过的三个官方 db 里都没有）。

实测上游（`github.com/mritd/tpclash` README）：

| 原方案 | 实际 |
|---|---|
| `tpclash` 是 pacman 包 | ❌ Go 二进制，从 GitHub Releases 下载 |
| `tpclash install --config X --yes` | ❌ 没有 `--yes`；真实是 `install --config <url>` |
| — | 安装结果：`/usr/local/bin/tpclash` + `/etc/systemd/system/tpclash.service` |
| — | 默认配置路径 `/etc/clash.yaml`，远程订阅用 `-c <url>` |
| — | TUN 模式需要 `/dev/net/tun` |

**已做的处理：** 重写为 `airootfs/usr/local/bin/install-tpclash.sh`，
带 3 个下载镜像（GitHub 直连 + 2 个国内加速）、HTML 预检、TUN 模块检查、
`--enable` 自动自启 + 实际连通性自检。

---

## 4. 🟡 会坏：`dms-greeter` 不存在

原方案 4.8："配置 greetd：`/etc/greetd/config.toml` 使用 `dms-greeter --command niri`"。

**实测（`archlinux.org/packages/extra/x86_64/dms-shell-niri` 与
`danklinux` 仓库 README）：**

> Includes the greeter functionality (**disabled in distro packages**)

DMS 官方在构建发行版包时**主动禁用了 greeter 功能**。所以 Arch 官方仓库的
`dms-shell` 包里没有 dms greeter，`dms greeter install` 不可用。

**已做的处理：** 改用 `greetd` + `greetd-tuigreet`（注意包名是
`greetd-tuigreet`，独立的 `tuigreet` 包不存在 —— 这是 preflight 抓出来的）。

顺带：原方案想要的"开机自启进 niri"用 greetd 的
`[security] initial_session = "niri-session"` 实现，比 tuigreet 折腾更直接。

**附带发现：** 原方案第 6 节让你验证"`dms-shell-niri`（官方 Extra）与
`shorin-dms-niri-git` 版本兼容" —— 这条现在不用验了，**`dms-shell-niri` 这个包
已经被移除**（1.5.3 的 split 包没了，现在只有 `dms-shell` 一个，自带 compositor）。

---

## 5. 🟡 `plasmalnf` —— 是真模块，但在这方案里没用

> **先更正我自己**：我第一版文档里说 `plasmalnf` 是"笔误 / 模块不存在 / 会让 Calamares
> 起不来"。**这是错的。** 我核了 Calamares 3.4.2 的源码树，62 个模块里确实有
> `plasmalnf`，其 `CMakeLists.txt` 在正常构建列表中。

它真实的作用（读 `src/modules/plasmalnf/plasmalnf.conf` 自带的注释）：

> The Plasma Look-and-Feel module allows selecting a Plasma Look-and-Feel ...
> This module should be used once in a view section (to get the UI) and once in
> the exec section (to apply the selection to the target user).

所以它是个**选 Plasma 主题**的模块。对本项目有两个问题：

1. **原方案只把它放在 show，没放在 exec** —— 按它自己的文档那样用是无效的，
   选了主题不会应用到目标系统。
2. **语义上就是多余的** —— 这个项目装完第一件事就是**把 Plasma 删掉换 Niri**，
   给一个即将被卸载的桌面选主题，没有意义。

**处理：** 已从 sequence 移除，并在 preflight 里加了检查（`settings.conf` 里再出现
`plasmalnf` 就报错）。如果你确实想保留一个 Plasma 主题选择页，告诉我，我加回去 ——
但要记得 show 和 exec 各放一次。

---

## 5b. 🔴 关键发现：Calamares 3.4.x 的 Python 接口不支持 view

原方案 4.5 的自定义模块：

```yaml
type: "view"        # ← 做不出来
interface: "python"
name: "proxysub"
```

**核了源码，这个组合是不被接受的。** `src/libcalamaresui/modulesystem/ModuleFactory.cpp`
的模块分发逻辑：

```cpp
if ( moduleDescriptor.type() == Type::View ) {
    if ( moduleDescriptor.interface() == Interface::QtPlugin )  m.reset( new ViewModule() );
    else  cError() << "Bad interface" << ...;          // ← python 在这里被拒
}
else if ( moduleDescriptor.type() == Type::Job ) {
    if      ( interface == Interface::QtPlugin ) m = new CppJobModule();
    else if ( interface == Interface::Process  ) m = new ProcessJobModule();
    else if ( interface == Interface::Python   ) m = new PythonJobModule();   // ← 只在 Job 分支
}
```

而 `PythonJobModule::type()` 的实现是**硬编码**的：

```cpp
Module::Type PythonJobModule::type() const { return Module::Type::Job; }
```

也就是说：**Python 接口只能写后台 job（无界面），不能写带输入框的页面。**
QML 视图模块（`welcomeq`/`summaryq`/`notesqml` 等）则是**编译进二进制**的 C++
`ViewStep`（`calamares_add_plugin(... TYPE viewmodule ... SHARED_LIB)`），
要加一个自定义输入页，就得写 C++ 继承 ViewStep 再重编一遍。

> 顺带澄清：你原文的 `interface: "python"` 这个值本身**没写错**（`dummypython/module.desc`
> 就是这么写的），错的是 `type` —— 那个模块是 `type: "job"`。

**处理：绕开这个限制，UX 不变。**

订阅输入改由 `airootfs/usr/local/bin/launch-installer.sh` 完成 —— 也就是你本来就有的
那个"双击安装"桌面图标，在拉起 Calamares **之前**用 `kdialog --inputbox` 弹窗：

```
双击「安装 Arch Linux」
   └─► kdialog 弹窗："粘贴 Clash 订阅链接（可留空）"
          └─► 立刻 curl 预检，返回 HTML 就提示"这是网页不是订阅"
                 └─► exec sudo calamares
```

- UX 和原方案设计的**一模一样**（装机前弹窗填订阅）
- 不需要写 C++ ViewStep，不需要 `WITH_PYTHONQT`，省掉 pybind11/pyqt5 构建依赖
- 少一个能出错的环节

代价：订阅输入发生在**进安装器之前**，而不是作为安装流程里的一个步骤。
实际体验没差别，甚至更好 —— 用户在填之前能先看到网络配置页确认网络通了。

## 6. 🟡 自相矛盾：分区方式

- 第 1 节说"**自动全盘安装**"
- 4.4 的 sequence 用的是 `partition`（**交互式手动分区**）

这两个对不上。而且方案还要 Btrfs 快照 —— `snapper` 要求 `/` 是**独立子卷**，
默认单卷布局下 `/` 是 subvol id 5，snapper 直接不工作。

**已做的处理：** `setup-snapper.sh` 改成先检测 `/` 的 fstype 和 subvolume ID，
不满足条件就**跳过并写清原因**，而不是让 `snapper create-config` 失败拖垮安装。
检测逻辑写在脚本里，装完看日志就知道为什么没生效。

---

## 7. 🟡 改了会更安全：删 KDE 的时序

原方案 4.9 的 service：

```ini
After=network-online.target
Before=display-manager.service graphical.target
ConditionPathExists=/etc/shorin-remove-kde
DefaultDependencies=no
```

**我把这个改掉了**，改成挂在 `multi-user.target`、`Before=` 拿掉、
`DefaultDependencies=no` 拿掉。理由：

1. `Before=display-manager.service` 意味着在 sddm 启动前删 KDE。
   但 sddm 正在运行时 `pacman -Rns` 删它所在包，风险很高 —— **一旦脚本中途失败，
   用户面对的是"完全没有图形界面"的砖机状态**。
2. `DefaultDependencies=no` + `WantedBy=multi-user.target` 的组合会让
   ordering 变得难以推理。
3. **关键：改不改，用户能看到的现象完全一样。** 你的方案本来就写了
   "不自动重启，通过 motd 和通知提示用户手动重启" —— 也就是说
   **本次启动用户看到的仍然是 KDE**。既然如此，就选不会砖的那条路。

**新增了两层保底：**

- `/var/lib/shorin-incomplete` —— post-install 任一关键步骤失败会留下它。
  首次启动时 `shorin-remove-kde.sh` 看到它就**中止并保留 KDE**，下个开机重试。
- `niri-session` 不存在时直接中止，不删 KDE。

**另外：** 删包改成**逐个删**（`pacman -Qq` 先探测存在再删），而不是一把
`pacman -Rns plasma-meta` —— 后者一旦某个包不存在会整条报错，而且容易连带删掉
niri/dms 需要的共享依赖（Qt6/XDG/Polkit）。

**孤儿依赖清理默认关闭**（`DO_ORPHAN_CLEAN=0`），你自己原方案里也写了
"首次测试建议禁用"，我把它做成了开关而不是删掉。系统稳了再开。

---

## 8. 🟡 双内核 × 闭源驱动的复杂度

原方案 4.8 让 post-install 装 NVIDIA 驱动。但你有 **两个内核**
（`linux-zen` + `linux-lts`），闭源模块要为**每个内核各编一份**，复杂度翻倍，
而且驱动问题往往只在真实硬件上暴露，虚拟机里 `hwdetect` 的结论不可靠。

**已做的处理：** `hw-drivers.sh` 默认**只装厂商中立开源栈**（Mesa / Vulkan / VA-API），
检测结果写进 `/var/lib/shorin-gpu` 和 `/var/log/shorin-drivers.log`，你照着它手动装。
想让它自动装闭源驱动，装系统前预置一个标记文件即可：

```bash
sudo touch /etc/shorin-install-proprietary-drivers
```

---

## 9. 🟡 `shorin-dms-niri-git` 会让安装跑很久

原方案第 6 节把它列为风险"能否编译"。实测数据比"可能失败"更具体：

```
shorin-dms-niri-git r137.8fb8468-2
Dependencies (77)  ← 大半是 AUR 的 -git 包
  需要编译的: bash-git, cava-git, dgop-git, kimageformats-git,
             powercurve, tuned-ppd-git, wl-clipboard-rs-git,
             xwayland-satellite-*, dsearch-bin, ...
```

**Rust + Go + C++ 全套，在 chroot 里编译。** 这不是"可能失败"，是
**必然很慢** —— ISO 安装跑一两个小时起步。

**已做的处理：** `post-install.sh` 里做成开关：

```bash
SHORIN_MODE=skeleton   # 默认：官方 dms-shell + niri，不装 shorin dotfiles
SHORIN_MODE=full       # 装 shorin-dms-niri-git，耗时长
```

建议**先用 skeleton 跑通全流程**，确认 niri 能进、greetd 正常、KDE 能删干净，
再开 full。`skel-config.sh` 里已经写了一份可用且自洽的最小 niri 配置，
保证 skeleton 模式下装完就能进桌面。

另外原方案 4.8 提的 `shorindms init` 非交互问题 —— **在 chroot 里以 root 跑它是错的**，
因为它写的是 `$HOME` 下的配置，而目标用户此时还不存在。
`skel-config.sh` 改成写 `/etc/skel`，用户创建时自动拷过去。

---

## 10. ⚪ 顺手修掉的包名失效问题

`preflight.sh` 拿当天官方数据库逐个核对，抓出这些：

| 原方案/初稿写的 | 实际情况 | 处理 |
|---|---|---|
| `tpclash` | 非 pacman 包 | 移除，改脚本安装 |
| `tuigreet` | 无此包 | → `greetd-tuigreet` |
| `mlocate` | 已废弃 | → `plocate` |
| `gdisk` | 无此包 | → `gptfdisk` |
| `mkinitcpio-videomode` / `-firmware` | 已并回主包 | 移除 |
| `libva-mesa-driver` | 已不存在（Mesa 自带 VA-API） | 移除 |
| `noto-fonts-cjk-extra` | 无此包 | 移除 |
| `ttf-wqy-microhei` | `wqy-microhei`（无 `ttf-` 前缀） | 改名 |
| `fcitx5-pinyin` / `fcitx5-unicode` | 非独立包，在 `fcitx5-chinese-addons` 里 | 移除 |
| `mesa-vulkan-drivers` | 无此包（`vulkan-radeon` 已覆盖） | 移除 |
| `dms-shell-niri` | 已移除，只剩 `dms-shell` | 改用 `dms-shell` |
| `sudoers` | 虚拟包，由 `sudo` 提供 | 移除 |
| `mkfat` | 在 `dosfstools` 里 | 移除 |
| `archlinuxcn-keyring` | 不在官方仓库 | 改为仅 `archlinux-keyring` |
| `bgrub` | 无此包 | 移除 |

`profiledef.sh` 的 `bootmodes` 也改了：原方案的 `'bios.syslinux'` /
`'uefi.systemd-boot.esp'` 是老版 archiso 的旧式命名，当前 archiso 已改为
`<mode>.<loader>.<variant>` 三段式，沿用旧名会直接报 `unknown boot mode`。

`file_permissions` 我第一版写崩了（数组语法错误），已重写。

---

## 11. 镜像源实测结果（2026-10-05）

原方案只给了名字没给 URL。实测：

| 源 | 官方仓库 | archlinuxcn |
|---|---|---|
| 中科大 `mirrors.ustc.edu.cn` | ✅ 206 | ✅ 206 |
| 阿里云 `mirrors.aliyun.com` | ✅ 206 | ✅ 206 |
| 华为云 `mirrors.huaweicloud.com` | ✅ 206 | ✅ 206 |
| 清华 TUNA `mirrors.tuna.tsinghua.edu.cn` | ✅ 206 | ✅ 206 |
| 北大 `mirrors.pku.edu.cn` | ✅ 206 | ❌ 不镜像 archlinuxcn |

注意 `mirrors.pku.edu.cn` 可用，`mirror.pku.edu.cn`（无 s）**不通**。
archlinuxcn 的路径结构是 `$arch/` 而不是 `$repo/os/$arch/`，两者不能混用同一个
mirrorlist 文件，所以拆成了 `mirrorlist` + `mirrorlist.archlinuxcn` 两个。

---

## 12. 下一步：构建与测试

> ⚠️ **访问不了 GitHub 的话，先看 [`无GitHub构建方案.md`](无GitHub构建方案.md)** ——
> 有不需要 GitHub 账号的 Docker 本地构建路线。

> 📄 **用 VMware + Ventoy 的话，直接看 [`测试与写盘-VMware-Ventoy.md`](测试与写盘-VMware-Ventoy.md)**，
> 里面有针对 VMware 的虚拟机设置（含 BIOS/UEFI 双测、Secure Boot 要关）
> 和 Ventoy 写盘步骤。

## 没有 Arch 机器？两条路

### 路线 A：GitHub Actions（推荐，什么都不用装）

只要一个浏览器 + GitHub 账号。仓库里已经带了
`.github/workflows/build-iso.yml`，它会在官方 `archlinux:base` 容器里把整条
流程跑完，然后把 ISO 作为 artifact 给你。

```bash
# 1. 解压后建个仓库推上去
cd archlive && git init && git add -A && git commit -m "archlive"
git remote add origin git@github.com:<你的用户名>/archlive.git
git push -u origin main

# 2. 打开 Actions 页面，点 "build-iso" -> Run workflow
#    shorin_mode 选 skeleton 或 full

# 3. 等 30~90 分钟，跑完在 Artifacts 里下载 archlinux-shorin-iso
```

推 `v*` 形式的 tag 也会自动触发。

> ⚠️ **磁盘**：GitHub 标准 runner 磁盘有限（约 14GB 可用），完整构建比较吃紧。
> workflow 里有一道磁盘体检，会在不够时发 warning。要更稳就用更大的 runner
> （组织设置里可选 `ubuntu-latest-4-cores` 之外的规格）或走路线 B。

### 路线 B：Docker（宿主机不用是 Arch，Windows/Mac 都行）

```bash
# 装好 Docker Desktop 后
bash build/docker-build.sh
SHORIN_MODE=full bash build/docker-build.sh
```

脚本会拉 `archlinux:base` 容器（`--privileged`，mkarchiso 需要），
在里面装依赖、编译、自检、构建，ISO 导出到 `build/docker-out/`。
顺带一提：脚本会**探测延迟自动选镜像源** —— 在国内用国内五源，海外用官方源，
不用手动切。

### 路线 C：有 Arch 机器

```bash
bash make.sh
# 或指定模式
SHORIN_MODE=full bash make.sh
BURN=/dev/sdX bash make.sh        # 构建完直接写 U 盘（会二次确认）
```

`build/use-mirror.sh {cn|official|auto}` 可手动切镜像源。

`make.sh` 会自动完成：环境检查 → 编译 Calamares → 预编译 AUR → 10 项自检 →
构建 ISO → 输出 SHA256 和虚拟机测试命令。跑之前会检查你是不是在 Arch 上、
是不是普通用户、磁盘够不够。

**手动分步：**

```bash
# 1. 在 Arch Linux 机器上
git clone <本目录> && cd archlive

# 2. 编译打过补丁的 Calamares —— 必须【普通用户】运行（makepkg 拒绝 root）
bash build/build-calamares.sh
#    10~25 分钟。这一步产出 airootfs/etc/pacman.d/build-repo/calamares-*.pkg.tar.zst
#    以及 repo-add 生成的 .db.tar.gz

# 3. 跑自检
bash build/preflight.sh .
#    期望：PREFLIGHT PASS（10 项全过）
#    若第 1 项报 "找不到 calamares" → 第 2 步没成功

# 4. 构建 ISO（需要 root）
sudo bash build/build.sh

# 5. 校验 Calamares 配置（可选，需要 node + js-yaml）
npm i js-yaml && node build/check-calamares.js airootfs/etc/calamares
```

**PKGBUILD 补丁内容**（`build/PKGBUILD.calamares-shorin`，已在源码 tarball 层面验证）：

```
官方 AUR skip 列表 vs 本项目 skip 列表
  官方 skip 但我们【解开】了:  initramfs, packagechooser
  我们额外 skip 的:          （无）
```

- `initramfs` 必解 —— 装完不重建 initramfs，新内核起不来
- `packagechooser` 必解 —— 原方案 sequence 里用了
- 源用官方 release tarball + sha256 校验（**已实测 sha256 与上游一致**），
  不走实时 git —— 呼应原方案第 7 节"AUR 投毒"的风险对策
- 去掉了 `WITH_PYTHONQT`（不再需要 Python 模块，见 5b 节），
  连带省掉 pybind11 / python-pyqt5 的构建依赖

构建完 **BIOS 和 UEFI 都要测**：

```bash
# UEFI
qemu-system-x86_64 -enable-kvm -m 8192 -smp 4 \
  -bios ovmf \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.fd \
  -cdrom out/archlinux-shorin-*.iso -boot d

# BIOS
qemu-system-x86_64 -enable-kvm -m 8192 -smp 4 \
  -cdrom out/archlinux-shorin-*.iso -boot d
```

### 装机后必查清单

| # | 检查项 | 怎么看 |
|---|---|---|
| 1 | niri 能不能进图形 | 重启后能否看到 DMS 界面 |
| 2 | greetd autologin 生效 | 无需登录直接进桌面 |
| 3 | KDE 是否删干净 | `pacman -Q | grep -i plasma` 应为空 |
| 4 | 代理是否通 | `curl -I https://www.google.com` |
| 5 | 快照是否生效 | `snapper list`（布局不对时会跳过，看日志） |
| 6 | 驱动是否正常 | `cat /var/lib/shorin-gpu` + `/var/log/shorin-drivers.log` |
| 7 | 双内核 initramfs | `ls /boot/initramfs-*` 应有两个 |
| 8 | 重启后是否进 niri | 第二次重启 |
| 9 | 有没有进图形失败的风险 | `/var/lib/shorin-incomplete` 不应存在 |

### 日志位置

```
/var/log/shorin-install.log       post-install 全流程
/var/log/shorin-remove-kde.log    删 KDE
/var/log/shorin-drivers.log       驱动检测
/var/lib/shorin-gpu               显卡 vendor/model
/var/lib/shorin-incomplete        存在 = 上次安装有失败项（会导致不删 KDE）
/var/lib/shorin-need-reboot       存在 = KDE 已删，建议重启
```

---

## 13. 还差什么

**必须你这边做的：**

1. **编译 Calamares**（`build/build-calamares.sh`）—— 需要一台 Arch 机器 + Qt6 开发包，
   沙箱里做不了。跑完第 9 项检查才会转绿。
2. **找到真正的订阅链接** —— `http://18.162.158.218:80` 返回的是 HTML 面板（见第 2 节）。
   `launch-installer.sh` 会在填完立刻预检并提示，但 URL 得你给。
3. **选 `SHORIN_MODE`** —— `skeleton`（默认，官方 dms-shell + niri，快）
   还是 `full`（装 shorin-dms-niri-git，编译 77 个 AUR 依赖，一两小时）。
   建议先跑通 skeleton。

**原方案第 8 节「生成 .img」只写了标题没写内容。** ISO 验证通过后写 U 盘：

```bash
# ⚠️ 确认设备名，别擦错盘
lsblk
dd if=out/archlinux-shorin-*.iso of=/dev/sdX bs=4M status=progress conv=fsync sync
```

要的话我可以补一个带校验（`sha256sum` + 回读验证）的写盘脚本。

---

## 附：本次核对的证据来源

- 官方包数据库：`mirrors.tuna.tsinghua.edu.cn/archlinux/{core,extra,multilib}/os/x86_64/*.db`
  （`last-modified: 2026-10-05 10:06:13 GMT`）
- `archlinux.org/packages/?q=calamares` → 0 results
- `archlinux.org/packages/extra/x86_64/dms-shell-niri` → 302（包已移除）
- `github.com/mritd/tpclash` README（`opusb/tpclash` 为 fork）
- `aur.archlinux.org/packages/shorin-dms-niri-git`（r137.8fb8468-2，77 依赖）
- `github.com/AvengeMedia/DankMaterialShell` / `danklinux` README（greeter 被禁用）
- `archlinux.org/packages/extra/x86_64/archinstall`（4.5-1）
- `github.com/archlinux/archinstall` 的 `schema.json`（archinstall 配置字段定义）
- 2026-07-30 Arch 停用 AUR 领养机制的公告报道

### 本轮（Calamares 源码级核对）

- `codeberg.org/Calamares/calamares` 分支 `calamares` 的源码树（经 Codeberg API）
  - `src/libcalamaresui/modulesystem/ModuleFactory.cpp` —— 模块类型分发表
  - `src/libcalamaresui/modulesystem/PythonJobModule.cpp` —— `type()` 硬编码返回 Job
  - `src/modules/`（62 个模块目录清单）
  - `src/modules/dummypython/module.desc` —— `type: "job"` / `interface: "python"` 的真实写法
  - `src/modules/plasmalnf/plasmalnf.conf` —— 该模块的实际用途（选 Plasma 主题）
  - `src/modules/contextualprocess/contextualprocess.conf`
  - `src/modules/interactiveterminal/CMakeLists.txt` —— `TYPE viewmodule`
- AUR `calamares` 的 PKGBUILD（3.4.2-2）：SKIP_MODULES 列表、缺 WITH_PYTHONQT
- 上游 release tarball `calamares-3.4.2.tar.gz`（4.9 MB，sha256 已实测匹配）
  —— 据此核对模块目录存在性、SKIP 列表差异、解开模块的额外依赖
