# Original User Request

## Initial Request — 2026-10-31T03:23:26Z

这是一个面向新手小白配置 Niri 平铺式窗口管理器的安装与配置仓库，需要阅读源码后修复 RHEL、Arch、Debian 及 laptop 电池模块脚本中的各项已知问题，并在本地 QEMU/KVM 虚拟机（Debian、Fedora、Arch）中测试并恢复快照，严禁改动本机配置且严格保护个人隐私。

Working directory: /home/eilthorne/EilNiri
Integrity mode: demo
The team must NOT: copy code from existing open-source projects for core logic

## Requirements

### R1. 取消 RHEL 与 Arch 脚本中的快照相关功能
由团队排查 `RHEL-install.sh` 与 `arch-install.sh` 源码中所有快照/备份相关逻辑（包括配置文件替换备份 `.bak-*` 机制与诊断快照包 `save_diag_bundle` 生成等），按要求全部取消并清理对应逻辑。

### R2. RHEL 脚本输入法改为 COPR FCITX5
将 RHEL 系脚本（`RHEL-install.sh`）中的 IBus 输入法完全修改移除；由团队排查并选择适用于对应 RHEL/Fedora 版本的稳定 COPR 仓库源，配置并启用 FCITX5 输入法。

### R3. 修复 Debian 截图编辑功能
排查并修复 `deb-install.sh` 中截图编辑无法正常使用的问题，由团队排查具体运行报错并选用最合适可靠的修复方案，确保在 Debian 桌面环境下截图与编辑功能正常运行。

### R4. 适配与验证 laptop 电池模块脚本
确保 `laptop-need-install.sh` 脚本在主脚本执行完毕后，能正常为有需要的笔记本用户向 Waybar 注入电量模块，且在所有目标发行版下均能正确配置并显示电量。

### R5. 本机保护与隐私安全限制
本机仅作为参考机，不得修改本机任何系统或用户配置；除本地测试虚拟机外，团队只能修改 `/home/eilthorne/EilNiri` 目录。必须严格执行隐私保护，任何个人隐私信息（如历史记录、个人数据等）绝对不得写入脚本、配置或 Git 仓库。全流程以中文回复。

### R6. 本地 QEMU/KVM 虚拟机集成测试与快照恢复
测试必须直接连接到本地 QEMU/KVM 虚拟机执行：
- Debian 虚拟机（debian13）：user 用户密码为 `lwh1130@`
- Fedora 虚拟机（fedora44）：user 用户密码为 `1`
- Arch 虚拟机（archlinux）：user 用户密码为 `1`
每次测试执行脚本完毕后，都必须将虚拟机恢复到预设的快照状态。各发行版主脚本及 laptop 脚本均需在对应的虚拟机干净状态下完整执行验证，确保退出码为 0 且服务状态正常。

## Acceptance Criteria

### 快照功能清理
- [ ] `RHEL-install.sh` 与 `arch-install.sh` 中的快照相关逻辑已全部取消，且脚本仍能正常运行。

### RHEL 输入法改造
- [ ] `RHEL-install.sh` 中 IBus 相关配置与安装逻辑已彻底移除。
- [ ] 成功配置 COPR FCITX5 仓库并安装必要组件，FCITX5 守护进程可正常启动、托盘显示正常且中英文切换可用。

### Debian 截图编辑
- [ ] `deb-install.sh` 修复后，Debian 虚拟机中截图编辑工具可正常触发、抓取并编辑截图。

### Laptop 电池模块
- [ ] `laptop-need-install.sh` 脚本在各系统虚拟机中执行无报错，Waybar 成功添加并正常加载 battery 模块。

### 本机与隐私安全
- [ ] 本机系统及 `/home/eilthorne/EilNiri` 外的所有文件未发生任何修改。
- [ ] 仓库文件及 Git 历史中无任何用户个人隐私信息泄露。

### 虚拟机自动化测试与快照
- [ ] 在 Debian 虚拟机中执行 `deb-install.sh` 与 `laptop-need-install.sh` 无报错退出。
- [ ] 在 Fedora 虚拟机中执行 `RHEL-install.sh` 与 `laptop-need-install.sh` 无报错退出。
- [ ] 在 Arch 虚拟机中执行 `arch-install.sh` 与 `laptop-need-install.sh` 无报错退出。
- [ ] 所有虚拟机在测试完成后均恢复至初始快照状态。
