# eilNiri

把当前机器的 **niri 桌面套件**（软件包 + 桌面配置 + 系统服务）采集为快照，在全新的 **Arch 系** / **RHEL 系** 系统上一键重现完全一致的桌面环境。

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
| 系统服务 | 勾选制 | bluetooth / dhcpcd / libvirtd / power-profiles-daemon（提供包缺失自动补装） |

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
- dhcpcd 不可用时提示改用 NetworkManager

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
