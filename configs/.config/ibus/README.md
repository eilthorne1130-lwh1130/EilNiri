# Fcitx5 → IBus 输入法迁移说明（RHEL 系）

本目录是 **`RHEL-install.sh` 专用的输入法配置快照**，对应 Debian / Arch 两个脚本使用的
`configs/.config/fcitx5/`。原因很简单：**fcitx5 在 EL（Rocky / Alma / CentOS Stream / RHEL）
任何仓库里都没有包**，此前脚本不得不用源码编译整条链
（xcb-imdkit → fcitx5 core → gtk → qt → librime → leveldb/opencc/marisa → fcitx5-rime），
这正是"输入法编译有问题"的根源。改用 IBus 后，全部组件都是现成 RPM：

| 组件 | 来源 | 说明 |
|---|---|---|
| `ibus` `ibus-gtk3` `ibus-gtk4` `ibus-wayland` `ibus-panel` | AppStream（系统基础仓库；`ibus-panel` 在 EL10 属 CRB） | Fedora 与 EL 都有，无需 EPEL |
| `ibus-rime` + `librime` + `librime-lua` + `brise` | EPEL 10 / EPEL 8 / Fedora 官方 | Rime 引擎 + 词库基础方案；**EPEL 9 从未打包 `ibus-rime`/`librime`**（实测 2026-10） |
| `ibus-libpinyin` | AppStream（官方） | **无需 EPEL 的后备引擎**，EL9/EL10/Fedora 都有；无雾凇词库 |
| rime-ice（雾凇拼音） | GitHub release `full.zip` | 与 fcitx5 时代**完全同一套** Rime 数据 |

## 0. 引擎选择：rime 优先，自动降级到 libpinyin

脚本按"**装得上哪个就用哪个**"决定引擎（`_ibus_pick_engine`），不会再出现
"没装成 rime 就彻底没有中文输入"的情况：

| 发行版 | `ibus-rime` | 实际引擎 | 雾凇拼音词典 |
|---|---|---|---|
| Fedora 40+ | 官方源 ✅ | **rime** | ✅ 部署 |
| EL **10** | EPEL 10 ✅（需 EPEL 可用） | **rime** | ✅ 部署 |
| EL **8** | EPEL 8 ✅ | **rime** | ✅ 部署 |
| EL **9** | ❌ **EPEL 9 无此包** | **libpinyin**（AppStream） | ❌ 跳过（Rime 数据对 libpinyin 无用） |

> ⚠️ EL9 上看到 `ibus-rime` 装不上**不是** EPEL 没配好——EPEL 9 里根本没有
> `ibus-rime`/`librime`，再换镜像源也没用。脚本会直接写明这条，并自动装
> `ibus-libpinyin` 保证中文可用。想要雾凇拼音只能自行编译 librime + ibus-rime。
>
> EL10 上若 rime 装不上，请先确认 EPEL 真的可用：
> `dnf repolist | grep epel` / `sudo dnf install epel-release`，然后重跑 `restore`。

脚本内部的映射见 `RHEL-install.sh` 的 `GROUP_PKGS[ime]`、`RHEL_CANDIDATES` 与
`install_ibus_ime()`。

---

## 1. 运行时配置写在哪里

IBus 使用独立的 dconf profile：`/etc/dconf/profile/ibus`

```
user-db:user        # ~/.config/dconf/user —— 用户在 ibus-setup 里的改动
system-db:ibus      # /etc/dconf/db/ibus  —— 只读系统默认值（本脚本写这里）
```

**为什么不用 `su - user -c gsettings set`**：安装阶段用户的 D-Bus 会话并不存在，
`gsettings`/`dconf` 写入需要会话总线。而 dconf 的 profile 里 `user-db:user` 排在
`system-db:ibus` **之前**，用户库优先级更高——所以把默认值写进 system-db 既能
"装完即用、不必手动跑 ibus-setup"，又不会妨碍用户后续自行修改。

脚本动作：

```bash
# 生成 /etc/dconf/db/ibus.d/00-eilniri-ime 并编译
sudo dconf update
# 查看生效值（会话内）
gsettings get org.freedesktop.ibus.general preload-engines
ibus engine          # 正常输出 rime
```

`/etc/dconf/db/ibus.d/00-eilniri-ime` 由脚本生成，**本目录的 `config` 只是它的可读快照**
（IBus 不读这个文件），两者内容保持一致，方便你 diff 与手工修改。

---

## 2. Rime 用户数据目录变更（含自动迁移）

| | fcitx5（旧） | IBus（新） |
|---|---|---|
| Rime 用户数据目录 | `~/.local/share/fcitx5/rime` | `~/.config/ibus/rime` |
| 引擎 | `fcitx5-rime`（EL 需编译） | `ibus-rime`（EPEL 现成 RPM） |
| 词典/方案文件格式 | Rime YAML | **完全相同** |

新目录来自上游 `ibus-rime` 的 `rime_main.c`：
`get_ibus_rime_user_data_dir()` → `$HOME/.config/ibus/rime`。

`install_rime_ice()` 会**自动迁移**：若新目录里还没有 `rime_ice.schema.yaml`，
而旧目录存在，则把旧目录内容复制过去（跳过 `build/`，Rime 会自行重新编译；
已存在的同名文件不覆盖）。这样你此前积累的自定义方案、用户词库、`*.custom.yaml`
都不会丢。迁移完成后旧目录保持原样，确认无误可自行删除。

> ⚠️ 注意：本仓库里的 `rime/default.custom.yaml` 是**模板与文档**，脚本并不会整目录
> 拷贝它——实际文件由 `RHEL-install.sh` 在**文件不存在时**生成到
> `~/.config/ibus/rime/default.custom.yaml`（内容等价），以免覆盖你手工调过的配置。
> 想改每页候选数等参数：直接编辑目标机上的那个文件后"重新部署"。

---

## 3. 逐项迁移对照表

| 原 `configs/.config/fcitx5/` | IBus / Rime 侧 | 状态 |
|---|---|---|
| `profile` → `DefaultIM=rime` | dconf `general/preload-engines=['rime']` | ✅ 等效 |
| `profile` → 输入法组 `keyboard-us` + `rime` | 由 Rime 的 `ascii_mode` 承担中英两态 | ✅ 等效（英文态=ascii_mode） |
| `config` → `TriggerKeys=Shift+Shift_L`<br>`AltTriggerKeys=Shift_L` | Rime 引擎自身：`rime_ice.schema.yaml` 的 `switches: ascii_mode` 绑定 `Shift_L` | ✅ 单击左 Shift 切中英文不变 |
| `config` → `DefaultPageSize=5` | `~/.config/ibus/rime/default.custom.yaml` → `menu/page_size: 5` | ✅ 等效 |
| `config` → `PreeditEnabledByDefault=False` | `general/embed-preedit-text=false` + `ibus_rime.yaml` → `inline_preedit: false` | ✅ 等效 |
| `config` → `ShareInputState=No` | `general/use-global-engine=false` | ✅ 等效 |
| `config` → `ActiveByDefault=False` | `general/enable-by-default=false` | ✅ 等效 |
| `config` → `OverrideXkbOption=False` | `general/use-system-keyboard-layout=true` | ✅ 等效 |
| `config` → `EnumerateGroupForwardKeys=Super+space` | `general/hotkey/triggers=['<Super>space']` | ✅ 保留手感 |
| `config` → `PrevPage/NextPage=Up/Down`、`Prev/NextCandidate=Shift+Tab/Tab` | Rime 引擎默认（方向键、`,`/`.`、Tab） | ✅ 引擎默认 |
| `conf/classicui.conf` → 字体/主题/托盘图标 | ❌ IBus 无等价物 | 候选窗外观改由 `panel/lookup-table-orientation` 等控制，皮肤不复刻 |
| `conf/classicui.conf` → `Vertical Candidate List=False` | `panel/lookup-table-orientation=0`（0=横向） | ✅ 等效 |
| `conf/notifications.conf` | ❌ fcitx5 专有 | 删除 |

---

## 4. 会话集成（三个脚本共用的 `configs/.config/niri/config.kdl`）

该文件被三个安装脚本共用，为不影响 Debian / Arch，仓库里**仍保留 fcitx5 的写法**；
`RHEL-install.sh` 在部署配置后就地改写（`_repoint_ime_spawn` / `_repoint_ime_env_config`，
改写前自动备份 `config.kdl.bak-ime-*`）：

```kdl
# 改写前（fcitx5）
environment {
    XMODIFIERS "@im=fcitx"
    GTK_IM_MODULE "fcitx"
    QT_IM_MODULE "fcitx"
    SDL_IM_MODULE "fcitx"
    GLFW_IM_MODULE "ibus"
}
spawn-at-startup "fcitx5"

# 改写后（IBus）—— -d 后台  -r 替换旧实例  -x 提供 XWayland 的 XIM
environment {
    XMODIFIERS "@im=ibus"
    GTK_IM_MODULE "ibus"
    QT_IM_MODULE "ibus"
    SDL_IM_MODULE "ibus"
    GLFW_IM_MODULE "ibus"
}
spawn-at-startup "ibus-daemon" "-drx"
```

环境变量同时写入 `~/.config/environment.d/00-ime.conf` 与 `/etc/environment`
（旧版 fcitx 变量会被检测并**替换**，避免残留值让 IBus 静默失效）。

---

## 5. 排查

| 现象 | 处理 |
|---|---|
| 完全无法切中文 | 确认 `ibus-daemon` 在跑：`pgrep -a ibus-daemon`；环境变量：`echo $GTK_IM_MODULE` 应为 `ibus` |
| `ibus engine` 不是 rime | `ibus engine rime`；仍无效则看引擎是否可见：`ibus list-engine \| grep -i rime` |
| 引擎列表里没有 rime，只有 libpinyin | **EL9 属于正常情况**（EPEL 9 无 `ibus-rime`），中文输入仍可用。EL10/Fedora 上则先确认 EPEL：`sudo dnf install epel-release && sudo dnf install ibus-rime`，再重跑 `restore` |
| `ibus engine` 输出 `libpinyin` 而不是 `rime` | 说明走了后备引擎。查看安装汇总里的 `Manual install needed`，其中会写明原因（EL9 无 rime / EPEL 未启用） |
| 想恢复原厂雾凇行为 | 删除 `~/.config/ibus/rime/default.custom.yaml` 后"重新部署" |
| 手工改过 dconf 想回到脚本默认 | `sudo dconf update`（重新生成 system-db）后注销重登 |
| 只想用拼音（不装 EPEL） | `sudo dnf install ibus-libpinyin`，然后 `gsettings set org.freedesktop.ibus.general preload-engines "['libpinyin']"` |
