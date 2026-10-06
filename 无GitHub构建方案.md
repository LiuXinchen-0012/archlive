# 三条构建路线

> 结论先说：**能做。** 即使访问不了 GitHub，Docker 本地路线也能出 ISO，
> 只是拿不到 `full` 模式的 Shorin dotfiles。

## 先选路线

| 路线 | 需要 | 产出 | 适合 |
|---|---|---|---|
| **A. Docker 本地** | Docker Desktop | 完整 ISO（GitHub 不通则自动降级 skeleton） | **你现在的情况** |
| **B. GitHub Actions** | GitHub 账号 | 完整 ISO（含 full 模式） | 以后能连 GitHub 再说 |
| **C. 别人的机器** | 一台能上网的 Linux | 完整 ISO | 有朋友/公司机器时 |

**三条路线共用同一份 profile**，随时可以换。GitHub Actions 的配置文件
(`.github/workflows/build-iso.yml`) 一直都在包里，没删。

---

## 如果你现在访问不了 GitHub

往下看第 2 节起的 Docker 方案。


## 为什么不是死路

我们实际要访问的站点，就四类：

| 站点 | 用来干什么 | 访问不到会怎样 |
|---|---|---|
| `codeberg.org` | **Calamares 源码** | ❌ ISO 里没有安装器，方案不成立 |
| `aur.archlinux.org` | AUR 的 PKGBUILD | ⚠️ 编不了 AUR 包 |
| 清华/中科大/阿里/华为/北大 | 全部官方包 | ❌ 系统装不起来 |
| `github.com` | AUR 包**源码** + TPClash 二进制 | ⚠️ 只有 full 模式和代理受影响 |

**Calamares 在 Codeberg，不在 GitHub。** 官方包走国内五源。真正卡住的只有 GitHub。

## 方案 A：Docker 本地构建（推荐）

**不需要 GitHub 账号、不需要推送代码。** 全部在你自己的 Windows 机器上做。

### 第 1 步：装 Docker Desktop

<https://www.docker.com/products/docker-desktop/>

### 第 2 步：配 Docker 镜像源（关键，国内不做这步会卡死）

`Settings → Docker Engine` → 粘贴 → `Apply & Restart`

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://hub.rat.dev"
  ]
}
```

### 第 3 步：构建

```bash
bash build/docker-build.sh
```

脚本开头会自动探测：Docker Hub 通不通、Codeberg 通不通、AUR 通不通、GitHub 通不通，
然后告诉你这个 ISO 能做到什么程度。

ISO 落在 `build/docker-out/`。

## 方案 B：拿到 GitHub 访问权

如果只是慢而不是完全不通，先试试：

```bash
bash build/github-access.sh check    # 探测
bash build/github-access.sh setup    # 配置 git 走加速镜像
```

`setup` 会实测哪个镜像能用，然后配置 `git config --global url."<镜像>".insteadOf`，
之后所有 `git clone https://github.com/...` 自动走镜像。

## GitHub 通不了的话，损失是什么

| | full 模式 | skeleton 模式 |
|---|---|---|
| `dms-shell` + `niri` + `matugen` + `cava` | ✅ | ✅ |
| 中文输入法 / 字体 | ✅ | ✅ |
| 我手写的最小 niri 配置（含工作区/快捷键/截图键） | ✅ | ✅ |
| **Shorin 的 dotfiles**（主题配色、按键布局、额外配置） | ✅ | ❌ |
| Shorin 的 `shorindms` CLI | ✅ | ❌ |
| 装完没有 Shorin | — | 桌面仍然能进，只是没那套 dotfiles |

**说白了：skeleton 是个能用的 niri + DMS 桌面，不是个坏掉的东西。**
Shorin 那个包本质上是 dotfiles + 一个装软件的脚本 + 一堆可选应用，
核心桌面（dms-shell、niri）在官方仓库里，不依赖 GitHub。

等你以后搞到访问办法了，`bash build/prebuild-aur.sh` 补编一次，
重新构建就变成 full 了 —— **前面那 20~40 分钟的编译不白费**。

## 方案 C：找一台能连 GitHub 的机器

- 朋友家 / 公司能上网的 Linux 机器
- 或者一台便宜的海外 VPS（但你说过没有服务器，这条对你不适用）

做法一样：把 `archlive/` 拷过去，`bash make.sh` 或 `bash build/docker-build.sh`。

