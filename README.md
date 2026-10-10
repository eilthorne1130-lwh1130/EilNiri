# 🌟 EilNiri

<div align="center">

**零心智负担、优雅现代的 Linux [niri](https://github.com/niri-wm/niri) 滚动平铺式桌面一键部署套件**

[![License](https://img.shields.io/badge/License-GPL%203.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux-orange.svg)](#-支持的发行版矩阵)
[![Wayland](https://img.shields.io/badge/Wayland-niri%20wm-purple.svg)](https://github.com/niri-wm/niri)
[![Shell](https://img.shields.io/badge/Bash-%3E%3D%204.0-success.svg)](#-快速开始)

[✨ 核心特性](#-核心特性) • [💻 效果预览](#-效果预览) • [🚀 快速开始](#-快速开始) • [🔋 笔记本适配](#-笔记本扩展支持) • [⌨️ 快捷键速查](#️-niri-核心快捷键速查) • [❓ 常见排查](#-故障排查与日志)

</div>

---

## 💻 效果预览

EilNiri 致力于在全新的 Linux 系统上，全自动安装并调校好基于 Wayland 的 **niri** 无限滚动平铺式窗口管理器环境。**无需任何前置准备**——装完重启，登录界面直接步入高颜值、现代化、开箱即用的工作区。

<div align="center">
  <img src="QQ图片20260713144149.jpeg" alt="EilNiri Desktop Preview" width="900" style="border-radius: 10px; box-shadow: 0 4px 16px rgba(0,0,0,0.2);" />
  <p><em>（毛玻璃半透明终端、美化 Waybar 状态栏、圆角几何设计、Fcitx5 中文输入法、精选壁纸）</em></p>
</div>

---

## ✨ 核心特性

- 🎯 **一键全自动化**：自动完成软件包安装、登录管理器（SDDM 自动配置接管）、硬件显示器参数自适应探测、中文输入法（Fcitx5 + 雾凇拼音）、壁纸与锁屏守护，开箱即用。
- 🌐 **跨三大 Linux 主流生态**：原生支持 **Debian/Ubuntu 系**、**Arch 系** 以及 **RHEL/Fedora/CentOS 系**，内置针对各发行版的包映射与安装策略。
- ⚡ **智能并发编译**：针对各发行版仓库缺失的无包组件（如 niri、awww 等），自动使用 Rust/Cargo 转入后台并行编译，前台同步进行包管理与环境配置，极大缩短等待时间。
- 🔋 **笔记本深度关怀**：配备独立的 `laptop-need-install.sh` 伴生脚本，自动侦测电池硬件并为 Waybar 幂等无缝注入电量（Battery）胶囊模块。
- 🇨🇳 **中文环境开箱即用**：全自动配置 Fcitx5 + Rime + 雾凇拼音词库，自动注入环境配置文件，单击左 `Shift` 顺畅切换中英文。
- 🛡️ **安全、幂等与断点续跑**：
  - **断点续跑**：中断后直接重新执行，已完成阶段自动跳过；
  - **配置安全**：修改或覆盖已有配置前自动生成带时间戳的 `.bak-*` 备份；
  - **非破坏性接管**：多桌面环境下仅禁用冲突守护进程（保留清单于 `.system_disabled`），可通过命令随时无损还原。
- 🌏 **国内网络自愈**：内置 GitHub 下载代理镜像回退、Rustup/Cargo rsproxy 镜像加速、apt 404 智能换源自愈以及虚拟机时钟偏差检测。
- 🖥️ **虚拟化环境智能预检**：内置 VM 图形预检机制，自动检测 QEMU/KVM/Virgl 3D 加速状态，防患黑屏于未然。

---

## 📦 支持的发行版矩阵

| 脚本 | 适用系统 | 状态与特点 |
|---|---|---|
| **`deb-install.sh`** | **Debian 12/13、Ubuntu 24.04+、Linux Mint、Pop!_OS**，以及 Deepin / UOS / Kali / MX / 麒麟等 Debian 衍生版 | ✅ **成熟主力（推荐首选）**<br>完整覆盖测试，预检、多源自愈与后台编译体验极佳 |
| **`arch-install.sh`** | **Arch Linux、Manjaro、EndeavourOS** | ⚙️ **官方支持**<br>官方源走 pacman，AUR 走 yay（缺失自动引导编译），配置快照同步 |
| **`RHEL-install.sh`** | **Fedora 40+、Rocky Linux、AlmaLinux、CentOS Stream、RHEL 9/10** | ⚙️ **深度适配（EL10 实测打通）**<br>Fedora 全组件官方仓库；针对 EL10 缺少 Wayland/fcitx5 生态 RPM 的痛点，全自动执行 CRB/EPEL 探测与全家桶源码编译兜底 |
| **`laptop-need-install.sh`** | **上述所有发行版的笔记本 / 带电池设备** | 🔋 **随需运行**<br>独立为已安装好的 Waybar 补装电量模块与 pill 样式，普通用户或 root 均可执行 |

> 💡 **新手推荐**：首次体验建议优先选用 Debian 13 或 Ubuntu 24.04+ 配合 `deb-install.sh`。

---

## 🚀 快速开始

### 1. 克隆仓库

在新装系统上打开终端（确保系统已安装 `git`）：

```bash
git clone https://github.com/eilthorne1130-lwh1130/EilNiri.git
cd EilNiri
```

### 2. 运行对应发行版安装脚本

#### 🐧 Debian / Ubuntu 系
```bash
# 完整交互安装（支持 --dry-run 预览计划）
sudo ./deb-install.sh restore
```

#### 🏹 Arch Linux 系
```bash
sudo ./arch-install.sh restore
```

#### 🎩 RHEL / Fedora / CentOS 系
```bash
sudo ./RHEL-install.sh restore
```

> **交互提示说明**：
> 运行过程中会有简单的交互界面（按 `回车` 即可使用推荐默认配置）：
> 1. **目标用户**：默认选择 UID 1000 用户；
> 2. **中文输入法**：是否启用 Fcitx5 + 雾凇拼音（默认是）；
> 3. **应用分组**：使用 fzf 勾选要安装的应用（默认全选，`Tab` 切换、`Enter` 确认）；
> 4. **系统服务**：勾选需随开机启动的系统服务（蓝牙 / libvirtd / 电源管理）。

### 3. 查看后台构建进度（可选）

对于 Debian 与 RHEL 系，niri / awww 等无包组件的 Cargo 编译在后台并行运行。若想实时查看进度，可在另一终端执行：

```bash
./deb-install.sh status        # 或 watch -n 5 ./deb-install.sh status
# RHEL 系同理：
./RHEL-install.sh status
```

### 4. 重启系统

安装流程完成后，重启系统即可在 SDDM 登录界面直接进入 Niri 桌面：

```bash
sudo reboot
```

---

## 🔋 笔记本扩展支持

如果你是在**笔记本电脑**或**带电池的外设环境**上使用，主安装脚本运行完毕后，可直接运行伴生脚本一键增强：

```bash
# 普通用户直接执行即可（也会在 root 运行时自动识别真实用户）
./laptop-need-install.sh

# 也支持预览模式
./laptop-need-install.sh --dry-run
```

**该脚本将自动完成**：
- 自动检测 `/sys/class/power_supply/` 下的电池硬件设备；
- 自动备份 `~/.config/waybar/config` 和 `style.css` 为 `*.bak-bat-<时间戳>`；
- 安全幂等注入 `battery` 状态定义及优雅的药丸外观；
- 根据电量自动呈现充电、警告、告急不同状态颜色。

---

## 🛠️ 命令与环境变量参考

### 脚本命令对比

| 命令 | 适用脚本 | 权限 | 功能描述 |
|---|---|---|---|
| `sudo ./<脚本>.sh restore` | 全部主脚本 | root | 完整执行安装与环境部署流程 |
| `sudo ./<脚本>.sh restore --dry-run` | 全部主脚本 | root | 预览执行计划，不实际更改系统 |
| `./<脚本>.sh status` | 全部主脚本 | 普通/root | 实时查看后台源码组件的编译状态与日志 |
| `sudo ./<脚本>.sh restore-system` | 全部主脚本 | root | 重新启用在安装期间为避免冲突而禁用的旧桌面组件 |
| `sudo ./deb-install.sh update` | `deb-install.sh` | root | 检查并升级 apt 包，若源码组件有上游更新则重新编译 |
| `./laptop-need-install.sh` | 笔记本脚本 | 普通/root | 为 Waybar 注入电量监测模块与样式 |
| `./<脚本>.sh --help` | 全部脚本 | - | 查看详细帮助与说明 |

### 环境变量

| 环境变量 | 默认值 | 作用与用法 |
|---|---|---|
| `EILNIRI_KEEP_DM=1` | 0 | 保留系统现有的显示管理器（如 gdm3/lightdm），不强制替换为 sddm |
| `EILNIRI_KEEP_SYS=1` | 0 | 跳过对其他桌面环境冲突守护进程的禁用操作（多桌面共存场景） |
| `EILNIRI_GH_PROXY="..."` | 内置4组代理 | 自定义 GitHub 下载代理加速镜像（空格分隔的 URL 列表） |

*示例：*
```bash
# 保留 Ubuntu 原生的 GDM 登录器进行安装
EILNIRI_KEEP_DM=1 sudo ./deb-install.sh restore
```

---

## 🧩 部署的应用与环境生态

<details open>
<summary><b>点击展开查看完整集成组件清单</b></summary>
<br>

| 类别 | 预装组件与工具 | 说明 |
|---|---|---|
| **核心合成器** | `niri` | 基于滚动平铺特性的 Wayland 窗口合成器 |
| **状态栏** | `waybar` | 现代化状态栏，集成工作区、媒体播放、网络、音量、时钟与折叠抽屉 |
| **通知中心** | `mako` | 轻量级 Wayland 桌面通知守护进程 |
| **应用启动器** | `fuzzel` | 极速 Wayland 原生应用启动菜单 |
| **终端模拟器** | `kitty` | GPU 加速终端，默认启用 85% 半透明毛玻璃与圆角 |
| **Shell & 提示符** | `zsh` + `oh-my-zsh` + `starship` | 集成语法高亮、自动建议插件及现代 CLI 工具（`eza`、`bat`、`zoxide`） |
| **中文输入法** | `fcitx5` + `fcitx5-rime` + `rime-ice` | 雾凇拼音词库，预置环境变量，左 Shift 一键切中英文 |
| **锁屏与空闲** | `hyprlock` + `hypridle` | 优雅的锁屏界面与自动休眠/灭屏管理 |
| **壁纸引擎** | `awww` + `waypaper` | 支持动态平滑切换的壁纸引擎，配套 GUI 壁纸选择器 |
| **剪贴板管理** | `copyq` + `wl-clipboard` | 强大的剪贴板历史管理器，已配置单实例与启动防呆 |
| **截图与标注** | `satty` + `grim` + `slurp` | 快捷区域截屏并直接唤起图形化画板进行标注、马赛克与保存 |
| **音频与媒体** | `pipewire` + `wireplumber` + `playerctl` | 现代低延迟音频架构及全局多媒体快捷键支持 |
| **蓝牙与系统** | `bluetui` + `brightnessctl` + `btop` | 蓝牙终端管理（点击 Waybar 蓝牙图标即开）、亮度调节与性能监控 |
| **字体资源** | `JetBrainsMono Nerd Font` + `文泉驿正黑` | 完美呈现 Nerd 图标字形与清晰的中文渲染 |

</details>

---

## ⌨️ niri 核心快捷键速查

`Mod` 键在物理机桌面下默认为 **`Super` (Windows 徽标键)**。

### 常用操作

| 快捷键 | 功能 |
|---|---|
| <kbd>Mod</kbd> + <kbd>W</kbd> | **打开终端**（Kitty + zsh） |
| <kbd>Mod</kbd> + <kbd>Z</kbd> | **应用启动器**（Fuzzel） |
| <kbd>Super</kbd> + <kbd>Ctrl</kbd> + <kbd>V</kbd> | **剪贴板历史**（CopyQ） |
| <kbd>Super</kbd> + <kbd>Alt</kbd> + <kbd>L</kbd> | **立即锁屏**（Hyprlock） |
| <kbd>Mod</kbd> + <kbd>Shift</kbd> + <kbd>S</kbd> | **区域截图**（框选后直接进入 Satty 标注保存） |
| <kbd>Ctrl</kbd> + <kbd>Print</kbd> | 全屏截图（保存到 `~/Pictures/Screenshots/`） |
| <kbd>Mod</kbd> + <kbd>Q</kbd> | **关闭当前窗口** |
| <kbd>Mod</kbd> + <kbd>Shift</kbd> + <kbd>?</kbd> | **打开快捷键帮助蒙版**（Overlay 帮助界面） |

### 窗口、分栏与布局控制

| 快捷键 | 功能 |
|---|---|
| <kbd>Mod</kbd> + <kbd>←</kbd> / <kbd>→</kbd> / <kbd>↑</kbd> / <kbd>↓</kbd> (或 <kbd>H</kbd>/<kbd>J</kbd>/<kbd>K</kbd>/<kbd>L</kbd>) | 移动窗口/分栏焦点 |
| <kbd>Mod</kbd> + <kbd>Ctrl</kbd> + 方向键 / HJKL | 在分栏间移动窗口位置 |
| <kbd>Mod</kbd> + <kbd>O</kbd> | **切换工作区概览**（Overview 缩放全览，或触摸板四指上滑） |
| <kbd>Mod</kbd> + <kbd>1</kbd> ~ <kbd>9</kbd> | 切换至指定编号的工作区 |
| <kbd>Mod</kbd> + <kbd>Ctrl</kbd> + <kbd>1</kbd> ~ <kbd>9</kbd> | 将当前列移动到指定编号的工作区 |
| <kbd>Mod</kbd> + <kbd>F</kbd> | 最大化当前列 |
| <kbd>Mod</kbd> + <kbd>Shift</kbd> + <kbd>F</kbd> | 当前窗口全屏（Fullscreen） |
| <kbd>Mod</kbd> + <kbd>V</kbd> | 切换窗口 **浮动 / 平铺** 状态 |
| <kbd>Mod</kbd> + <kbd>T</kbd> | 切换分栏 **标签页模式**（垂直折叠多标签） |
| <kbd>Mod</kbd> + <kbd>R</kbd> | 循环切换预设列宽（1/3 ➔ 1/2 ➔ 2/3） |
| <kbd>Mod</kbd> + <kbd>-</kbd> / <kbd>=</kbd> | 微调当前列宽（每次 ±10%） |
| <kbd>Mod</kbd> + <kbd>Shift</kbd> + <kbd>E</kbd> | 退出桌面会话（弹出确认对话框） |

---

## 🖥️ 虚拟机使用指南

niri 采用现代 GPU 渲染管线，**拒绝纯 CPU 软渲染（llvmpipe）**。如果您在虚拟机中测试体验，请注意以下关键配置：

### 推荐虚拟机配置

| 项目 | 推荐要求 | 说明 |
|---|---|---|
| **显卡模式** | **Virtio + 勾选 3D 加速（必需）** | 在 `virt-manager` 中显卡选 Virtio 并勾选「3D 加速」；SPICE 协议需开启 GL。纯 2D 显卡（QXL / std / bochs）无法运行 niri |
| **内存** | **≥ 4GB**（建议 8GB+） | 源码编译需要合理内存支持，脚本会依据内存量动态限制并发线程 |
| **处理器** | **≥ 2 核** | 保证多线程编译与窗口合成流畅 |
| **磁盘空间** | **≥ 25GB** 空闲 | 包含基础系统与源码编译产物所需缓存 |

> 🔍 **自动预检守护**：脚本每次运行都会自动执行 **VM Graphics Check**，读取内核日志判定 Virgl 3D 加速是否真正生效（**绿色**通过，**黄色**会提示先在宿主机开启 3D）。并且会自动在虚拟机内安装 `spice-vdagent`（剪贴板同步）和 `qemu-guest-agent`。

---

## ❓ 故障排查与日志

### 常见问题速查

- **登录后黑屏**：
  1. 虚拟机用户：请确认虚拟显卡是否为 **Virtio 且开启了 3D 加速**；
  2. 物理机或排查原因：切入 TTY 终端（<kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>F3</kbd>）查看错误日志：
     ```bash
     tail -n 50 ~/.local/state/eilNiri/session.log
     ```
  3. 获取自动生成的诊断包直接排查：`~/.local/state/eilNiri/diag-*.tar.gz`。
- **Waybar 出现双重栏位**：
  直接重新执行一次 `./<脚本>.sh restore`，内置的单实例守卫与链接修复会自动清理。
- **输入法未唤出**：
  确认已注销或重启会话以加载环境变量（已自动配置 `/etc/environment` 和 `~/.config/environment.d/`）；默认左 `Shift` 键切换中文。
- **替换默认壁纸**：
  仓库根目录的 `QQ图片20260713144149.jpeg` 是安装时的初始壁纸。换用自定义壁纸只需替换该图片重新跑一次 restore，或者进桌面后运行 `waypaper` 自由挑选。

### 关键日志路径

| 日志文件 | 内容说明 |
|---|---|
| `~/.local/state/eilNiri/replicate.log` | 主安装过程日志 |
| `~/.local/state/eilNiri/session.log` | niri 桌面会话运行日志（排查启动报错的第一现场） |
| `~/.local/state/eilNiri/{niri,awww}-build.log` | 后台 Cargo 编译日志（可通过 `tail -f` 追踪） |
| `~/.local/state/eilNiri/apt-errors.log` | （Debian 系）apt 安装失败底层日志 |
| `~/.local/state/eilNiri/diag-*.tar.gz` | 一键打包的系统与桌面诊断包 |

---

## 📂 仓库结构

```
EilNiri/
├── deb-install.sh              # Debian / Ubuntu 系一键安装脚本（成熟主力）
├── arch-install.sh             # Arch / Manjaro 系一键安装脚本
├── RHEL-install.sh             # RHEL / Fedora / CentOS 系一键安装脚本（含 EL10 深度兜底）
├── laptop-need-install.sh      # 笔记本 / 电池设备专用的 Waybar 电量模块补装脚本
├── configs/                    # 预置桌面配置模板快照
│   ├── .config/
│   │   ├── niri/               # niri 窗口管理器配置 (config.kdl)
│   │   ├── waybar/             # waybar 状态栏配置与美化 CSS
│   │   ├── hypr/               # hyprlock 锁屏与 hypridle 待机守护配置
│   │   ├── kitty/              # kitty 终端配置
│   │   ├── mako/               # mako 桌面通知配置
│   │   ├── fuzzel/             # fuzzel 启动器样式配置
│   │   ├── fcitx5/             # fcitx5 输入法与主题配置
│   │   ├── satty/              # satty 截图画板配置
│   │   └── ...
│   └── .zshrc                  # 预置 zsh 配置文件
├── QQ图片20260713144149.jpeg    # 初始预置壁纸（桌面与锁屏共用）
├── LICENSE                     # GPL-3.0 开源许可协议
└── README.md                   # 项目文档
```

---

## 💡 自定义配置技巧

- 如果你想将自己的配置（Dotfiles）固化到安装流程中，只需将配置放入 `configs/.config/<app_name>` 或 `configs/.local/share/`，脚本在 restore 阶段会自动同步部署；
- 脚本具备严格的安全机制，绝不会提交或同步隐私历史（如剪贴板历史、输入法词库记忆、最近文件等）；
- 配置文件中的路径推荐使用 `$HOME` 字面量，脚本部署时会自动将其解析为目标用户的实际家目录。

---

## 🤝 鸣谢与参考

- 交互风格与视觉引擎参考：[SHORiN-KiWATA/shorin-arch-setup](https://github.com/SHORiN-KiWATA/shorin-arch-setup)
- 跨发行版部署思路启发：[nickjj/dotfriedrice](https://github.com/nickjj/dotfriedrice)
- 现代滚动平铺合成器：[niri-wm/niri](https://github.com/niri-wm/niri)

## 📄 许可证

本项目采用 [GNU General Public License v3.0](LICENSE) 开源许可证。

---
<div align="center">
Made with ❤️ by <b>eilthorne</b> and contributors
</div>
