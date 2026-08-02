# EilNiri

在新装的 **Arch 系** / **RHEL 系** 系统上一键配置 Niri 桌面环境。全量预编译安装，零编译、零 AUR 构建。自动适配显示器、输入法中文组件可选、服务自启、字体渲染、TTY 英文模式。

## 快速开始

```bash
# 1. 在当前 Arch 机器采集快照（普通用户运行，只读系统不改动）
./install.sh export

# 2. 把整个 EilNiri 目录带到新机器（git clone / U盘 任意方式）

# 3. 在新机器安装（需要 root，显示 EilNiri Logo）
sudo ./install.sh restore

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
| 显示管理器 | ⬜ | ly（仅 Arch，默认不装） |
| 系统服务 | 可选 | bluetooth / libvirtd / power-profiles-daemon |

### 配置采集（export 复制进 `config/`）

`~/.config/` 下：niri waybar mako（排 __pycache__）kitty hypr copyq satty waypaper fcitx5 fcitx environment.d xdg-desktop-portal gtk-3.0 gtk-4.0 fontconfig，以及家目录 `.pam_environment`。

额外捕获并修复 `/usr/bin/niri-session`（systemd 弃用警告）→ 存入 `config/.local/bin/`。

敏感数据（~/.ssh、keyring、token）不进入快照。

## restore 流程（共 10 步）

1. **Logo 展示** → **Pre-Flight**：pacman 并行下载 + Reflector CN 镜像优化 + keyring 刷新 + 系统更新
2. **目标用户检测**：默认 UID 1000，30s 超时可选创建新用户
3. **中文组件选择**：是否装输入法和中文字体 → fzf 应用选择 → 批量安装（失败自动逐个隔离，waypaper 走 pip）
4. **服务启用**：fzf 选择系统服务 → `systemctl enable --now`
5. **显示管理器** ly（可选，默认 N）
6. **配置快照**：部署前将已有配置打包至 `backups/`（tar.gz）
7. **配置部署**：已有文件自动备份为 `.bak-时间戳` → PipeWire 用户服务自启 → zsh 设为默认 shell
8. **硬件适配**：自动检测显示器输出名+分辨率 → 修复 niri config → 注释 waybar 硬件 sink → GPU 驱动提示
9. **装后验证**：包对账 + 配置目录审计
10. **汇总报告** → pacman 缓存清理

## RHEL 系支持

- 包名自动翻译
- 无 RPM 对应包列入手动安装报告
- waypaper 走 pip3 兜底

## 硬件自动适配

| 适配项 | 说明 |
|---|---|
| 显示器输出名 | 读 `/sys/class/drm` 检测 → 替换 niri config 的 output 配置 |
| 分辨率+刷新率 | 读首选 mode → 注入 config |
| 多余输出 | 多屏配置自动注释为 `/-output` |
| waybar sink | 硬件 ALSA sink 自动注释 |
| GPU 检测 | `lspci` → info 显示显卡型号 |
| niri-session | 修复 `import-environment` 弃用警告 |

## TTY 支持

纯 TTY 下自动切换英文纯文本，避免乱码。`TTY_MODE=1` 可手动强制：

```bash
TTY_MODE=1 sudo ./install.sh restore
```

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

| | Arch 系 | RHEL 系 |
|---|---|---|
| 包管理 | pacman | dnf |
| fzf | 自动安装 | 自动安装 |
| root | restore/rollback 需要 | restore/rollback 需要 |

## 注意事项

- 预编译安装，无需 base-devel / yay
- export 默认修正 niri config 两处笔误，live 配置不受影响
- 壁纸图片不在快照内
- 中断恢复：重跑自动跳过已完成阶段，删除 `.replicate_progress` 可强制全量重跑
- dry-run：不对系统做任何改动
- 临时文件在退出时自动清理（sudoers、构建目录、解包目录）
- 日志：`~/.local/state/eilNiri/replicate.log`，自动截断保留最近 800 行

## 参考

- 交互风格与视觉引擎：[SHORiN-KiWATA/shorin-arch-setup](https://github.com/SHORiN-KiWATA/shorin-arch-setup)
- 快照回滚设计：[ech678/NyxNiri](https://github.com/ech678/NyxNiri)
- 跨发行版思路：[nickjj/dotfriedrice](https://github.com/nickjj/dotfriedrice)
