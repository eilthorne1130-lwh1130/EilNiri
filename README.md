# eilNiri

在这台PC快速配置好niri配置

## 快速开始

```bash
# 1. 在当前 Arch 机器采集快照（普通用户运行，只读系统不改动）
./install.sh export

# 2. 把整个 EilNiri 目录带到新机器（git clone / U盘 / rsync 任意方式）

# 3. 在新机器重现桌面（需要 root，Arch/RHEL 系自动识别）
sudo ./install.sh restore

# 4. 部署前自动打快照；如需回滚（需要 root）
sudo ./install.sh rollback
```

## 命令一览

| 命令 | 权限 | 说明 |
|---|---|---|
| `./install.sh export` | 普通用户 | 采集快照：包清单 + 服务清单 + 配置镜像（系统零改动） |
| `./install.sh export --keep-typos` | 普通用户 | 导出时保留配置原样，不修正已知笔误 |
| `sudo ./install.sh restore` | root | 在新系统重现桌面（含交互式应用/服务选择） |
| `sudo ./install.sh restore --dry-run` | root | 只打印将执行的操作，不实际安装/启用/部署 |
| `sudo ./install.sh rollback` | root | 从已有备份快照恢复配置（fzf 单选，默认需确认） |
| `./install.sh --help` | - | 显示帮助 |

## 包含内容

### 应用分组（restore 时 fzf 勾选，默认全选）

| 分组 | 默认 | 内容 |
|---|---|---|
| 核心组件 | ✅ | niri waybar mako fuzzel kitty polkit-gnome xwayland-satellite xdg-desktop-portal-gnome wl-clipboard libnotify zsh |
| 锁屏/空闲 | ✅ | hyprlock hypridle |
| 壁纸 | ✅ | awww、waypaper (AUR) |
| 剪贴板/截图 | ✅ | copyq satty |
| 媒体/亮度 | ✅ | playerctl brightnessctl |
| 音频 | ✅ | pipewire-pulse wireplumber |
| 输入法 | ✅ | fcitx5 全家 + rime + 雾凇拼音 (AUR) |
| 字体 | ✅ | ttf-jetbrains-mono-nerd wqy-zenhei |
| 密钥环 | ✅ | gnome-keyring |
| 显示管理器 | ⬜ 可选 | ly（仅 Arch，默认不装，有 DM 冲突检测） |
| 系统服务 | 勾选制 | bluetooth / libvirtd / power-profiles-daemon（提供包缺失自动补装） |

交互方式：fzf 多选 —— **默认全选**，TAB 切换，Ctrl-A 全选，Ctrl-D 全不选，Enter 确认。

### 配置采集白名单（export 复制进 `config/`）

`~/.config/` 下：niri、waybar、mako（排除 `__pycache__`）、kitty、hypr、copyq、satty、waypaper、fcitx5、fcitx、environment.d、xdg-desktop-portal、gtk-3.0、gtk-4.0；家目录散文件：`.pam_environment`。

## restore 流程

1. **Pre-Flight**：Arch 系刷新 keyring + 全系统更新；RHEL 系 `dnf upgrade --refresh`
2. **目标用户检测**：默认 UID 1000，30s 超时自动选择；可选创建新用户（创建失败会重试）
3. **应用选择**（fzf）→ 安装：仓库包批量装（失败自动逐个隔离），AUR 包逐个装 + 重试 1 次（无 yay 自动编译安装 yay-bin）
4. **服务启用**（fzf，默认全选）→ 提供包补装 → `systemctl enable --now`（libvirtd 附带 sockets）
5. **显示管理器** ly（可选，默认 N）
6. **配置快照**：部署前把将被覆盖的现有配置打包到 `backups/`（tar.gz 回滚点）
7. **配置部署**：`config/` → 目标用户家目录，已有文件自动备份为 `.bak-时间戳`
8. **装后验证**：`pacman -T` / `rpm -q` 对账 + 关键配置目录审计
9. **汇总报告**：已安装 / 已跳过 / 已启用服务 / 失败 / 需手动安装清单

## RHEL 系支持

- 包名自动翻译（如 `ttf-jetbrains-mono-nerd` → `jetbrains-mono-nerd-fonts`、`pipewire-pulse` → `pipewire-pulseaudio`、`wqy-zenhei` → `wqy-zenhei-fonts`）
- 部分包无 RPM 对应：waypaper 走 `pip3 install --user` 兜底；awww / satty / rime-ice / ly 等列入**末尾"需手动安装"报告**并给出建议

## TTY 支持

在纯 TTY（linux console / 无 Wayland/X 的 SSH）下运行时**自动切换英文纯文本**，避免中文乱码。也可手动指定：

```bash
TTY_MODE=1 sudo ./install.sh restore   # 强制英文
TTY_MODE=0 ./install.sh export          # 强制中文
```

## 产物结构

```
EilNiri/
├── install.sh                # 主脚本（export / restore / rollback）
├── pkglist/                  # export 生成
│   ├── official.txt          # 官方仓库包清单（可手改）
│   ├── aur.txt               # AUR 包清单（可手改）
│   └── services.txt          # 已启用服务（格式: unit 提供包）
├── config/                   # export 生成的配置镜像
│   ├── .config/              # niri/waybar/kitty/mako/hypr/...
│   └── .pam_environment      # 输入法环境变量
├── backups/                  # restore 部署前自动创建的回滚快照（tar.gz）
├── .replicate_progress       # restore 断点续装状态文件
└── README.md
```

## 系统要求

| | Arch 系 | RHEL 系 (Fedora/CentOS/Rocky) |
|---|---|---|
| 包管理 | pacman + yay（自动安装） | dnf（无 RPM 对应包列入手动清单） |
| fzf | 自动安装（即使 dry-run 也会实际装，交互前提） | 自动安装 |
| root | restore / rollback 需要 | restore / rollback 需要 |

## 注意事项

- **export 笔误修正**：默认自动修正快照副本中 niri 配置的两处笔误（`swww-daemon`→`awww-daemon`、`authenntication`→`authentication`），live 配置不受影响；`--keep-typos` 可关闭
- **敏感数据**：`~/.ssh/`、keyring、token 等不进入快照
- **壁纸图片**：waypaper 配置引用的图片文件不在快照内，新机器需自行放置
- **断点续装**：restore 中断后重跑自动跳过已完成阶段；服务阶段有失败则不标记完成、下次重试；删除 `.replicate_progress` 强制全量重跑
- **dry-run**：不写进度文件、不写临时 sudoers、不部署配置；应用自动全选打印计划；汇总里"将装包/将启用服务"单独列出
- **临时文件回收**：sudoers 临时授权、yay 构建目录、回滚解包目录均在退出时自动清理（EXIT/INT/TERM 陷阱）
- **日志位置**：`~/.local/state/eilNiri/replicate.log`（sudo 下自动定位到真实用户家目录），自动截断保留最近 800 行

## 执行效果

在全新 Arch 机器 restore 完成后，重启登录 niri 即可获得：

- 一致的平铺布局、全部键位绑定
- waybar 顶栏 + mako 通知 + hyprlock 锁屏 + hypridle 空闲管理
- fcitx5 输入法（雾凇拼音）开箱可用
- 音量/亮度快捷键正常工作（playerctl、brightnessctl 就位）
- 部署前自动创建回滚点，随时可 `rollback` 还原

## 参考

- 交互风格与视觉引擎：[SHORiN-KiWATA/shorin-arch-setup](https://github.com/SHORiN-KiWATA/shorin-arch-setup)
- 快照回滚设计：[ech678/NyxNiri](https://github.com/ech678/NyxNiri)
- 跨发行版思路：[nickjj/dotfriedrice](https://github.com/nickjj/dotfriedrice)

在这里向作者鸣谢

如有错误欢迎提出，新人刚做请温柔指正，谢谢！！！
邮箱：eilthorne1130@gmail.com/eilthorne2025@outlook.com

---

## English Version

# eilNiri

Quickly set up a niri configuration on this PC.

## Quick Start

```bash
# 1. Capture a snapshot on the current Arch machine (run as a regular user, read-only, no system changes)
./install.sh export

# 2. Bring the whole EilNiri directory to the new machine (git clone / USB drive / rsync, any method)

# 3. Reproduce the desktop on the new machine (requires root, Arch/RHEL families auto-detected)
sudo ./install.sh restore

# 4. A snapshot is automatically taken before deployment; to roll back (requires root)
sudo ./install.sh rollback
```

## Command Overview

| Command | Privilege | Description |
|---|---|---|
| `./install.sh export` | Regular user | Capture snapshot: package list + service list + config mirror (zero system changes) |
| `./install.sh export --keep-typos` | Regular user | Keep configs as-is during export, do not fix known typos |
| `sudo ./install.sh restore` | root | Reproduce the desktop on a new system (with interactive app/service selection) |
| `sudo ./install.sh restore --dry-run` | root | Only print operations that would be performed, no actual install/enable/deploy |
| `sudo ./install.sh rollback` | root | Restore configs from an existing backup snapshot (fzf single-select, confirmation required by default) |
| `./install.sh --help` | - | Show help |

## Included Content

### App Groups (checked with fzf during restore, all selected by default)

| Group | Default | Content |
|---|---|---|
| Core components | ✅ | niri waybar mako fuzzel kitty polkit-gnome xwayland-satellite xdg-desktop-portal-gnome wl-clipboard libnotify zsh |
| Lock screen/Idle | ✅ | hyprlock hypridle |
| Wallpaper | ✅ | awww, waypaper (AUR) |
| Clipboard/Screenshot | ✅ | copyq satty |
| Media/Brightness | ✅ | playerctl brightnessctl |
| Audio | ✅ | pipewire-pulse wireplumber |
| Input method | ✅ | fcitx5 family + rime + Rime Ice (雾凇拼音, AUR) |
| Fonts | ✅ | ttf-jetbrains-mono-nerd wqy-zenhei |
| Keyring | ✅ | gnome-keyring |
| Display manager | ⬜ Optional | ly (Arch only, not installed by default, has DM conflict detection) |
| System services | Checkbox style | bluetooth / libvirtd / power-profiles-daemon (missing provider packages auto-installed) |

Interaction: fzf multi-select — **all selected by default**, TAB to toggle, Ctrl-A select all, Ctrl-D select none, Enter to confirm.

### Config Collection Whitelist (copied into `config/` by export)

Under `~/.config/`: niri, waybar, mako (excluding `__pycache__`), kitty, hypr, copyq, satty, waypaper, fcitx5, fcitx, environment.d, xdg-desktop-portal, gtk-3.0, gtk-4.0; loose files in home directory: `.pam_environment`.

## Restore Flow

1. **Pre-Flight**: on Arch, refresh keyring + full system update; on RHEL, `dnf upgrade --refresh`
2. **Target user detection**: default UID 1000, 30s timeout auto-select; optionally create a new user (creation retried on failure)
3. **App selection** (fzf) → install: repo packages installed in batch (failed ones isolated and retried one by one), AUR packages installed one by one with 1 retry (auto-builds and installs yay-bin if yay is missing)
4. **Service enable** (fzf, all selected by default) → provider packages installed as needed → `systemctl enable --now` (libvirtd includes sockets)
5. **Display manager** ly (optional, default N)
6. **Config snapshot**: existing configs that would be overwritten are packed into `backups/` before deployment (tar.gz rollback point)
7. **Config deployment**: `config/` → target user's home directory, existing files auto-backed up as `.bak-timestamp`
8. **Post-install verification**: `pacman -T` / `rpm -q` reconciliation + audit of key config directories
9. **Summary report**: installed / skipped / enabled services / failed / manual install list

## RHEL Family Support

- Automatic package name translation (e.g. `ttf-jetbrains-mono-nerd` → `jetbrains-mono-nerd-fonts`, `pipewire-pulse` → `pipewire-pulseaudio`, `wqy-zenhei` → `wqy-zenhei-fonts`)
- Some packages have no RPM equivalent: waypaper falls back to `pip3 install --user`; awww / satty / rime-ice / ly etc. are listed in the **"manual install required" report** at the end with suggestions

## TTY Support

When running in a pure TTY (linux console / SSH without Wayland/X), **English plain text is automatically used** to avoid garbled Chinese. You can also set it manually:

```bash
TTY_MODE=1 sudo ./install.sh restore   # Force English
TTY_MODE=0 ./install.sh export          # Force Chinese
```

## Output Structure

```
EilNiri/
├── install.sh                # Main script (export / restore / rollback)
├── pkglist/                  # Generated by export
│   ├── official.txt          # Official repo package list (editable)
│   ├── aur.txt               # AUR package list (editable)
│   └── services.txt          # Enabled services (format: unit provider-package)
├── config/                   # Config mirror generated by export
│   ├── .config/              # niri/waybar/kitty/mako/hypr/...
│   └── .pam_environment      # Input method environment variables
├── backups/                  # Rollback snapshots auto-created before restore deployment (tar.gz)
├── .replicate_progress       # Restore resume state file
└── README.md
```

## System Requirements

| | Arch family | RHEL family (Fedora/CentOS/Rocky) |
|---|---|---|
| Package management | pacman + yay (auto-installed) | dnf (packages with no RPM equivalent go to the manual list) |
| fzf | Auto-installed (actually installed even on dry-run, it's a prerequisite for interactivity) | Auto-installed |
| root | Required for restore / rollback | Required for restore / rollback |

## Notes

- **export typo fixes**: two typos in the niri config within the snapshot copy are fixed by default (`swww-daemon`→`awww-daemon`, `authenntication`→`authentication`); the live config is unaffected; `--keep-typos` disables this
- **Sensitive data**: `~/.ssh/`, keyrings, tokens etc. are not included in the snapshot
- **Wallpaper images**: image files referenced by the waypaper config are not in the snapshot; place them manually on the new machine
- **Resume**: re-running restore after an interruption automatically skips completed stages; a failed service stage is not marked complete and will be retried next run; delete `.replicate_progress` to force a full rerun
- **dry-run**: does not write progress files, temporary sudoers, or deploy configs; apps are all auto-selected and the plan is printed; "packages to install / services to enable" are listed separately in the summary
- **Temp file cleanup**: temporary sudoers grants, yay build dirs, and rollback extraction dirs are all cleaned up automatically on exit (EXIT/INT/TERM traps)
- **Log location**: `~/.local/state/eilNiri/replicate.log` (auto-located to the real user's home under sudo), auto-truncated to keep the latest 800 lines

## Result

After a restore completes on a fresh Arch machine, reboot and log in to niri to get:

- Consistent tiling layout and all keybindings
- waybar top bar + mako notifications + hyprlock lock screen + hypridle idle management
- fcitx5 input method (Rime Ice) ready to use out of the box
- Volume/brightness shortcuts working (playerctl, brightnessctl in place)
- Rollback point auto-created before deployment, `rollback` available anytime

## References

- Interaction style & visual engine: [SHORiN-KiWATA/shorin-arch-setup](https://github.com/SHORiN-KiWATA/shorin-arch-setup)
- Snapshot/rollback design: [ech678/NyxNiri](https://github.com/ech678/NyxNiri)
- Cross-distro approach: [nickjj/dotfriedrice](https://github.com/nickjj/dotfriedrice)

Special thanks to the authors here.

Please feel free to point out any errors — I'm a beginner, so please be gentle. Thank you!!!
Email: eilthorne1130@gmail.com/eilthorne2025@outlook.com
