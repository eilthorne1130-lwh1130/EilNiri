# 输入法修复已执行但未生效 — 原因已定位：进度标记吞掉了修复

## 根因（已核实，与"执行了"的事实吻合）

`stage_done()` 按进度文件 `$BASE_DIR/.replicate_progress` 中的版本标记跳过阶段，而 `PROGRESS_VERSION` 仍是 `"v49"`（RHEL-install.sh:609，上轮修改遗漏了 bump）。你的测试机之前跑过 v49，因此这次 restore 中 **apps 阶段（ibus 安装/dconf/rime 配置）与 configs 阶段（启动器重写、config.kdl fcitx→ibus、EPEL 清理、壁纸修正）被当作"已完成"整体跳过**——上轮所有修复一行都没执行。

托盘无图标不是 waybar 的问题（config 已含 tray 模块）：输入法图标由 ibus-panel（ibus-ui-gtk3）随 ibus-daemon 启动注册，守护进程没起来自然没有图标。

（另请确认：Fedora 测试机上的脚本确实是修改后的副本——上轮改动只存在于这台开发机的仓库里，需要同步过去。）

## 修改内容（仍仅改 RHEL-install.sh）

1. **`PROGRESS_VERSION` v49 → v50**（附注释）：旧进度文件判定过期，restore 强制重跑 apps 与 configs 阶段，让 IME/壁纸/EPEL 修复真正落地。
2. **ibus 启动器 `log()` 增加落盘**：同时写 `~/.cache/eilniri-ime.log`（带时间戳，保留 stderr）。测试机上一条 `cat ~/.cache/eilniri-ime.log` 即可看到走了哪条启动路径、引擎是否激活，不再盲猜。

## 验证
`bash -n` 语法检查 + 重新提取 launcher 生成脚本做 `sh -n` 与内容检查。

## 你的操作步骤（Fedora 测试机）
1. 同步修改后的脚本过去，并确认版本：`grep -n 'PROGRESS_VERSION=' RHEL-install.sh` 应为 v50；
2. `sudo ./RHEL-install.sh restore`（可保险起见先 `sudo rm -f .replicate_progress`）——观察日志里 apps/configs 阶段确实重新执行（而非 "skipping"）；
3. **注销并重新登录 niri 会话（或重启）**——ibus 自启动与 IME 环境变量只在新会话生效；
4. 验证：托盘出现输入法图标；`pgrep -af ibus-daemon`；任意应用左 Shift 切中英；
5. 若仍失败，贴给我：`pgrep -af ibus-daemon; ibus engine; cat ~/.cache/eilniri-ime.log` 的输出。