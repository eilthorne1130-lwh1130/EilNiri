# EilNiri

在新装的 **Arch 系** / **RHEL 系** / **Debian 系**（Debian/Ubuntu）系统上**只运行一个脚本**即可还原完整的 Niri 桌面环境：包安装、niri/awww/satty 预编译或源码构建、waypaper pip 安装、rime-ice 词库部署、**登录管理器**、系统服务、显示器适配、配置部署全部自动完成，无需再手动安装或下载任何东西。**niri/awww 的 cargo 编译自动放到后台并行执行**，期间继续装包、部署配置，最后统一等待收尾，大幅压缩总等待时间。Arch 系与 Fedora 全量预编译安装、零 AUR 构建；Debian/Ubuntu 与 Rocky/Alma/CentOS Stream 上，niri 自动走官方预编译二进制或官方 vendored 源码离线编译。自动适配显示器、输入法中文组件可选、服务自启、字体渲染。

## 快速开始

```bash
# 1. 在当前 Arch 机器采集快照（普通用户运行，只读系统不改动）
./install.sh export

# 2. 把整个 EilNiri 目录带到新机器（git clone / U盘 任意方式）

# 3. 在新机器安装（需要 root；一个脚本搞定所有：包、niri/awww/satty、输入法词库、登录管理器、服务、配置）
sudo ./install.sh restore
#    完成后重启，直接进入登录界面 → niri 桌面

# 4. 回滚配置
sudo ./install.sh rollback
```

## 命令一览

| 命令 | 权限 | 说明 |
|---|---|---|
| `./install.sh export` | 普通用户 | 采集快照（系统零改动） |
| `./install.sh export --keep-typos` | 普通用户 | 保留配置原样，不修正已知笔误 |
| `sudo ./install.sh restore` | root | 显示 Logo → 安装桌面环境（fzf 交互） |
| `sudo ./install.sh restore --dry-run` | root | 预览模式，只打印不执行 |
| `./install.sh status` | 任意 | **查看后台编译进度**（restore 运行时在另一终端执行，支持 `watch -n 5 ./install.sh status`） |
| `sudo ./install.sh rollback` | root | 从备份快照恢复配置 |
| `./install.sh --help` | - | 查看帮助 |

## 包含内容

### 应用分组（fzf 勾选，默认全选，使用前可选中文组件）

| 分组 | 默认 | 内容 |
|---|---|---|
| 核心组件 | ✅ | niri waybar mako fuzzel kitty polkit-gnome xwayland-satellite xdg-desktop-portal-gnome wl-clipboard libnotify zsh |
| 锁屏/空闲 | ✅ | hyprlock hypridle |
| 壁纸 | ✅ | awww、waypaper (pip) |
| 剪贴板/截图 | ✅ | copyq satty |
| 媒体/亮度 | ✅ | playerctl brightnessctl |
| 音频 | ✅ | pipewire-pulse wireplumber |
| 输入法 | ✅ | fcitx5 全家 + rime + 雾凇拼音 |
| 字体 | ✅ | ttf-jetbrains-mono-nerd wqy-zenhei |
| 密钥环 | ✅ | gnome-keyring |
| 显示管理器 | ✅ 自动 | 自动安装并启用：Arch→ly；Debian/RHEL→lightdm（已装其他 DM 则保留并启用） |
| 系统服务 | 可选 | bluetooth / libvirtd / power-profiles-daemon |

### 配置采集（export 复制进 `config/`）

`~/.config/` 下：niri waybar mako（排 __pycache__）kitty hypr copyq satty waypaper fcitx5 fcitx environment.d xdg-desktop-portal gtk-3.0 gtk-4.0 fontconfig，以及家目录 `.pam_environment`。

额外捕获并修复 `/usr/bin/niri-session`（systemd 弃用警告）→ 存入 `config/.local/bin/`。

敏感数据（~/.ssh、keyring、token）不进入快照。

## restore 流程（共 10 步）

1. **Logo 展示** → **Pre-Flight**：Arch 系（pacman 并行下载 + Reflector CN 镜像优化 + keyring 刷新 + 系统更新）；RHEL 系（dnf upgrade）；Debian 系（apt-get update + 自动开启 Ubuntu universe + upgrade，确保 curl/tar/unzip）
2. **目标用户检测**：默认 UID 1000，30s 超时可选创建新用户
3. **中文组件选择**：是否装输入法和中文字体 → fzf 应用选择 → 批量安装（失败自动逐个隔离，waypaper 走 pip）；**CN 时区自动启用 cargo/rustup 镜像（rsproxy.cn）**；niri/awww 的 cargo 编译**转入后台**（日志 `~/.local/state/eilNiri/{niri,awww}-build.log`）
4. **服务启用**：fzf 选择系统服务 → `systemctl enable --now`（后台编译同时进行）
5. **显示管理器**：自动安装并启用（Arch→ly；Debian/RHEL→lightdm，装不上自动依次尝试 sddm/gdm3；**已有 DM（如 Ubuntu Desktop 预装 gdm3 / display-manager.service 已配置）则保留**）——重启后直接进登录界面
6. **配置快照**：部署前将已有配置打包至 `backups/`（tar.gz）
7. **配置部署**：已有文件自动备份为 `.bak-时间戳` → PipeWire 用户服务自启 → zsh 设为默认 shell
8. **等待后台构建**：轮询 niri/awww 编译进度（每 15s 显示已用时间 + **当前正在编译的 crate**，如 `Compiling smithay v0.4.0`）→ 编译完成后自动安装二进制到 `/usr/local/bin`；失败读取日志尾部进手动报告。**restore 运行时可在另一终端用 `./install.sh status` 实时查看每个构建的状态/耗时/当前编译项**（日志：`~/.local/state/eilNiri/{niri,awww}-build.log`，`tail -f` 可实时跟看）
9. **硬件适配**：自动检测显示器输出名+分辨率 → 修复 niri config → 注释 waybar 硬件 sink → GPU 驱动提示
10. **装后验证**：包对账 + 配置目录审计 → **汇总报告** → pacman 缓存清理

## RHEL 系支持

- 包名自动翻译（如 `ttf-jetbrains-mono-nerd` → `jetbrains-mono-nerd-fonts`）
- 无 RPM 对应包自动走替代安装（awww 源码构建 / satty 预编译 / rime-ice 词库部署 / lightdm 登录管理器），只有全部失败才列入手动安装报告
- waypaper 走 pip3 兜底
- **Fedora**：niri / hyprlock / hypridle / xwayland-satellite 官方仓库都有，`dnf` 直接装
- **Rocky / Alma / CentOS Stream**：这些包默认仓库没有——niri 自动回退官方预编译/源码编译安装；hyprlock/hypridle/xwayland-satellite 给出 EPEL / Copr / 手动指引
- **awww / satty**（全部 RHEL 系）：awww 自动从 Codeberg 源码构建（约 5 分钟）；satty 自动下载官方预编译二进制，不可用时回退 cargo 构建
- **登录管理器**：自动装并启用 `lightdm`（Fedora 仓库有；Rocky/Alma 需 EPEL，装不上会提示并给出 tty 方案）

## Debian 系支持（Debian 12/13 / Ubuntu 24.04+）

- **包名自动翻译**：

| Arch 包名 | Debian/Ubuntu 包名 |
|---|---|
| mako | mako-notifier |
| fcitx5-configtool | fcitx5-config-qt |
| fcitx5-gtk | fcitx5-frontend-all |
| fcitx5-qt | fcitx5-frontend-all |
| polkit-gnome | policykit-1-gnome（Ubuntu 24.04+/Debian 13+ 已改名；旧发行版自动回退 polkit-gnome） |
| ttf-jetbrains-mono-nerd | fonts-jetbrains-mono |
| wqy-zenhei | fonts-wqy-zenhei |
| libnotify | libnotify-bin |
| polkit-gnome | polkit-gnome |

- **Ubuntu universe 自动开启**：fuzzel / mako-notifier / waybar / fcitx5-rime / hyprlock 等全部在 universe 组件。Ubuntu Server / minimal / 云镜像默认不开 universe —— restore 的 Pre-Flight 会自动检测并开启（`add-apt-repository universe`），无需手动操作
- **Ubuntu 版本**：建议 24.04+。低于 24.04 时 Pre-Flight 会明确警告（22.04 等旧版仓库基本没有 niri 套件包）；26.04+ 的 universe 已自带 hyprlock / hypridle，会直接 apt 装成功
- **debconf 不卡流程**：Debian 系自动 `DEBIAN_FRONTEND=noninteractive`，apt 安装（如 libvirt）不会弹出交互提示
- **编译提速（后台并行 + 资源感知）**：niri/awww 的 `cargo build` 转入后台执行，期间脚本继续装服务、DM、配置，最后统一等待——Ubuntu（4 核）总等待从 ~25 分钟降到 ~12-15 分钟。编译并行度按内存自动限制（每任务约 1.5GB，防小 VM OOM；<8GB 内存时 awww 自动等 niri 完成再编译）。所有下载走 **GitHub 官方直连**（断点续传 + 重试 + 超时，失败自动重试一次并报告 curl 退出码）；CN 时区或 crates.io 不可达时自动启用 rsproxy.cn 的 cargo/rustup 镜像（仅影响 Rust 依赖拉取）。编译日志：`~/.local/state/eilNiri/{niri,awww,xwayland-satellite}-build.log`
- **niri 自动安装（分层策略）**：官方仓库无 niri 包。restore 时优先下载官方预编译二进制；若无预编译包（官方现已只发源码包），先用官方 `vendored-dependencies` 离线源码包（40MB，构建时无需网络）——**该大文件下载失败时自动降级为源码小 tarball（~1MB，独立临时文件防污染）+ 网络依赖构建**；解包后硬校验 `Cargo.toml` 存在才启动构建，内容异常直接进手动报告并附文件类型/大小诊断；后台并行编译（约 10-20 分钟）。
- **awww 自动安装**：无 .deb 也无预编译二进制，且上游已从 GitHub 迁到 Codeberg。restore 自动浅克隆 `codeberg.org/LGFae/awww` → 后台 `cargo build --release`（约 5 分钟）→ 安装 `awww` 与 `awww-daemon` 到 `/usr/local/bin`。
- **satty 自动安装**：无 .deb，但官方（Satty-org/Satty）发布预编译二进制。restore 直接走 `releases/latest/download` 稳定 URL（免 GitHub API，CN 更稳）下载 `satty-<arch>-unknown-linux-gnu.tar.gz`（x86_64/aarch64）→ 安装到 `/usr/local/bin`，并确保 GTK4/libadwaita/librsvg 运行时库；预编译不可用时回退 `cargo install`。
- **xwayland-satellite 自动安装**：Debian/Ubuntu 稳定仓库没有（Fedora 有），且**未发布到 crates.io**（已验证 404）。restore 自动装构建依赖（git/clang/libclang-dev/libxcb-cursor-dev）后 `cargo install --git`（官方 GitHub 仓库，约 3 分钟，日志带失败尾部），并顺带装 Xwayland。
- **polkit agent**：Ubuntu 24.04+/Debian 13+ 的包名已从 polkit-gnome 改为 `policykit-1-gnome`（自动映射，旧版自动回退）；niri 配置里的 agent 启动路径自动按家族改写（Arch `/usr/lib` ↔ Debian/RHEL `/usr/libexec`）。
- **hyprlock / hypridle / xwayland-satellite**：Debian/Ubuntu 稳定仓库没有（仅 Debian 13 backports、testing、Ubuntu 26.04+ 有前两者）。restore 会先尝试 apt 安装，失败则给出 backports / 手动编译提示。
- **PEP 668**：waypaper 的 pip 安装自动加 `--break-system-packages`（Debian/Ubuntu 默认阻止系统级 pip）。
- **服务提供包**：`libvirtd.service` 的提供包按家族映射（Debian 为 `libvirt-daemon-system`）。
- **rime-ice 雾凇拼音自动部署**：无 .deb，但官方发布 release zip（`full.zip`）——restore 自动从 GitHub 直连下载 → 解压复制到 `~/.local/share/fcitx5/rime`（fcitx5-rime 包提供引擎）。Arch 上仍走 archlinuxcn 包，不受影响。
- **登录管理器自动安装**：Debian/RHEL 自动装并启用 `lightdm` + `lightdm-gtk-greeter`；已装有 gdm/sddm 等则保留并确保启用。
- **ly**：仅 Arch 有包（自动安装）；Debian/RHEL 上由脚本改用 lightdm。
- **export 仅限 Arch**：快照的 pkglist 由 pacman 生成，export 只能在 Arch 参考机上运行（Ubuntu 上 restore 没问题，但快照必须来自 Arch）。

## 硬件自动适配

| 适配项 | 说明 |
|---|---|
| 显示器输出名 | 读 `/sys/class/drm` 检测 → 替换 niri config 的 output 配置 |
| 分辨率+刷新率 | 读首选 mode → 注入 config |
| 多余输出 | 多屏配置自动注释为 `/-output` |
| waybar sink | 硬件 ALSA sink 自动注释 |
| GPU 检测 | `lspci` → info 显示显卡型号 |
| niri-session | 修复 `import-environment` 弃用警告 |

## 产物结构

```
EilNiri/
├── install.sh
├── pkglist/          (official.txt, services.txt)
├── config/           (配置镜像 + .local/bin/niri-session)
├── backups/          (回滚快照 tar.gz)
├── .replicate_progress
└── README.md
```

## 系统要求

| | Arch 系 | RHEL 系 | Debian 系 |
|---|---|---|---|
| 包管理 | pacman | dnf | apt-get |
| 推荐版本 | 任意 | Fedora / Rocky / Alma / CentOS Stream | **Ubuntu 24.04+** / Debian 13（22.04 会警告） |
| universe 源 | - | - | Ubuntu 自动开启 |
| fzf | 自动安装 | 自动安装 | 自动安装 |
| root | restore/rollback 需要 | restore/rollback 需要 | restore/rollback 需要 |

## 注意事项

- **脚本版本**：`--help`、restore/export 开头都会显示 `v版本号`（当前 v1.4.4）——目标机器上先看版本号确认同步的是最新脚本（旧进度文件自动作废）
- Arch 系与 Fedora 预编译安装，无需 base-devel / yay；Debian/Ubuntu 与 Rocky/Alma/CentOS Stream 上 niri 离线源码编译（约 10-20 分钟）、awww 源码构建（约 5 分钟）均**在后台并行执行**，satty 走官方预编译二进制（不可用时 cargo 构建）
- 后台构建进行中若中断脚本，构建会一并终止，下次重跑自动重建（不残留孤儿进程）
- export 默认修正 niri config 两处笔误，live 配置不受影响
- 壁纸图片不在快照内
- 中断恢复：重跑自动跳过已完成阶段，删除 `.replicate_progress` 可强制全量重跑；**进度文件带脚本版本标记，旧版本脚本写的进度自动作废**（失败阶段不再标记完成，重跑自动重试，无需手动删文件）
- dry-run：不对系统做任何改动（唯一例外：fzf 是交互前提，dry-run 下也会实际安装）
- 临时文件在退出时自动清理（sudoers、构建目录、解包目录）
- 日志：`~/.local/state/eilNiri/replicate.log`，自动截断保留最近 800 行

## 参考

- 交互风格与视觉引擎：[SHORiN-KiWATA/shorin-arch-setup](https://github.com/SHORiN-KiWATA/shorin-arch-setup)
- 快照回滚设计：[ech678/NyxNiri](https://github.com/ech678/NyxNiri)
- 跨发行版思路：[nickjj/dotfriedrice](https://github.com/nickjj/dotfriedrice)

在这里向他/她们表示感谢
