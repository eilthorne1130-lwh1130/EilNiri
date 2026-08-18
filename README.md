# EilNiri

在新装的 **Arch 系** / **RHEL 系** / **Debian 系**（Debian/Ubuntu）系统上**只运行一个脚本**即可还原完整的 Niri 桌面环境：包安装（内置列表）、niri/awww/satty 预编译或源码构建、waypaper pip 安装、rime-ice 词库部署、**登录管理器（自动替换现有 DM）**、系统服务（内置列表 fzf 勾选）、显示器适配、配置部署（仓库内 `configs/`）全部自动完成，无需快照/export 流程。**niri/awww 的 cargo 编译自动放到后台并行执行**，期间继续装包、部署配置，最后统一等待收尾，大幅压缩总等待时间。Arch 系与 Fedora 全量预编译安装、零 AUR 构建；Debian/Ubuntu 与 Rocky/Alma/CentOS Stream 上，niri 自动走官方预编译二进制或官方 vendored 源码离线编译。自动适配显示器、输入法中文组件可选、服务自启、字体渲染。

## 快速开始

```bash
# 1. 在参考机（任意发行版，普通用户）收集桌面配置到仓库 configs/（自动修正笔误与 niri-session，完成后自检并提示 git 提交）
./install.sh collect-config

# 2. 用 git 云同步时，configs/ 必须提交（git clone 只传被跟踪的文件）：
git add configs && git commit -m "configs update" && git push
#    （或直接用 U盘/rsync 拷贝整个 EilNiri 目录）

# 3. 在新机器克隆/拷贝后安装（需要 root；一个脚本搞定所有：包、niri/awww/satty、输入法词库、登录管理器、服务、配置）
sudo ./install.sh restore
#    完成后重启，直接进入登录界面 → niri 桌面

# 4. 回滚配置
sudo ./install.sh rollback

# 5. 若想重新启用 restore 时被禁用的其他桌面组件（多桌面环境场景）
sudo ./install.sh restore-system
```

## 命令一览

| 命令 | 权限 | 说明 |
|---|---|---|
| `./install.sh collect-config` | 普通用户 | 收集本机桌面配置到仓库 `configs/`（任意发行版） |
| `sudo ./install.sh restore` | root | 显示 Logo → 安装桌面环境（fzf 交互） |
| `sudo ./install.sh restore --dry-run` | root | 预览模式，只打印不执行 |
| `./install.sh status` | 任意 | **查看后台编译进度**（restore 运行时在另一终端执行，支持 `watch -n 5 ./install.sh status`） |
| `sudo ./install.sh rollback` | root | 从备份（`backups/` tar.gz）恢复配置 |
| `sudo ./install.sh restore-system` | root | **重新启用 restore 时被禁用的其他桌面组件**（多桌面环境场景，基于 `.system_disabled` 清单） |
| `./install.sh --help` | - | 查看帮助 |

## 环境变量

| 变量 | 作用 |
|---|---|
| `EILNIRI_KEEP_DM=1` | 保留现有显示管理器不变，不做替换 |
| `EILNIRI_KEEP_SYS=1` | restore 跳过禁用其他桌面组件（多桌面环境场景） |
| `EILNIRI_GH_PROXY` | 空格分隔的 GitHub 代理 URL 列表，覆盖默认代理（见下文"网络"） |

## 包含内容

### 应用分组（fzf 勾选，默认全选，使用前可选中文组件）

| 分组 | 默认 | 内容 |
|---|---|---|
| 核心组件 | ✅ | niri waybar mako fuzzel kitty polkit-gnome xwayland-satellite xdg-desktop-portal-gnome xdg-desktop-portal-gtk wl-clipboard libnotify zsh（oh-my-zsh 及插件、starship、eza、bat 由脚本自动安装，见下方说明） |
| 锁屏/空闲 | ✅ | hyprlock hypridle |
| 壁纸 | ✅ | awww、waypaper (pip) |
| 剪贴板/截图 | ✅ | copyq satty grim slurp |
| 媒体/亮度 | ✅ | playerctl brightnessctl |
| 音频 | ✅ | pipewire-pulse wireplumber |
| 输入法 | ✅ | fcitx5 全家 + rime + 雾凇拼音 |
| 字体 | ✅ | ttf-jetbrains-mono-nerd wqy-zenhei |
| 密钥环 | ✅ | gnome-keyring |
| 显示管理器 | ✅ 自动 | 自动安装并**替换现有 DM**：Arch→ly；Debian/RHEL→gdm（gdm3 兜底，装不上自动尝试 sddm） |
| 系统服务 | 可选 | bluetooth / libvirtd / power-profiles-daemon |

### 配置采集（`collect-config` 复制进仓库 `configs/`）

`~/.config/` 下：niri waybar mako（排 __pycache__）kitty hypr copyq satty waypaper fcitx5 fcitx environment.d xdg-desktop-portal gtk-3.0 gtk-4.0 fontconfig systemd，以及家目录 `.pam_environment`、`.zshrc`。

额外捕获并修复 `/usr/bin/niri-session`（systemd 弃用警告）→ 存入 `configs/.local/bin/`；`systemd` 目录内的用户单元（如 waypaper 服务）也会被采集并在 restore 时启用。

敏感数据（~/.ssh、keyring、token）不进入 `configs/`。

## restore 流程（共 11 步）

1. **Logo 展示** → **Pre-Flight**：Arch 系（pacman 并行下载 + Reflector CN 镜像优化 + keyring 刷新 + 系统更新）；RHEL 系（dnf upgrade）；Debian 系（apt-get update + 自动开启 Ubuntu universe + upgrade，确保 curl/tar/unzip，并自动 `locale-gen` 生成 `zh_CN.UTF-8`/`en_US.UTF-8`）；**Debian 系自动修复破损的 dpkg 状态**（`dpkg --audit` 发现半完成包即 `dpkg --configure -a`，否则后续所有 apt 安装都会失败且报"unavailable"），**apt 错误统一写入 `~/.local/state/eilNiri/apt-errors.log`** 供排查
2. **目标用户检测**：默认 UID 1000，30s 超时可选创建新用户
3. **中文组件选择**：是否装输入法和中文字体 → fzf 应用选择 → 批量安装（失败自动逐个隔离，waypaper 走 pip）；**CN 时区自动启用 cargo/rustup 镜像（rsproxy.cn）**；niri/awww 的 cargo 编译**转入后台**（日志 `~/.local/state/eilNiri/{niri,awww}-build.log`）
4. **服务启用**：fzf 勾选内置服务（bluetooth / libvirtd / power-profiles-daemon，默认全选）→ `systemctl enable --now`（后台编译同时进行）
5. **显示管理器**：自动安装脚本选择的 DM 并**替换现有 DM**（Arch→ly；Debian/RHEL→gdm（gdm3 兜底），装不上自动尝试 sddm）——现有 DM（如 Ubuntu Desktop 预装 gdm3）会被自动禁用、`display-manager.service` 指向新 DM；**先装新的再禁旧的**，安装失败则保留现有 DM 不动；**默认启动目标自动设为 `graphical.target`**（否则重启只会进纯文本 tty、任何 DM 都不启动）；**gdm 默认会话自动设为 niri**（AccountsService `Session=niri` + 自动清除 `custom.conf` 的 `DefaultSession`/`AutomaticLogin` 覆盖 + 自动装/启 `accountsservice` + 重启 `accounts-daemon`；**每次 restore 幂等重检**——niri 后台构建晚完成也会被补上；否则登录会进系统默认桌面如 GNOME）；niri.desktop 同时安装到 `/usr/share/wayland-sessions/` 和 `/usr/local/share/wayland-sessions/` 确保所有 DM 都能发现；**若 niri.desktop 意外缺失（编译中断等），restore 自动从 GitHub 下载源码轻量修复（仅提取 niri.desktop，无需重新编译）**；`EILNIRI_KEEP_DM=1` 可保留现有 DM——重启后直接进 niri 登录
6. **配置快照**：部署前将已有配置打包至 `backups/`（tar.gz）
7. **配置部署**：已有文件自动备份为 `.bak-时间戳` → PipeWire 用户服务自启 → **waypaper 用户服务（waypaper.service + 定时换壁纸 timer）自启** → **fcitx5 选中时兜底写入 `~/.config/environment.d/ime.conf`（IME 环境变量；`.pam_environment` 在 Debian 12+/Ubuntu 22.04+ 已默认失效）** → zsh 设为默认 shell → **自动安装 oh-my-zsh 及所需运行时（starship / eza / bat；见下方"zsh / oh-my-zsh"）**
8. **系统清理（禁用其他桌面组件）**：目标机若有多套桌面环境（如 Ubuntu 预装 GNOME），自动**禁用（不卸载）**其他 DE 的冲突组件——通知 daemon（evolution-alarm-notify / xfce4-notifyd）、GNOME 设置守护（媒体键/电源/声音/剪贴板）、gnome-remote-desktop。机制为写 `~/.config/autostart/*.desktop` 覆盖（`Hidden=true`）+ `systemctl mask`，**只禁用不删除任何包**；每次操作记录到 `$BASE_DIR/.system_disabled` 清单，可用 `./install.sh restore-system` 一键重新启用。`EILNIRI_KEEP_SYS=1` 跳过。
9. **等待后台构建**：轮询 niri/awww 编译进度（每 15s 显示已用时间 + **当前正在编译的 crate**，如 `Compiling smithay v0.4.0`）→ 编译完成后自动安装二进制到 `/usr/local/bin`；失败读取日志尾部进手动报告。**restore 运行时可在另一终端用 `./install.sh status` 实时查看每个构建的状态/耗时/当前编译项**（日志：`~/.local/state/eilNiri/{niri,awww}-build.log`，`tail -f` 可实时跟看）
10. **硬件适配**：自动检测显示器输出名+分辨率 → 修复 niri config → 注释 waybar 硬件 sink → polkit agent 路径按家族改写 → GPU 驱动提示
11. **装后验证**：包对账 + 配置目录审计 → **NIRI STATUS 单行**（binary/desktop/gdm Session）→ **Boot Environment Check**（若 gdm 无法启动 niri 会打印醒目 `BOOT CHECK FAILED` + 具体原因）→ **汇总报告** → 生成**诊断包** `~/.local/state/eilNiri/diag-<时间戳>.tar.gz`（含各 build 日志、AccountsService、custom.conf、包清单，便于分享排查）→ pacman 缓存清理

## RHEL 系支持

- 包名自动翻译（如 `ttf-jetbrains-mono-nerd` → `jetbrains-mono-nerd-fonts`）
- 无 RPM 对应包自动走替代安装（awww 源码构建 / satty 预编译 / rime-ice 词库部署 / gdm 登录管理器），只有全部失败才列入手动安装报告
- waypaper 走 pip3 兜底
- **Fedora**：niri / hyprlock / hypridle / xwayland-satellite 官方仓库都有，`dnf` 直接装
- **Rocky / Alma / CentOS Stream**：这些包默认仓库没有——niri 自动回退官方预编译/源码编译安装；hyprlock/hypridle/xwayland-satellite 给出 EPEL / Copr / 手动指引
- **awww / satty**（全部 RHEL 系）：awww 自动从 Codeberg 源码构建（约 5 分钟）；satty 自动下载官方预编译二进制，不可用时回退 cargo 构建
- **登录管理器**：自动装并启用 `gdm`（Fedora 仓库有 / gdm3 兜底；装不上会提示并给出 tty 方案）

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

- **Ubuntu universe 自动开启（硬校验）**：fuzzel / mako-notifier / waybar / fcitx5-rime / hyprlock 等全部在 universe 组件。Ubuntu Server / minimal / 云镜像默认不开 universe —— Pre-Flight 自动检测并开启（`add-apt-repository universe`，无该命令时直接改写 deb822 `.sources` 的 `Components` 行），开启后**必须能看到 universe 包才算成功**，否则明确警告并给出手动命令；构建依赖自愈时若发现候选 `-dev` 包不在 apt 列表（如 `libxcb-render-util0-dev` 这类 universe 包），也会自动重试启用 universe 后再装。
- **Ubuntu 版本**：建议 24.04+。低于 24.04 时 Pre-Flight 会明确警告（22.04 等旧版仓库基本没有 niri 套件包）；26.04+ 的 universe 已自带 hyprlock / hypridle，会直接 apt 装成功
- **debconf 不卡流程**：Debian 系自动 `DEBIAN_FRONTEND=noninteractive`，apt 安装（如 libvirt）不会弹出交互提示
- **编译提速（后台并行 + 资源感知）**：niri/awww 的 `cargo build` 转入后台执行，期间脚本继续装服务、DM、配置，最后统一等待——Ubuntu（4 核）总等待从 ~25 分钟降到 ~12-15 分钟。编译并行度按内存自动限制（每任务约 1.5GB，防小 VM OOM；<8GB 内存时 awww 自动等 niri 完成再编译）。编译日志：`~/.local/state/eilNiri/{niri,awww,xwayland-satellite}-build.log`
- **niri 自动安装（分层策略 + 多项可靠性修复）**：官方仓库无 niri 包。restore 时下载**源码小 tarball（~1MB）**后台 `cargo build --release`（依赖从 crates.io 拉取，rsproxy 镜像兜底；约 10-20 分钟）。**仅当任何 cargo 注册源都不可达时**才额外下载 40MB `vendored-dependencies` 归档离线构建（此路径的 `.cargo/config.toml` 使用绝对路径指向 vendored 目录，修掉了相对路径解析 bug）。构建依赖的按版本改名采用**运行时 `apt-cache policy` 探测 + 回退原名**（不再硬编码猜测，旧版错误的 `libdisplay-info-dev→libdisplay-info0-dev` 映射会让依赖被静默丢弃、编译 15 分钟后才报 `libdisplay-info.pc not found`）；**关键依赖硬校验**（build-essential/cmake/pkg-config/clang/libclang-dev/libwayland-dev/wayland-protocols/libpango1.0-dev/**libdisplay-info-dev/libxkbcommon-dev/libinput-dev**）缺失即明确报错中止，并把真实 apt 错误尾部带进报错信息；niri 的 pipewire 特性依赖 `libspa-sys`（bindgen），因此强制包含 `clang`/`libclang-dev`。**启动构建前做 pkg-config 预检**：一次性验证 build 需要的全部 23 个 `.pc` 文件（libdisplay-info/xkbcommon/wayland-client/libseat/pipewire/dbus/pango/gbm/egl/xcb-*），任一缺失几秒内即报错并进入手动报告，不再等 10-20 分钟。
- **hyprlock / hypridle 源码编译兜底**：Ubuntu 26.04+ 的 universe 已自带 hyprlock/hypridle（直接 apt 装）；**Debian 13 / 旧版 Ubuntu 无包时，restore 自动从源码构建**（`git clone` 官方仓库 + `cargo build --release` + 装 `/usr/local/bin`），不再只给手动提示。源码构建的 hyprlock 会**自动写入 `/etc/pam.d/hyprlock`**（apt 包自带 PAM，源码构建不会）。此兜底由 `SOURCE_PKGS` 表驱动，可扩展更多"仓库没有的包一律源码编译"。
- **awww 自动安装**：无 .deb 也无预编译二进制，且上游已从 GitHub 迁到 Codeberg。restore 自动浅克隆 `codeberg.org/LGFae/awww` → 后台 `cargo build --release`（约 5 分钟）→ 安装 `awww` 与 `awww-daemon` 到 `/usr/local/bin`。
- **satty 自动安装**：无 .deb，但官方（Satty-org/Satty）发布预编译二进制。restore 直接走 `releases/latest/download` 稳定 URL（免 GitHub API，CN 更稳）下载 `satty-<arch>-unknown-linux-gnu.tar.gz`（x86_64/aarch64）→ 安装到 `/usr/local/bin`，并确保 GTK4/libadwaita/librsvg 运行时库；预编译不可用时回退 `cargo install`。
- **xwayland-satellite 自动安装**：Debian/Ubuntu 稳定仓库没有（Fedora 有），且**未发布到 crates.io**（已验证 404）。restore 自动装构建依赖（git/clang/libclang-dev/libxcb-cursor-dev）后 `cargo install --git`（官方 GitHub 仓库，约 3 分钟，日志带失败尾部），并顺带装 Xwayland。
- **polkit agent**：Ubuntu 24.04+/Debian 13+ 的包名已从 polkit-gnome 改为 `policykit-1-gnome`（自动映射，旧版自动回退）；niri 配置里的 agent 启动路径自动按家族改写（Arch `/usr/lib` ↔ Debian/RHEL `/usr/libexec`）。
- **PEP 668**：waypaper 的 pip 安装自动加 `--break-system-packages`（Debian/Ubuntu 默认阻止系统级 pip）。
- **服务提供包**：`libvirtd.service` 的提供包按家族映射（Debian 为 `libvirt-daemon-system`）。
- **rime-ice 雾凇拼音自动部署**：无 .deb，但官方发布 release zip（`full.zip`）——restore 自动从 GitHub 直连下载 → 解压复制到 `~/.local/share/fcitx5/rime`（fcitx5-rime 包提供引擎）。Arch 上仍走 archlinuxcn 包，不受影响。
- **登录管理器自动安装**：Debian/RHEL 自动装并启用 `gdm`（gdm3 兜底）；现有 DM 被自动禁用替换，`EILNIRI_KEEP_DM=1` 可保留。
- **ly**：仅 Arch 有包（自动安装）；Debian/RHEL 上由脚本改用 gdm。
- **apt 镜像源自动换源（404 / 无法下载自愈）**：当 `apt-get update` 失败、或安装时 apt 报 `404`/`无法下载`/`Failed to fetch`（典型：`cn.archive.ubuntu.com` 等镜像同步滞后——索引里已有新版但 pool 里的 .deb 尚未同步，如 Ubuntu 26.04 的 `libudev-dev_259.5-0ubuntu3.3`、`libinput10 1.31.1-1`）时，脚本按 **tuna → 阿里云 → 中科大** 顺序询问并自动换源：备份原源文件（`*.mirror-bak-时间戳`）→ 改写 `.list`/`.sources` 里的 host → `apt-get update` → **用 curl 探测之前 404 的 .deb 是否真被新镜像同步**（只有显式 404 才换下一个候选）→ 换源成功后自动重试关键依赖一轮（带 `--fix-missing`）。fzf 可用时用 fzf 菜单选择，未装时退化为编号提示。手动报告只追加一次。
- **系统时钟偏差自动检测**：apt 报 `Release 文件已经过期 / expired / Valid-Until` 时（尤其是 `security.ubuntu.com` 这类官方源也报过期）通常不是镜像问题，而是**本地时钟偏快**（VM 常见）。脚本在 `apt-get update` 失败和关键依赖失败时会对比官方源 Last-Modified 与本地时间，偏差 ≥ 3 天即给出校准命令（`sudo timedatectl set-ntp true`），避免"换镜像也没用"的误导。
- **pkg-config 预检自愈**：启动 niri 后台编译前一次性验证全部 23 个 `.pc` 文件；缺失时（Debian 系）**自动安装对应的 -dev 包**（新旧命名都试，如 `libxcb-icccm4-dev` ↔ `libxcb-icccm-dev`，`apt-cache` 探测哪个存在装哪个），装完重新校验；仍缺则报出**具体缺失清单**，不再等到 15 分钟编译后报 "libdisplay-info.pc not found"。另有 `.pc` **命名分歧自动兼容**（Ubuntu 26.04 的 `libxcb-render-util0-dev` 装的是上游原名 `xcb-renderutil.pc`，与 Debian 系传统命名 `xcb-render-util.pc` 不同——脚本自动补双向符号链接），以及"包已装但 pkg-config 找不到"时自动把 `.pc` 所在目录加入 `PKG_CONFIG_PATH`。
- **Rust 工具链版本守卫**：`rustup` 工具链/默认版本缺失时防止静默使用发行版自带的过老 cargo（Debian 12 的 rustc 1.63、Ubuntu 22.04 的 1.75 编译 niri 会报 "edition 2024" 错误）。`ensure_rust` 校验 cargo ≥ 1.85，不足时自动 `rustup update stable` 重试一次，仍不满足则明确报错中止，不再用老工具链硬编译。

## zsh / oh-my-zsh（桌面终端体验）

- **自动安装 oh-my-zsh**：Debian/RHEL 的官方仓库都没有 oh-my-zsh 包（[Arch 参考机靠 AUR 才有](https://github.com/ohmyzsh/ohmyzsh)），参考机收集的 `configs/.zshrc` 也因此只在 Arch 上生效。restore 在 zsh 选中时自动以目标用户身份 `git clone --depth=1` 官方仓库到 `~/.oh-my-zsh`，跨 Arch/RHEL/Debian 三家一致生效。
- **OMZ 插件放到 `custom/plugins/`**：`zsh-autosuggestions` / `zsh-syntax-highlighting` 不再走 apt/dnf 包（它们装到 `/usr/share` 或 `/etc/zsh/zshrc.d`，OMZ 的 `plugins=()` 用不上），而是克隆到 `~/.oh-my-zsh/custom/plugins/` 供 .zshrc 插件表识别。
- **配套运行时自动装**：starship（`configs/.zshrc` 里 `init zsh` 依赖，官方脚本装到 `/usr/local/bin`）、eza（repo 优先，无包则 `cargo install --root /usr/local`）、bat（Debian/Ubuntu 上自动建 `bat`→`batcat` 符号链接）。
- **`.zshrc` 全防护**：`source $ZSH/oh-my-zsh.sh`、`starship init zsh`、eza/bat/rg 别名均改为"命令存在才加载"，参考机写死的 `/home/eilthorne` 绝对路径改为主目录相对（`$HOME`）；即使某个组件没装上，shell 也不会报错。
- 每步失败都会进入"手动安装报告"（MANUAL_ITEMS）并给出具体命令，不会静默抛错。

## 网络（CN 友好）

- **GitHub 下载代理回退**：所有源码/预编译 tarball（niri、satty、rime-ice、hyprlock/hypridle 等）优先走 GitHub 官方直连（断点续传 + 重试 + 超时）；**直连失败后自动依次尝试代理**（默认 `https://ghfast.top/`、`https://mirror.ghproxy.com/`），可用 `EILNIRI_GH_PROXY="https://proxyA/ https://proxyB/"` 覆盖。
- **cargo/rustup 镜像**：CN 时区或 crates.io 不可达时自动启用 **rsproxy.cn**（写入 `~/.cargo/config.toml`，并导出 `RUSTUP_DIST_SERVER`/`RUSTUP_UPDATE_ROOT`，让 rustup 工具链下载也走镜像）。CN 时区下始终预设 rsproxy。

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
├── configs/          (桌面配置镜像 + .local/bin/niri-session，collect-config 生成，随 git 走)
├── backups/          (回滚点 tar.gz)
├── .replicate_progress
├── .system_disabled  (restore 时禁用的其他桌面组件清单，restore-system 据此恢复)
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

- **脚本版本**：`--help`、restore/collect-config 开头都会显示 `v版本号`（当前 v1.9.9）——目标机器上先看版本号确认同步的是最新脚本（旧进度文件自动作废）
- **多桌面环境**：restore 会自动禁用（不卸载）其他 DE 的冲突组件（通知/设置守护等），清单存 `.system_disabled`；切回其他 DE 前用 `sudo ./install.sh restore-system` 重新启用，或 `EILNIRI_KEEP_SYS=1` 跳过禁用
- **诊断**：restore 结尾打印 `NIRI STATUS`（niri 二进制/desktop/gdm Session 三态）+ `Boot Environment Check`（gdm 是否真能启动 niri）+ 生成 `~/.local/state/eilNiri/diag-*.tar.gz` 诊断包（各 build 日志 + AccountsService + custom.conf + 包清单），排查时直接分享该包
- Arch 系与 Fedora 预编译安装，无需 base-devel / yay；Debian/Ubuntu 与 Rocky/Alma/CentOS Stream 上 niri 离线源码编译（约 10-20 分钟）、awww 源码构建（约 5 分钟）均**在后台并行执行**，satty 走官方预编译二进制（不可用时 cargo 构建）
- 后台构建进行中若中断脚本，构建会一并终止，下次重跑自动重建（不残留孤儿进程）
- collect-config 默认修正 niri config 两处笔误（swww-daemon→awww-daemon、authenntication→authentication），live 配置不受影响
- 壁纸图片不在 `configs/` 内
- 中断恢复：重跑自动跳过已完成阶段，删除 `.replicate_progress` 可强制全量重跑；**进度文件带脚本版本标记，旧版本脚本写的进度自动作废**（失败阶段不再标记完成，重跑自动重试，无需手动删文件）
- dry-run：不对系统做任何改动（唯一例外：fzf 是交互前提，dry-run 下也会实际安装）
- 临时文件在退出时自动清理（sudoers、构建目录、解包目录）
- 日志：`~/.local/state/eilNiri/replicate.log`，自动截断保留最近 800 行；**apt 报错单独记在 `~/.local/state/eilNiri/apt-errors.log`**（apt stderr 不再被丢弃，包装不上时能直接看到真实原因）

## 参考

- 交互风格与视觉引擎：[SHORiN-KiWATA/shorin-arch-setup](https://github.com/SHORiN-KiWATA/shorin-arch-setup)
- 快照回滚设计：[ech678/NyxNiri](https://github.com/ech678/NyxNiri)
- 跨发行版思路：[nickjj/dotfriedrice](https://github.com/nickjj/dotfriedrice)

## 贡献者

- **eilthorne** - 项目创建与维护
- **Claude** - Debian 12+ 编译修复、系统组件禁用完善、网络弹性改进；niri 依赖探测/硬校验与 pkg-config 预检、oh-my-zsh 并行安装与 .zshrc 防护、pre-flight dpkg 适配修复、apt 错误日志化

在这里向所有贡献者表示感谢
