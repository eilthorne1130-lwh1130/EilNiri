# EilNiri

一键在全新的 Linux 系统上装好并配置 [niri](https://github.com/niri-wm/niri) 平铺式窗口管理器桌面：包安装、niri/awww/satty 等无包组件的安装、登录管理器（自动替换现有 DM）、显示器适配、中文输入法、壁纸、开机自启全部自动完成，**无需任何前置准备**——装完重启，登录界面直接进 niri 桌面。

---

## 一、选择你的发行版

| 脚本 | 适用发行版 | 状态 |
|---|---|---|
| **`deb-install.sh`** | Debian 12/13、Ubuntu 24.04+、Linux Mint、Pop!_OS，以及任意 Debian 衍生版（脚本自动识别 `/etc/debian_version`：deepin / UOS / Kali / MX / 麒麟等均可） | ✅ **可用（当前主力，完整测试）** |
| `arch-install.sh` | Arch / Manjaro / EndeavourOS | 🚧 **未完成开发**（WIP，可能无法完整工作，欢迎测试反馈） |
| `RHEL-install.sh` | Fedora / Rocky / Alma / CentOS Stream / RHEL | 🚧 **未完成开发**（WIP，可能无法完整工作，欢迎测试反馈） |

> **新手请直接用 `deb-install.sh`。** 另外两个脚本保留在仓库中供后续开发使用，尚未达到日用状态。

---

## 二、快速开始（Debian 系）

### 前置要求

| 项目 | 要求 |
|---|---|
| 系统 | 推荐 **Debian 13 / Ubuntu 24.04+**（Debian 12 可用，waybar 版本较旧会自动使用精简布局） |
| 权限 | root（`sudo`） |
| 网络 | 需要联网下载包与源码（国内网络已内置镜像与代理回退，见[网络](#七网络与镜像)） |
| 磁盘 | **≥ 6GB 空闲**（niri/awww 走源码编译，需要空间） |
| 虚拟机 | 显卡必须设为 **Virtio + 3D 加速**，否则 niri 无法运行（见[虚拟机使用指南](#八虚拟机使用指南)） |

### 安装步骤

```bash
# 1. 在新机器上 clone 仓库（没有 git 时先 sudo apt-get install -y git）
git clone https://github.com/eilthorne1130-lwh1130/EilNiri.git
cd EilNiri

# 2. 运行安装脚本
sudo ./deb-install.sh restore

# 3. 按提示完成交互（都有默认值，直接回车也能走完）
#    - 选择目标用户（默认 UID 1000 的用户）
#    - 是否安装中文输入法（fcitx5 + 雾凇拼音，默认是）
#    - fzf 界面勾选要装的应用（默认全选，TAB 切换、回车确认）
#    - fzf 界面勾选要启用的系统服务（bluetooth / libvirtd / power-profiles-daemon）

# 4. 等待完成。niri/awww 的编译在后台进行，可在另一个终端看进度：
./deb-install.sh status        # 或 watch -n 5 ./deb-install.sh status

# 5. 重启 → 登录界面 → 直接进 niri 桌面
sudo reboot
```

> **注意**：脚本会自动安装登录管理器（sddm）并**替换系统现有的 DM**（例如 Ubuntu 预装的 gdm3 会被禁用，不会被卸载）。想保留现有 DM，用 `EILNIRI_KEEP_DM=1 sudo ./deb-install.sh restore`。
>
> **断点续跑**：中断后直接重跑同一条命令，已完成的阶段自动跳过、失败的阶段自动重试。删除 `.replicate_progress` 文件可强制全量重跑。

---

## 三、命令一览

| 命令 | 权限 | 说明 |
|---|---|---|
| `sudo ./deb-install.sh restore` | root | 完整安装（fzf 交互） |
| `sudo ./deb-install.sh restore --dry-run` | root | 预览模式：只打印计划，不改动系统 |
| `./deb-install.sh status` | 任意 | **实时查看后台编译进度**（restore 运行时在另一终端执行，支持 `watch`） |
| `sudo ./deb-install.sh restore-system` | root | 重新启用 restore 时被禁用的其他桌面组件（多桌面环境场景） |
| `sudo ./deb-install.sh update` | root | 检查并更新软件：apt 包升级 + niri/awww/xwayland-satellite 源码组件有新版时重编译（fzf 勾选） |
| `./deb-install.sh --help` | - | 查看帮助 |

> Debian 系**没有** `rollback` 命令（配置覆盖前的本地备份以 `.bak-时间戳` 形式保留在原目录）。`rollback` 仅存在于 Arch / RHEL 脚本中。

## 四、环境变量

| 变量 | 作用 |
|---|---|
| `EILNIRI_KEEP_DM=1` | 保留现有显示管理器，不做替换 |
| `EILNIRI_KEEP_SYS=1` | 跳过禁用其他桌面组件（多桌面环境共存场景） |
| `EILNIRI_GH_PROXY="https://a/ https://b/"` | 覆盖默认的 GitHub 下载代理列表（空格分隔） |

---

## 五、安装了什么

### 应用分组（fzf 勾选，默认全选）

| 分组 | 内容 |
|---|---|
| 核心组件 | niri、waybar、mako（通知）、fuzzel（启动器）、kitty（终端）、polkit 认证代理、xwayland-satellite、xdg-desktop-portal、wl-clipboard、libnotify、zsh + oh-my-zsh（含 autosuggestions / syntax-highlighting 插件、starship 提示符、eza / bat）、gsimplecal、adwaita-icon-theme |
| 锁屏/空闲 | hyprlock、hypridle |
| 壁纸 | awww（wayland 壁纸引擎，源码编译）、waypaper（壁纸选择器） |
| 剪贴板/截图 | copyq、satty、grim、slurp |
| 媒体/亮度 | playerctl、brightnessctl、btop |
| 音频 | pipewire-pulse、wireplumber |
| 输入法（可选） | fcitx5 全家 + rime + 雾凇拼音词库（单击左 Shift 切中英文） |
| 字体 | JetBrainsMono Nerd Font（waybar 图标）、文泉驿正黑 |
| 密钥环 | gnome-keyring |
| 工具 | bluetui（蓝牙 TUI，waybar 蓝牙图标点击打开）、ripgrep、zoxide |

### 系统服务（fzf 可选）

bluetooth（蓝牙，bluetui 依赖）、libvirtd（虚拟机）、power-profiles-daemon（电源性能切换）。

### 登录管理器（自动）

自动安装 **sddm** 并设为默认（失败依次回退 gdm3 / gdm），默认会话设为 niri；现有 DM 自动禁用（不卸载）。重启后直接进 niri。

### 桌面配置

- 仓库 `configs/` 内置 niri / waybar / hypr（锁屏）/ mako / kitty / satty / fcitx5 / waypaper / systemd 用户单元等配置，restore 一并部署，已存在的文件自动备份为 `.bak-时间戳`
- **默认壁纸 = 仓库根目录那张图片**（`QQ图片20260713144149.jpeg`），桌面与锁屏（hyprlock）共用；想换默认壁纸，直接替换仓库根目录的图片文件再跑一次 restore
- waybar 使用与参考机同步的完整配置（媒体控件 / 折叠抽屉 / 系统更新计数）；旧版 waybar（< 0.10）自动使用兼容布局；**电量模块安装时按提示选择**（自动检测电池预填默认值，台式机选了也会被 waybar 自动隐藏）
- niri 显示器参数自动检测注入（分辨率来自 DRM 硬件报告）；登录时若显示器未变不会覆盖你手动调过的配置
- 启动防呆：waybar 单实例守卫（不会出现两条栏）、fcitx5 单实例、CopyQ 主窗口自动隐藏（无托盘环境不再弹出空白窗口）

---

## 六、安装过程会发生什么

1. **Pre-Flight**：apt 更新 + 自动开启 Ubuntu universe 源 + 修复破损 dpkg 状态 + 自动生成中文 locale + **VM 图形预检**（QEMU/KVM 下检测显卡/渲染节点并给出黑屏预防指引）+ Mesa 图形运行时安装
2. **目标用户检测**：默认 UID 1000 用户，30 秒内可选其他/新建
3. **应用安装**：按 fzf 勾选批量安装；无 .deb 的组件自动走预编译下载或源码编译；**niri / awww 的 cargo 编译转后台并行**，期间继续装包部署配置
4. **服务启用**：勾选的系统服务 `systemctl enable --now`
5. **显示管理器**：安装 sddm 并替换现有 DM，默认会话设为 niri，开机目标设为 graphical.target
6. **配置部署**：部署 `configs/` + 输入法环境变量（environment.d + /etc/environment）+ zsh/oh-my-zsh 运行时 + waybar/壁纸自愈
7. **系统清理**：自动**禁用（不卸载）**其他桌面环境的冲突组件（GNOME 通知/设置守护等），清单存 `.system_disabled`，可随时用 `restore-system` 恢复
8. **等待后台编译**：实时显示进度；完成后自动安装 niri/awww 二进制
9. **硬件适配**：检测所有已连接显示器 → 生成 output 配置（含真实分辨率）→ niri validate 校验，失败自动回滚
10. **验证收尾**：包对账 + 配置审计 + 启动链自检 + 汇总报告 + 生成诊断包

---

## 七、网络与镜像

- **GitHub 下载代理回退**：niri 源码、satty、bluetui、rime-ice 等下载优先 GitHub 直连，失败自动依次尝试国内代理（ghfast.top 等），可用 `EILNIRI_GH_PROXY` 覆盖
- **cargo/rustup 镜像**：国内时区自动启用 rsproxy.cn
- **apt 换源自愈**：apt 404 / 源失效时按 清华 → 阿里云 → 中科大 顺序询问换源，并验证新镜像确实同步了之前 404 的包
- **系统时钟偏差检测**：apt 报"Release 文件过期"时自动对比时钟，偏差 ≥ 3 天给出校准命令（VM 常见）
- **Ubuntu universe**：Server/minimal 镜像默认不开 universe（fuzzel/waybar/fcitx5-rime 都在里面），脚本自动开启并硬校验

---

## 八、虚拟机使用指南

在 QEMU/KVM 虚拟机里体验 niri 完全可行，但对虚拟机配置有硬性要求（niri 拒绝软件渲染）。**脚本会在每次 restore 开头运行 VM Graphics Check 自动检测并给出结论**，无需自己猜。

### 推荐虚拟机配置

| 项目 | 要求 | 说明 |
|---|---|---|
| 显卡 | **Virtio + 3D 加速（必需）** | virt-manager：显示 Virtio → 勾选"3D acceleration"；virsh：`<model type='virtio'><acceleration accel3d='yes'/>`。QXL/std/bochs 纯 2D 显卡**无法运行 niri** |
| 显示协议 | SPICE（virt-manager 默认） | virgl 输出需要 SPICE（配合远程查看器时开启 GL） |
| 内存 | ≥ 4GB（建议 8GB） | niri/awww 源码编译需要内存，脚本按内存自动限制编译并发 |
| CPU | ≥ 2 核 | |
| 磁盘 | ≥ 25GB | 系统本身 + 约 6GB 编译空间 |
| 蓝牙 | 无控制器 | 属正常：waybar 蓝牙图标不显示、bluetui 报超时都是因为 VM 没有蓝牙硬件，忽略即可 |

### 脚本为 VM 自动做的事

- **VM Graphics Check**：检测显卡型号 / DRM 设备 / 连接器（virtio 显示为 Virtual-1），并读内核日志判定 **virgl 3D 是否真正启用**（绿字=可以装；黄字=先去宿主机开 3D 再装）
- **Guest agent 自动安装**：spice-vdagent（宿主机↔VM 剪贴板共享、光标同步）+ qemu-guest-agent（宿主机管理通道）；物理机上自动跳过
- 会话日志：登录异常时切 TTY（`Ctrl+Alt+F3`）看 `~/.local/state/eilniri/session.log`

### VM 黑屏自查清单

1. 脚本开头 VM Graphics Check 是否黄字警告 3D 未启用？→ 宿主机关机开启 3D 后重试
2. 确认显卡模型是 Virtio（QXL/std/bochs 不行）
3. 切 TTY 看 `~/.local/state/eilniri/session.log` 末尾的 niri 报错
4. 把 `~/.local/state/eilNiri/diag-*.tar.gz` 诊断包发出来

---

## 九、故障排查

### 登录后黑屏

1. **虚拟机用户**：niri 硬性要求硬件渲染（拒绝 llvmpipe 软渲染），虚拟显卡必须是 **Virtio 且勾选 3D 加速**。脚本开头的 **VM Graphics Check** 会读取内核日志**直接判定 virgl 3D 是否启用**（绿字=已启用，黄字=未检测到、大概率黑屏），完整配置要求见[虚拟机使用指南](#八虚拟机使用指南)。
2. 切 TTY（`Ctrl+Alt+F3`）登录后查看会话日志：
   ```bash
   tail -n 50 ~/.local/state/eilniri/session.log
   ```
   niri 的报错（panic 原文）就在文件末尾。
3. 把诊断包发出来最快：`~/.local/state/eilNiri/diag-<时间戳>.tar.gz`（含编译日志、DM 状态、DRM 设备、journal 相关行、会话日志）。

### 其他常见项

| 现象 | 处理 |
|---|---|
| waybar 出现两条 | 重跑一次 restore（单实例守卫 + systemd 自启链接清理会自动修复） |
| 输入法候选异常 / Shift 不切换中文 | 确认装了输入法组件；重跑 restore 会重新写入 fcitx5 配置与输入法环境变量 |
| 壁纸不是仓库那张 | 确认 `~/.local/share/backgrounds/wallpaper.jpg` 存在；awww 编译失败时壁纸由 waypaper.service 在登录时恢复，重跑 restore 重试编译 |
| 包安装失败 | 看 `~/.local/state/eilNiri/apt-errors.log`（apt 真实报错都在这里） |
| 编译失败 | 看 `~/.local/state/eilNiri/{niri,awww}-build.log` 尾部；脚本结尾的 Summary 手动项会给出具体命令 |

### 日志位置

| 文件 | 内容 |
|---|---|
| `~/.local/state/eilNiri/replicate.log` | 主日志（保留最近 800 行） |
| `~/.local/state/eilNiri/apt-errors.log` | apt 安装真实报错 |
| `~/.local/state/eilNiri/{niri,awww}-build.log` | 后台编译日志（`tail -f` 实时看） |
| `~/.local/state/eilniri/session.log` | niri 会话日志（黑屏排查第一现场） |
| `~/.local/state/eilNiri/diag-*.tar.gz` | 诊断包（求助于人时直接分享这个） |

---

## 十、自定义配置

- `configs/` **不是必须的**——没有它 restore 也能跑（niri 用内置默认配置）
- 想用自己的 dotfiles：`configs/.config/` 下的每个目录对应目标机 `~/.config/<name>`；`configs/.local/share/` 对应 `~/.local/share/`
- 敏感数据（`~/.ssh`、token、keyring）不要放进 `configs/`
- 配置里的路径建议写成 `$HOME` 字面量（restore 时会展开为实际主目录）

---

## 十一、已知限制

- **Debian 系无 `rollback` 命令**（配置备份仅保留覆盖前的 `.bak-时间戳` 单份）
- **虚拟机必须开 3D 加速**，否则 niri 无法运行（niri 拒绝软件渲染，这是上游设计而非脚本问题）
- Debian 12 / Ubuntu 24.04 的 waybar 为 0.9.x 旧版，自动使用精简布局（无折叠抽屉/媒体模块）
- niri / awww 在 Debian 系走源码编译（约 10-20 分钟 + 5 分钟），需要 ≥ 6GB 磁盘与足够内存（编译并发按内存自动限制）
- `arch-install.sh` 与 `RHEL-install.sh` 为未完成开发状态，暂不提供支持

---

## 产物结构

```
EilNiri/
├── deb-install.sh      # Debian 系安装脚本（当前主力）
├── arch-install.sh     # Arch 系（🚧 未完成开发）
├── RHEL-install.sh     # RHEL 系（🚧 未完成开发）
├── configs/            # 桌面配置快照（部署到目标机 $HOME）
├── QQ图片20260713144149.jpeg   # 默认壁纸（桌面 + 锁屏共用）
├── LICENSE
└── README.md

# restore 运行后生成的文件（本目录内）
├── .replicate_progress # 断点续跑进度（删除即强制全量重跑；带版本标记，旧版自动作废）
└── .system_disabled    # 被禁用的其他桌面组件清单（restore-system 据此恢复）
```

## 参考

- 交互风格与视觉引擎：[SHORiN-KiWATA/shorin-arch-setup](https://github.com/SHORiN-KiWATA/shorin-arch-setup)
- 快照回滚设计（仅 Arch/RHEL）：[ech678/NyxNiri](https://github.com/ech678/NyxNiri)
- 跨发行版思路：[nickjj/dotfriedrice](https://github.com/nickjj/dotfriedrice)

## 贡献者

- **eilthorne** - 项目创建与维护

在这里向所有贡献者表示感谢
