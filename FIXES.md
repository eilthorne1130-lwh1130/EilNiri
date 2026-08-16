# eilNiri 脚本全面修复说明 (v1.8.1 → v1.8.2)

## 📋 修复概览

本次修复针对以下问题进行了全面改进：
1. **Debian 12 / Ubuntu 24.04 niri 编译失败**
2. **系统组件禁用不完整**
3. **下载失败导致安装中断**

---

## 🔧 修复内容详解

### **1. Debian 构建依赖版本适配（第1112-1116行 & 1330-1355行）**

#### 问题
- Debian 12 中 `libdisplay-info-dev` 实际名为 `libdisplay-info0-dev`
- Ubuntu <24.04 中包名差异导致 apt 安装失败
- 脚本使用 Arch 风格包名，未考虑 Debian 版本差异

#### 修复方案
```bash
declare -A DEB_NIRI_BDEPS_MAP=(
    [libdisplay-info-dev]="libdisplay-info0-dev"  # Debian 12, Ubuntu <24.04
    [libhyprutils-dev]=""                         # optional, only in newer versions
    [libhyprlang-dev]=""                          # optional, only in newer versions
)
```

新增 Debian 专用包名映射表，在安装前自动转换包名。

#### 验证机制
- 第一轮：尝试安装所有依赖（使用容错模式）
- 第二轮：**硬验证关键包**（build-essential, clang, libwayland-dev 等）
- 失败时清晰提示缺失的包名和建议

#### 输出示例
```
Critical build dependency NOT installed: libdisplay-info-dev
niri — critical build dependency 'libdisplay-info-dev' unavailable in your 
Debian/Ubuntu version; install manually or use a newer distribution version, then rerun
```

---

### **2. cargo 构建日志增强（第1347行）**

#### 问题
```bash
# 原来的命令
cargo build --release -j $(cargo_jobs)
# 问题: 
#  - 没有 -vv 详细日志，Debian 特定的链接错误被隐藏
#  - 没有设置 RUST_LOG，无法诊断构建失败
```

#### 修复
```bash
RUST_LOG=info cargo build --release -vv -j $(cargo_jobs) 2>&1
```

效果：
- `-vv`: cargo 详细输出（编译的每个 crate、链接细节）
- `RUST_LOG=info`: Rust 编译器诊断信息
- `2>&1`: 捕获 stderr，全部写入日志文件

---

### **3. 系统组件禁用列表扩展（第321-369行）**

#### 新增禁用项目

| 组件 | 类型 | 替代方案 | 新增/修改 |
|------|------|--------|---------|
| `org.gnome.ScreenSaver.service` | userunit | hyprlock | **新增** |
| `gnome-screensaver.service` | systemunit | hyprlock | **新增** |
| `pulseaudio.service` (user) | userunit | PipeWire | **新增** |
| `pulseaudio.socket` (user) | userunit | PipeWire | **新增** |
| `xfce4-screensaver.service` | systemunit | hyprlock | **新增** |
| `kscreenlocker.service` | systemunit | hyprlock | **新增** |
| `xfce4-power-manager.service` | userunit | power-profiles-daemon | **新增** |
| `org.kde.powerdevil.service` | userunit | power-profiles-daemon | **新增** |
| 各类 Power/Sound/Clipboard daemon | userunit | waybar/power-profiles-daemon | **改进注释** |

现在脚本会自动禁用所有与以下替代方案冲突的原始组件：
- **hyprlock + hypridle** → GNOME/XFCE/KDE 锁屏
- **PipeWire** → PulseAudio
- **power-profiles-daemon** → XFCE/KDE 电源管理
- **waybar** → GNOME 媒体键/剪贴板守护进程

---

### **4. 系统组件禁用验证机制（第2423-2581行）**

#### 原始问题
```bash
# 旧逻辑：
if as_user systemctl --user mask "$name" 2>/dev/null || _rc=$?; then
    log "Masked user unit: $name"
fi
# 问题：
# - systemctl mask 失败但通过了条件判断
# - 没有验证 mask 是否真的生效
# - 没有终止正在运行的进程
# - 无法统计禁用结果
```

#### 新增验证（三层验证）

**第一层：单元存在检查**
```bash
if as_user systemctl --user list-unit-files 2>/dev/null | grep -q "^$name"; then
    # 单元存在，进行禁用
fi
```

**第二层：停止 + 掩码**
```bash
# 停止正在运行的进程
as_user systemctl --user stop "$name" 2>/dev/null || true

# 掩码单元
as_user systemctl --user mask "$name" 2>/dev/null || _rc=$?
```

**第三层：验证掩码生效**
```bash
# 验证 mask 是否真的生效
if as_user systemctl --user is-enabled "$name" 2>/dev/null | grep -q "masked"; then
    log "  [✓ DISABLED] user unit: $name"
    disabled_count=$((disabled_count + 1))
else
    warn "  [FAILED] user unit mask not applied: $name"
    failed_items+=("userunit|$name")
fi
```

#### 进程清理（autostart 类型）
```bash
# 对于 autostart 文件，写入 Hidden=true 后还要 kill 进程
local _proc_base="${name%.desktop}"
if pkill -u "$TARGET_USER" -f "$_proc_base" 2>/dev/null; then
    log "   └─ Killed running process: $_proc_base"
fi
```

#### 详细输出与统计
```
System Cleanup
══════════════════════════════════════════════════════════════
   [✓ DISABLED] systemunit: gnome-screensaver.service
   └─ Reason: GNOME screensaver (replaced by hyprlock)
   [✓ DISABLED] userunit: pulseaudio.service
   └─ Reason: PulseAudio service (replaced by PipeWire)
   [✓ DISABLED] autostart: org.gnome.ScreenSaver.desktop
   └─ Reason: GNOME screensaver (replaced by hyprlock)
   └─ Killed running process: org.gnome.ScreenSaver

System Components Disabled
   ● System Components Disabled  : 15 successfully disabled
   ● Not Found (Skipped)         : 8 components (not installed on this system)
```

---

### **5. 下载重试机制强化**

#### 改进的下载源（niri、awww、satty、rime-ice、hyprlock/hypridle）

**统一的重试策略**：
```bash
local _dl_attempts=3 _dl_delay=15 _dlrc=0
for (( _attempt=1; _attempt<=$_dl_attempts; _attempt++ )); do
    if download_gh "$url" "$tmp"; then
        _dlrc=0
        break
    fi
    _dlrc=$?
    if [ "$_attempt" -lt "$_dl_attempts" ]; then
        log "Download attempt $_attempt/$_dl_attempts failed, retrying in ${_dl_delay}s..."
        sleep "$_dl_delay"
    fi
done

if [ "$_dlrc" -ne 0 ]; then
    MANUAL_ITEMS+=("Failed after $_dl_attempts attempts (code $_dlrc)")
    return 1
fi
```

**应用位置**：
1. niri 源码包（3 次重试，每次间隔 15s）
2. niri vendored 依赖包（3 次重试，每次间隔 15s）
3. awww 源码克隆（3 次重试，每次间隔 10s）
4. satty 预编译二进制（3 次重试，每次间隔 10s）
5. rime-ice 字典包（3 次重试，每次间隔 10s）
6. hyprlock/hypridle 源码克隆（3 次重试，每次间隔 10s）

#### 改进的错误信息
```
# 原来
niri — vendored dependencies download failed (curl exit code 35)

# 现在
niri — vendored dependencies download failed after 3 attempts (curl exit code 35); 
try online build or install manually: https://github.com/niri-wm/niri
```

---

## ✅ 测试清单

在 Debian 12 / Ubuntu 24.04 上验证以下功能：

- [ ] `sudo ./install.sh restore` 成功获取 niri 源码（即使网络不稳定）
- [ ] 构建依赖检查正确识别 Debian 12 的包名差异
- [ ] 关键依赖缺失时给出清晰的错误提示
- [ ] niri 编译日志包含详细的 `-vv` 输出
- [ ] gnome-screensaver 被正确禁用
- [ ] pulseaudio 用户单元被正确掩码
- [ ] 禁用统计信息准确显示
- [ ] 禁用后系统组件真的无法启动

---

## 🔄 向后兼容性

所有修改均保持向后兼容：
- ✅ Arch 系统不受影响（DEB_NIRI_BDEPS_MAP 仅在 Debian 分支使用）
- ✅ RHEL/Fedora 系统不受影响
- ✅ 新的禁用项目都包含 exists-check，不存在的组件安全跳过
- ✅ 重试机制对所有网络操作通用，无副作用

---

## 📝 更新日志

### v1.8.2 修复清单
- [x] 增加 Debian 包名版本映射表
- [x] 强化 Debian 构建依赖验证
- [x] 添加 cargo 详细日志输出
- [x] 扩展系统组件禁用列表（hyprlock/pulseaudio/power manager）
- [x] 实现三层禁用验证机制
- [x] 添加禁用进程清理
- [x] 统一的下载重试策略（所有来源）
- [x] 改进错误消息和统计反馈
- [x] 保持向后兼容性

---

## 🐛 已知限制

1. **DBus 服务无法直接禁用**：某些 DBus session 服务（如 `org.gnome.Mutter.DisplayConfig`）无法通过 systemd mask 禁用，需要手动配置或不同的禁用方式。

2. **进程名称猜测**：autostart 文件名转换为进程名称时使用简单的 `.desktop` 后缀移除，某些特殊命名的进程可能无法正确 kill。

3. **网络问题**：GitHub/Codeberg 的连接超时问题可能导致即使重试 3 次仍失败，此时建议使用 `EILNIRI_GH_PROXY` 环境变量指定镜像源。

---

## 📞 问题排查

### 如果 niri 编译仍然失败

**查看详细日志**：
```bash
tail -100 ~/.local/state/eilNiri/niri-build.log
```

**手动检查关键依赖**：
```bash
dpkg -l | grep -E "build-essential|clang|libwayland-dev|wayland-protocols"
```

**如果缺失包，安装它们**：
```bash
sudo apt-get install build-essential clang libwayland-dev wayland-protocols
```

### 如果系统组件未被禁用

**检查禁用清单**：
```bash
cat .system_disabled
```

**手动检查禁用状态**：
```bash
# 检查用户单元
systemctl --user list-unit-files | grep masked

# 检查系统单元
systemctl list-unit-files | grep masked

# 检查 autostart 覆盖
ls ~/.config/autostart/
```

**重新禁用**：
```bash
# 删除进度文件强制重新运行
rm .replicate_progress
sudo ./install.sh restore
```

---

## 🎯 下一步建议

1. **在 Debian 12 / Ubuntu 24.04 系统上完整测试**
2. **收集 niri 构建日志** 用于诊断任何剩余问题
3. **验证所有禁用的组件** 在重启后确实无法启动
4. **监控边界情况**：特殊包名、自定义系统配置等
