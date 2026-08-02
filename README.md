# EilNiri

在新装的 **Arch 系** / **RHEL 系** 系统上快速配置 Niri 桌面环境。全量预编译安装，零编译、零 AUR 构建。

## 快速开始

```bash
# 1. 在当前 Arch 机器采集快照（普通用户运行，只读系统不改动）
./install.sh export

# 2. 把整个 EilNiri 目录带到新机器（git clone / U盘 任意方式）

# 3. 在新机器安装（需要 root）
sudo ./install.sh restore

# 4. 回滚配置
sudo ./install.sh rollback
```

## 命令一览

| 命令 | 权限 | 说明 |
|---|---|---|
| `./install.sh export` | 普通用户 | 采集快照（系统零改动） |
| `./install.sh export --keep-typos` | 普通用户 | 保留配置原样，不修正已知笔误 |
| `sudo ./install.sh restore` | root | 安装桌面环境（交互式 fzf 选择） |
| `sudo ./install.sh restore --dry-run` | root | 预览模式，只打印不执行 |
| `sudo ./install.sh rollback` | root | 从备份快照恢复配置 |
| `./install.sh --help` | - | 查看帮助 |

## 包含内容

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

交互方式：fzf 多选，使用前可选是否安装中文输入法和中文字体。

### 配置采集（export 复制进 `config/`）

`~/.config/` 下：niri waybar mako（排 __pycache__）kitty hypr copyq satty waypaper fcitx5 fcitx environment.d xdg-desktop-portal gtk-3.0 gtk-4.0，家目录散文件：`.pam_environment`。

敏感数据（~/.ssh、keyring、token）不进入快照。

## restore 流程

1. **Pre-Flight**：Arch 系刷新 keyring + 系统更新；RHEL 系 `dnf upgrade --refresh`
2. **目标用户检测**：默认 UID 1000，30s 超时可选创建新用户
3. **选择安装**：是否装中文输入法+中文字体 → fzf 选择应用 → 批量安装（失败自动逐个隔离，waypaper 走 pip）
4. **服务启用**：fzf 选择要启用的系统服务 → `systemctl enable --now`
5. **显示管理器** ly（可选，默认 N）
6. **配置快照**：部署前将已有配置打包至 `backups/`
7. **配置部署**：已有文件自动备份为 `.bak-时间戳`
8. **汇总报告**：已安装 / 已跳过 / 失败 / 需手动安装清单

## RHEL 系支持

- 包名自动翻译（`ttf-jetbrains-mono-nerd` → `jetbrains-mono-nerd-fonts`）
- 部分包无 RPM 对应列入手动安装报告并给出建议
- waypaper 走 pip3 兜底

## TTY 支持

纯 TTY 下**自动切换英文纯文本**，避免中文乱码。

```bash
TTY_MODE=1 sudo ./install.sh restore   # 强制英文
```

## 产物结构

```
EilNiri/
├── install.sh                # 主脚本
├── pkglist/
│   ├── official.txt          # 包清单（可手改）
│   └── services.txt          # 服务清单
├── config/                   # 配置镜像
├── backups/                  # 回滚快照（tar.gz）
├── .replicate_progress       # 断点续装状态
└── README.md
```

## 系统要求

| | Arch 系 | RHEL 系 |
|---|---|---|
| 包管理 | pacman | dnf |
| fzf | 自动安装 | 自动安装 |
| root | restore/rollback 需要 | restore/rollback 需要 |

## 注意事项

- export 默认修正 niri 配置两处笔误，live 配置不受影响
- 壁纸图片不在快照内，新机器需自行放置
- 中断恢复：重跑自动跳过已完成阶段，删除 `.replicate_progress` 可强制全量重跑
- dry-run：不写任何文件，不对系统做任何改动
- 临时文件在退出时自动清理
- 日志：`~/.local/state/eilNiri/replicate.log`，自动截断保留最近 800 行

## 参考

- 交互风格与视觉引擎：[SHORiN-KiWATA/shorin-arch-setup](https://github.com/SHORiN-KiWATA/shorin-arch-setup)
- 快照回滚设计：[ech678/NyxNiri](https://github.com/ech678/NyxNiri)
- 跨发行版思路：[nickjj/dotfriedrice](https://github.com/nickjj/dotfriedrice)
