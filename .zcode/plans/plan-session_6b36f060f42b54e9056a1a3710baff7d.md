# RHEL-install.sh 修复计划（仅改 RHEL-install.sh，Fedora 平台验证，中英切换 = 左 Shift）

## 根因分析（已通读源码并联网核实）

### Bug 1：hyprlock 背景不是仓库那张图
- `_ensure_wallpaper()` 开头（:2253）`command -v awww || return 0` 早退。RHEL 系上 awww 无 RPM，`install_awww()`（:2221-2223）走后台 cargo 构建，二进制到 `stage_wait_builds`（在 `stage_configs` 之后）才安装。
- 首次安装时 `stage_configs` 里的 `_ensure_wallpaper` 必然因 awww 未就绪整体跳过 → 壁纸不复制、hyprlock.conf 的 `path =`（指向不存在的文件）不修正 → 锁屏背景错误。

### Bug 2：ibus 无法使用 / 快捷键（左 Shift 切中英文）无效
- 根因 A（主）：启动器 `eilniri-ime-session` 的 fallback `ibus-daemon -drxR`（:4201）——官方 ibus-daemon **没有 `-R` 选项**（仅 `-r --replace`），遇未知选项直接退出。当 `ibus start --type wayland` 失败时 fallback 也失败 → ibus-daemon 从未启动 → Shift/Ctrl+Space 一切无效。
- 根因 B：niri config.kdl:428 `Mod+W` 的 spawn-sh 内联 `QT_IM_MODULE=fcitx GTK_IM_MODULE=fcitx XMODIFIERS=@im=fcitx kitty -e zsh`，`_repoint_ime_env_config` 只改 `environment{}` 块 → kitty 及其子进程 fcitx 变量残留，ibus 失效。
- 根因 C：`_rime_ibus_write_custom`（:2963）写的 `default.custom.yaml` **没有** `ascii_composer/switch_key` 补丁——左 Shift 切中英文完全依赖 rime-ice 上游默认值；且函数"仅在文件不存在时写"，测试机上已生成的旧文件永远补不上。本仓库 fcitx5 时代的中英切换就是左 Shift（TriggerKeys=Shift+Shift_L），需在 rime 层显式固化，不依赖上游默认。
- 次要：launcher `select_engine` 用 `grep -qE '(^|[^a-z])rime$'` 探测，而 `ibus list-engine` 输出是 `name : longname`（行尾为 "Rime"）→ 探测常落空。

### Bug 3：Fedora 上 ibus-rime / copr(EPEL) 仓库报错
- `ensure_rhel_repos()`（:962）无 Fedora 分支：Fedora 上 epel.repo 不存在 → `dnf install epel-release` 失败 → 回退从 CN 镜像直装 **EL10 的 epel-release RPM** → epel.repo 的 `$releasever`=4x → 元数据 404 → 后续 dnf 事务被坏 repo 卡死 → ibus-rime 等大量安装失败 → 触发提及 ibus-rime/EPEL/COPR 的警告与降级链。
- 而 Fedora 官方源本就提供 ibus-rime、librime、librime-lua、brise，根本不需要 EPEL/COPR（其余 COPR 逻辑已用 `DISTRO_ID != fedora` 正确挡住，唯独这里没挡）。

## 修改内容（全部在 RHEL-install.sh）

1. **`_ensure_wallpaper()`**：删除 awww 早退——壁纸部署、awww 状态文件、waypaper/hyprlock 路径修正改为无条件执行（不依赖 awww 二进制；末尾 `awww-daemon set-wallpaper` 保留自带的 `-x` 存在性判断）。
2. **`stage_wait_builds()`**：awww 后台构建安装成功后补调一次 `_ensure_wallpaper`（幂等），保证 awww 就绪后状态文件与主动 set 生效（对齐 deb 脚本模式）。
3. **`_ibus_write_session_launcher()`**：
   - `ibus-daemon -drxR` → `ibus-daemon -drx`（去掉无效 `-R`，注释同步修正）；
   - `select_engine` 探测改 `grep -qw rime` / `grep -qw libpinyin`（词匹配）。
4. **`_repoint_ime_env_config()`**：新增一步——把 config.kdl 中含 `IM_MODULE=fcitx` / `XMODIFIERS=@im=fcitx` 的行（即 Mod+W 的 spawn-sh 内联变量）值替换为 ibus。
5. **`_rime_ibus_write_custom()`**：`default.custom.yaml` 模板显式固化左 Shift 切中英文：
   ```yaml
   ascii_composer/good_old_caps_lock: true
   ascii_composer/switch_key/Shift_L: commit_code   # 左 Shift 上屏并切英文
   ascii_composer/switch_key/Shift_R: commit_text
   ```
   对已存在但缺少 `switch_key` 补丁的旧文件：备份为 `.bak-<时间戳>` 后重写（该文件本由脚本生成，格式已知；用户自改文件含 switch_key 时不覆盖）。ibus 层 dconf 的 `trigger=['Control+space']` 保留为引擎级辅助切换，`Alt+Shift_L`/`Control+Shift_L`（带修饰键）不干扰单 Shift。
6. **`ensure_rhel_repos()`**：新增 Fedora 分支——跳过 EPEL 安装/自检/警告与 CRB 启用（Fedora 官方源全覆盖），保留 `-testing` 仓库禁用与 `dnf makecache`，输出一行说明日志；并自愈清理旧版脚本误装在 Fedora 上的 epel-release / `/etc/yum.repos.d/epel*.repo`（404 坏 repo），恢复 dnf 可用。

## 验证（Fedora 测试平台）
1. `bash -n RHEL-install.sh`；`sudo ./RHEL-install.sh restore --dry-run` 干跑。
2. 实机要点：
   - hyprlock.conf 的 `path =` 指向实际存在的 `~/.local/share/backgrounds/wallpaper.jpg`（首装、awww 尚在后台编译时也已部署）；
   - ibus-daemon 可启动（`pgrep ibus-daemon`），**在任意应用中按左 Shift 可上屏并切换中/英**，Ctrl+Space 可切引擎；
   - Mod+W 的 kitty 内 `env | grep -iE 'IM_MODULE|XMODIFIERS'` 全为 ibus；
   - `dnf repolist` 无 404 的 epel，`dnf install ibus-rime` 直接从官方源成功，无 copr/EPEL 报错；
   - `~/.config/ibus/rime/default.custom.yaml` 含 `ascii_composer/switch_key/Shift_L: commit_code`。

## 隐私说明
- 只改 RHEL-install.sh，不写入任何个人数据；脚本现有隐私防线（`is_privacy_risk` 拒绝部署 copyq 数据、*.db/*.sqlite/剪贴板历史等）保持不动。
- 提醒（不在改动范围）：`.zcode/plans/plan-sess_*.md` 已被 git 跟踪，疑似误提交的规划文档，建议自行决定是否移除。