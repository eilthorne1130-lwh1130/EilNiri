#!/usr/bin/env bash
# ==============================================================================
# eilNiri — laptop-need-install.sh
#
# 补装脚本，搭配 arch-install.sh / deb-install.sh / RHEL-install.sh 使用：
# 任一主安装脚本完成 eilNiri 安装后，在笔记本或台式机上运行本脚本，
# 为已配置好的 waybar 添加电量模块（外观与其余模块一致，每 10 秒刷新一次）。
#
# 兼容三种主脚本的全部产物形态：
#   - arch / RHEL：configs 快照参考版（含整行 /* */ JSONC 注释亦可，注入前剥离）
#   - deb（waybar >= 0.10）：内嵌参考版
#   - deb（waybar 0.9.x）：快照平铺版
#   - deb 安装时已加过 battery（interval 30）：重跑本脚本刷新为 10
# 台式机同样写入模块；waybar 对无电池机器会自动隐藏该模块（无害）。
#
# Usage:
#   sudo ./laptop-need-install.sh [-y|--yes] [--dry-run]   # 与主脚本一致，root 下自动定位目标用户
#   ./laptop-need-install.sh [-y|--yes] [--dry-run]       # 普通用户直接运行，操作自己的配置
#
# 本脚本只修改（写前自动做时间戳备份 *.bak-bat-YYYYmmdd-HHMMSS）：
#   ~/.config/waybar/config (或 config.jsonc) — modules-right 注入 "battery" + 模块定义（原子写）
#   ~/.config/waybar/style.css   — 幂等追加 #battery 基础样式；状态色 / blink
#                                  keyframes 缺失时自动补齐，已存在则跳过
#
# 生效方式：优先经 niri IPC（niri msg action spawn）拉起新 waybar —— 与
# spawn-at-startup 同源、继承 niri 完整会话环境（不会丢 NIRI_SOCKET 等变量）；
# niri IPC 不可用时以原进程完整环境+原命令行重启；两者皆不可用则不杀现有
# waybar，仅提示手动操作。
# ==============================================================================

set -uo pipefail

SCRIPT_VERSION="1.2.0"
DRY_RUN=0
ASSUME_YES=0
_ERROR_REPORTED=0
BAT_DETECTED="N"

declare -a CLEANUP_TEMP_PATHS=()
register_temp_path() { CLEANUP_TEMP_PATHS+=("$1"); }

cleanup() {
    local rc=$?
    local p
    for p in ${CLEANUP_TEMP_PATHS[@]+"${CLEANUP_TEMP_PATHS[@]}"}; do
        [ -n "$p" ] && rm -f "$p" 2>/dev/null
    done
    if [ $rc -ne 0 ] && [ $rc -ne 130 ] && [ "${_ERROR_REPORTED}" -ne 1 ]; then
        echo -e "\n\e[1;31m[-] Action interrupted or terminated. (Exit: $rc)\e[0m" >&2
    fi
    exit $rc
}
trap cleanup EXIT INT TERM

# Output is always English with ANSI colors (same as the main installers).
# _t always returns the English (2nd) argument; kept as a thin translation helper.
_t() { echo "$2"; }

# ==============================================================================
# 1. Visual engine (same subset as the main installers)
# ==============================================================================

export NC='\033[0m' BOLD='\033[1m' DIM='\033[2m'
export H_RED='\033[1;31m' H_GREEN='\033[1;32m' H_YELLOW='\033[1;33m'
export H_BLUE='\033[1;34m' H_PURPLE='\033[1;35m' H_CYAN='\033[1;36m'
export H_WHITE='\033[1;37m' H_GRAY='\033[1;90m' H_MAGENTA='\033[1;35m'

export TICK="${H_GREEN}✔${NC}"
export WARN_I="${H_YELLOW}⚠${NC}"
export ARROW="${H_CYAN}➜${NC}"

# Log dir: under sudo $HOME is /root, so use the real user's home (same as main scripts)
_LOG_USER="${SUDO_USER:-$USER}"
_LOG_HOME="$HOME"
if [ -n "$_LOG_USER" ] && [ "$_LOG_USER" != "root" ]; then
    _LOG_HOME=$(getent passwd "$_LOG_USER" 2>/dev/null | cut -d: -f6)
fi
[ -z "$_LOG_HOME" ] && _LOG_HOME="$HOME"
LOG_DIR="${XDG_STATE_HOME:-$_LOG_HOME/.local/state}/eilNiri"
# 以 sudo 运行时，mkdir 会在真实用户家目录下创建 ~/.local / ~/.local/state（若尚不存在），
# 且属主是 root。立即把新创建的层级归还给真实用户。
if [ -n "$_LOG_USER" ] && [ "$_LOG_USER" != "root" ] && [ -d "$_LOG_HOME/.local/state" ]; then
    chown "$_LOG_USER:$(id -gn "$_LOG_USER" 2>/dev/null || echo "$_LOG_USER")" \
        "$_LOG_HOME/.local" "$_LOG_HOME/.local/state" 2>/dev/null || true
    chown -R "$_LOG_USER" "$LOG_DIR" 2>/dev/null || true
fi
unset _LOG_USER _LOG_HOME
mkdir -p "$LOG_DIR" 2>/dev/null || true
export TEMP_LOG_FILE="$LOG_DIR/laptop-need.log"

write_log() {
    local clean_msg
    clean_msg=$(echo -e "$2" | sed 's/\x1b\[[0-9;]*m//g')
    echo "[$(date '+%H:%M:%S')] [$1] $clean_msg" >> "$TEMP_LOG_FILE" 2>/dev/null || true
}

log()     { echo -e "   $ARROW $1"; write_log "LOG" "$1"; }
success() { echo -e "   $TICK ${H_GREEN}$1${NC}"; write_log "SUCCESS" "$1"; }
warn()    { echo -e "   $WARN_I ${H_YELLOW}${BOLD}WARNING:${NC} ${H_YELLOW}$1${NC}"; write_log "WARN" "$1"; }

error() {
    _ERROR_REPORTED=1
    echo ""
    echo -e "${H_RED}   ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e "${H_RED}   ┃  ERROR: $1${NC}"
    echo -e "${H_RED}   ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    echo ""
    write_log "ERROR" "$1"
}

info_kv() {
    printf "   ${H_BLUE}●${NC} %-15s : ${BOLD}%s${NC} ${DIM}%s${NC}\n" "$1" "$2" "${3:-}"
    write_log "INFO" "$1=$2"
}

# Confirmation prompt with timeout: confirm "question" [default Y|N] [timeout sec]
# Returns 0 = yes, 1 = no
confirm() {
    local prompt="$1" default="${2:-Y}" timeout="${3:-30}" ans
    if [ "${ASSUME_YES:-0}" -eq 1 ]; then
        ans="Y"
        echo -e "   ${H_CYAN}${prompt} ${BOLD}Y (unattended)${NC}"
    else
        echo -ne "   ${H_CYAN}${prompt} ${NC}"
        if ! read -t "$timeout" -r ans; then echo ""; fi
    fi
    ans=${ans:-$default}
    [[ "$ans" =~ ^[Yy] ]]
}

# Core command executor: visual + logging + dry-run interception (main-script style)
exe() {
    local full_command="$*"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "   ${H_GRAY}│${NC} ${H_YELLOW}[DRY-RUN]${NC} ${BOLD}$full_command${NC}"
        write_log "DRYRUN" "$full_command"
        return 0
    fi
    echo -e "   ${H_GRAY}┌──[ ${H_MAGENTA}EXEC${H_GRAY} ]────────────────────────────────────────────────────${NC}"
    echo -e "   ${H_GRAY}│${NC} ${H_CYAN}$ ${NC}${BOLD}$full_command${NC}"
    write_log "EXEC" "$full_command"
    "$@"
    local status=$?
    if [ $status -eq 0 ]; then
        echo -e "   ${H_GRAY}└────────────────────────────────────────────────────── ${H_GREEN}OK${H_GRAY} ─┘${NC}"
    else
        echo -e "   ${H_GRAY}└────────────────────────────────────────────────────── ${H_RED}FAIL${H_GRAY} ─┘${NC}"
        write_log "FAIL" "Exit Code: $status ($full_command)"
        return $status
    fi
}

dry_run_note() {
    echo -e "   ${H_GRAY}│${NC} ${H_YELLOW}[DRY-RUN]${NC} ${BOLD}$1${NC}"
    write_log "DRYRUN" "$1"
}

# ==============================================================================
# 2. Identity — same resolution as the main installers, plus a plain-user mode
# ==============================================================================

TARGET_USER=""
HOME_DIR=""
RUN_AS_ROOT=0

detect_target_user() {
    if [ "$EUID" -eq 0 ]; then
        RUN_AS_ROOT=1
        # SUDO_USER → uid 1000 → first regular user (no interactive menu: this
        # companion runs right after an installer on a single-user laptop)
        local uid1000
        uid1000=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd | head -n 1)
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            TARGET_USER="$SUDO_USER"
        elif [ -n "$uid1000" ]; then
            TARGET_USER="$uid1000"
        else
            TARGET_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd | head -n 1)
        fi
        if [ -z "$TARGET_USER" ]; then
            error "$(_t "No regular user found (run this script with sudo from your own session)." "No regular user found (run this script with sudo from your own session).")"
            exit 1
        fi
        HOME_DIR=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)
        [ -z "$HOME_DIR" ] && HOME_DIR="/home/$TARGET_USER"
    else
        RUN_AS_ROOT=0
        TARGET_USER=$(id -un)
        HOME_DIR="$HOME"
    fi
    export TARGET_USER HOME_DIR
    info_kv "$(_t "Target User" "Target User")" "$TARGET_USER" "($HOME_DIR)"
}

as_user() {
    if [ "$RUN_AS_ROOT" -eq 1 ]; then
        runuser -u "$TARGET_USER" -- "$@"
    else
        "$@"
    fi
}

# Files written as root must be handed back to the real user (main-script rule)
_own_back() {
    [ "$RUN_AS_ROOT" -eq 1 ] || return 0
    local f
    for f in "$@"; do
        [ -e "$f" ] && chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$f" 2>/dev/null || true
    done
}

# ==============================================================================
# 3. Battery module injection (reference: deb-install.sh _waybar_add_battery)
# ==============================================================================

WAYBAR_CFG=""
WAYBAR_CSS=""

preflight() {
    if [ -f "$HOME_DIR/.config/waybar/config" ]; then
        WAYBAR_CFG="$HOME_DIR/.config/waybar/config"
    elif [ -f "$HOME_DIR/.config/waybar/config.jsonc" ]; then
        WAYBAR_CFG="$HOME_DIR/.config/waybar/config.jsonc"
    else
        error "$(_t "waybar config not found in $HOME_DIR/.config/waybar/ (checked config and config.jsonc) — run one of the main installers (arch/deb/RHEL-install.sh) first." "waybar config not found in $HOME_DIR/.config/waybar/ (checked config and config.jsonc) — run one of the main installers (arch/deb/RHEL-install.sh) first.")"
        exit 1
    fi
    WAYBAR_CSS="$HOME_DIR/.config/waybar/style.css"
    if ! command -v python3 >/dev/null 2>&1; then
        error "$(_t "python3 not found — cannot patch the waybar config." "python3 not found — cannot patch the waybar config.")"
        exit 1
    fi
    if ! command -v waybar >/dev/null 2>&1; then
        warn "$(_t "waybar binary not found in PATH; the config will still be patched." "waybar binary not found in PATH; the config will still be patched.")"
    fi
}

# Battery detection via power_supply "type" files (covers BAT0/BAT1/UPS naming),
# same method as the main installers. Result pre-fills the confirm default.
detect_battery() {
    local ps
    BAT_DETECTED="N"
    for ps in /sys/class/power_supply/*/type; do
        [ -e "$ps" ] || continue
        if [ "$(cat "$ps" 2>/dev/null)" = "Battery" ]; then
            BAT_DETECTED="Y"
            break
        fi
    done
}

backup_files() {
    local ts="$1" f bak
    for f in "$WAYBAR_CFG" "$WAYBAR_CSS"; do
        [ -f "$f" ] || continue
        bak="$f.bak-bat-$ts"
        if [ -e "$bak" ]; then
            log "$(_t "Backup already exists: " "Backup already exists: ") $bak"
            continue
        fi
        exe cp -p "$f" "$bak" || {
            warn "$(_t "Backup failed for $f — aborting without changes." "Backup failed for $f — aborting without changes.")"
            return 1
        }
        _own_back "$bak"
    done
    return 0
}

# JSON 注入：modules-right 在 "tray" 前插 "battery"（无 tray 则放最前）+ battery
# 模块定义。单 bar dict 与多 bar list 配置均兼容；幂等（battery 已在 modules-right
# 则不重复插入，定义整体刷新——可借此把旧 interval 30 更新为 10）。剥离全部 JSONC 注释
# （// 与 /* */）及末尾逗号，严格保护字符串不被破坏。原子写入：先写 .tmp 再 replace，
# 解析失败时原文件不动。
inject_battery_json() {
    if [ "$DRY_RUN" -eq 1 ]; then
        dry_run_note "python3 — inject battery module into $WAYBAR_CFG"
        return 0
    fi
    local tmp="$WAYBAR_CFG.tmp-bat.$$"
    register_temp_path "$tmp"
    python3 - "$WAYBAR_CFG" "$tmp" <<'PYBATEOF'
import json, os, re, sys

path, tmp = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    raw = f.read()

# 1. 剥离 JSONC 注释（// 与 /* */），同时严格保护双引号/单引号字符串内部不被破坏
comment_pattern = re.compile(
    r"(?P<comment>//[^\r\n]*|/\*.*?\*/)|(?P<string>\"(?:\\.|[^\"\\])*\"|\x27(?:\\.|[^\x27\\])*\x27)",
    re.DOTALL
)

def strip_comment_sub(match):
    if match.group("comment"):
        return " "
    return match.group("string")

clean_json = comment_pattern.sub(strip_comment_sub, raw)

# 2. 剥离 } 或 ] 前的末尾逗号（trailing commas），同时严格保护字符串内部
comma_pattern = re.compile(
    r"(?P<string>\"(?:\\.|[^\"\\])*\"|\x27(?:\\.|[^\x27\\])*\x27)|(?P<trailing_comma>,(?:\s*,)*\s*(?=[\]\}]))",
    re.DOTALL
)

def strip_comma_sub(match):
    if match.group("trailing_comma"):
        return ""
    return match.group("string")

clean_json = comma_pattern.sub(strip_comma_sub, clean_json)

cfg = json.loads(clean_json)

battery_def = {
    "format": "{capacity}% {icon}",
    "format-charging": "{capacity}% \U000F0084",
    "format-plugged": "{capacity}% \U000F06A5",
    "format-icons": ["\U000F007A", "\U000F007C", "\U000F007E", "\U000F0080", "\U000F0082"],
    "states": {"warning": 30, "critical": 15},
    "interval": 10,
    "tooltip-format": "<tt>\u7535\u91cf: {capacity}%\n\u5269\u4f59: {timeTo}</tt>",
}

def patch_bar(bar):
    if not isinstance(bar, dict):
        return
    mods = bar.get("modules-right", [])
    if "battery" not in mods:
        pos = mods.index("tray") if "tray" in mods else 0
        mods.insert(pos, "battery")
        bar["modules-right"] = mods
    bar["battery"] = battery_def

if isinstance(cfg, list):
    for b in cfg:
        patch_bar(b)
elif isinstance(cfg, dict):
    patch_bar(cfg)
else:
    raise ValueError(f"Unsupported Waybar config format: {type(cfg).__name__}")

with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=4, ensure_ascii=False)
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, path)
PYBATEOF
    if [ $? -ne 0 ]; then
        warn "$(_t "Battery JSON injection failed (python3 could not parse the config); original file untouched." "Battery JSON injection failed (python3 could not parse the config); original file untouched.")"
        return 1
    fi
    _own_back "$WAYBAR_CFG"
    return 0
}

# CSS：追加 #battery 基础 pill 样式。三个独立幂等守卫——基础样式、状态变色
# （charging/warning/critical）、blink keyframes，缺哪个补哪个（两版 style.css
# 通常已带状态色与 keyframes，则自动跳过；防的是更老的历史版本）。
append_battery_css() {
    if [ ! -f "$WAYBAR_CSS" ]; then
        warn "$(_t "style.css not found — base #battery style not added." "style.css not found — base #battery style not added.")"
        return 0
    fi
    local _need_base=0 _need_states=0 _need_blink=0
    grep -q '^#battery {' "$WAYBAR_CSS" || _need_base=1
    grep -q '^#battery\.charging' "$WAYBAR_CSS" || _need_states=1
    grep -q '@keyframes blink' "$WAYBAR_CSS" || _need_blink=1
    if [ "$_need_base" -eq 0 ] && [ "$_need_states" -eq 0 ] && [ "$_need_blink" -eq 0 ]; then
        log "$(_t "style.css already has all #battery rules — skipped." "style.css already has all #battery rules — skipped.")"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        dry_run_note "append #battery css blocks to $WAYBAR_CSS"
        return 0
    fi
    if [ "$_need_base" -eq 1 ]; then
        cat >> "$WAYBAR_CSS" <<'BATCSSEOF'

/* ═══════════════════════════════════════════════════════════════
   13. Battery（eilNiri 按需添加）
   ═══════════════════════════════════════════════════════════════ */
#battery {
    padding: 0 14px;
    margin: 3px 0;
    color: #cdd6f4;
    background: rgba(49, 50, 68, 0.72);
    border-radius: 10px;
    border-left: 2px solid rgba(166, 227, 161, 0.55);
    transition: all 200ms ease;
}

#battery:hover {
    background: rgba(69, 71, 90, 0.78);
    box-shadow: 0 2px 10px rgba(0, 0, 0, 0.25);
}
BATCSSEOF
    fi
    if [ "$_need_states" -eq 1 ]; then
        cat >> "$WAYBAR_CSS" <<'BATSTSEOF'

/* Battery 状态色（与参考版 style.css 第 6 节一致） */
#battery.charging {
    color: #a6e3a1;
}

#battery.warning:not(.charging) {
    color: #f9e2af;
}

#battery.critical:not(.charging) {
    color: #f38ba8;
    animation: blink 800ms infinite;
}
BATSTSEOF
    fi
    if [ "$_need_blink" -eq 1 ]; then
        cat >> "$WAYBAR_CSS" <<'BATBLKEOF'

@keyframes blink {
    0% {
        opacity: 1;
    }
    50% {
        opacity: 0.35;
    }
    100% {
        opacity: 1;
    }
}
BATBLKEOF
    fi
    _own_back "$WAYBAR_CSS"
    return 0
}

# ==============================================================================
# 4. waybar restart — 让新模块立即生效，且不破坏会话环境
#    v1.0 的「白名单环境变量重建」会丢 NIRI_SOCKET 等会话变量，导致
#    niri/workspaces、niri/window 模块失联甚至整条栏消失。正确做法：让 niri
#    自己拉起 waybar（niri msg action spawn，与 spawn-at-startup 同源、继承
#    niri 完整会话环境）；niri IPC 不可用时，以原进程的完整 environ+cmdline
#    原样重启；两者都不可用则不动运行中的 waybar，仅给手动提示。
# ==============================================================================

restart_waybar() {
    local wpid="" launch_cmd="" _envdump="" _cmddump="" _niri_env="" _cap="" _pyrelaunch=""
    local _niri_ok=0 _ok=0
    wpid=$(pgrep -x waybar 2>/dev/null | head -n 1 || true)
    if [ -z "$wpid" ]; then
        log "$(_t "waybar is not running; the battery module appears on next login (niri spawn-at-startup)." "waybar is not running; the battery module appears on next login (niri spawn-at-startup).")"
        return 0
    fi
    # 优先复用仓库的单实例启动守卫，与 niri 的启动来源保持一致
    if [ -x /usr/local/bin/eilniri-waybar-start ]; then
        launch_cmd="/usr/local/bin/eilniri-waybar-start"
    else
        launch_cmd="waybar"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        dry_run_note "pkill -x waybar; niri msg action spawn -- $launch_cmd"
        return 0
    fi

    # 先取运行中 waybar 的会话环境（进程死后 /proc/<pid> 即消失）：
    #   - NIRI_SOCKET/XDG_RUNTIME_DIR：root / SSH 下借给这一次 niri IPC 调用
    #     （真正拉起的 waybar 用的是 niri 自己的完整环境，与白名单重建不同）
    #   - 完整 environ + cmdline：留给次选的全环境重启
    _envdump=$(mktemp 2>/dev/null) && _cmddump=$(mktemp 2>/dev/null)
    [ -n "$_envdump" ] && register_temp_path "$_envdump"
    [ -n "$_cmddump" ] && register_temp_path "$_cmddump"
    cat "/proc/$wpid/environ" > "$_envdump" 2>/dev/null || true
    cat "/proc/$wpid/cmdline" > "$_cmddump" 2>/dev/null || true
    _niri_env=""
    [ -n "${NIRI_SOCKET:-}" ] && _niri_env="NIRI_SOCKET=${NIRI_SOCKET} "
    [ -n "${XDG_RUNTIME_DIR:-}" ] && _niri_env="${_niri_env}XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} "
    if [ -s "$_envdump" ]; then
        _cap=$(tr '\0' '\n' < "$_envdump" 2>/dev/null | grep -E '^(NIRI_SOCKET|XDG_RUNTIME_DIR)=' | tr '\n' ' ' || true)
        [ -n "$_cap" ] && _niri_env="${_niri_env}${_cap}"
    fi

    # 预检 niri IPC 可达（无害读命令）；确认能拉起才动进程
    if command -v niri >/dev/null 2>&1 && [ -n "${_niri_env// /}" ]; then
        if [ "$RUN_AS_ROOT" -eq 1 ]; then
            runuser -u "$TARGET_USER" -- env $_niri_env niri msg version >/dev/null 2>&1 && _niri_ok=1
        else
            env $_niri_env niri msg version >/dev/null 2>&1 && _niri_ok=1
        fi
    fi
    if [ "$_niri_ok" -ne 1 ] && [ ! -s "$_envdump" ]; then
        warn "$(_t "cannot restart waybar safely (no niri IPC and no captured env) — config written, running waybar left untouched. Apply manually: re-login, or 'pkill -x waybar' then run: $launch_cmd" "cannot restart waybar safely (no niri IPC and no captured env) — config written, running waybar left untouched. Apply manually: re-login, or 'pkill -x waybar' then run: $launch_cmd")"
        return 0
    fi

    pkill -x waybar 2>/dev/null || true
    sleep 0.5

    # 首选：niri 拉起（继承 niri 完整会话环境，与 spawn-at-startup 同源）
    if [ "$_niri_ok" -eq 1 ]; then
        if [ "$RUN_AS_ROOT" -eq 1 ]; then
            runuser -u "$TARGET_USER" -- env $_niri_env niri msg action spawn -- "$launch_cmd" >/dev/null 2>&1 && _ok=1
        else
            env $_niri_env niri msg action spawn -- "$launch_cmd" >/dev/null 2>&1 && _ok=1
        fi
    fi

    # 次选：以原进程完整环境 + 原命令行重启（双 fork 脱离本脚本会话）
    if [ "$_ok" -ne 1 ] && [ -s "$_envdump" ]; then
        _pyrelaunch=$(mktemp 2>/dev/null)
        if [ -n "$_pyrelaunch" ]; then
            register_temp_path "$_pyrelaunch"
            cat > "$_pyrelaunch" <<'PYWREOF'
import os, sys

envdump, cmddump, fallback_cmd = sys.argv[1], sys.argv[2], sys.argv[3]
env = {}
with open(envdump, "rb") as f:
    for kv in f.read().split(b"\0"):
        if b"=" in kv:
            k, v = kv.split(b"=", 1)
            env[k.decode("utf-8", "replace")] = v.decode("utf-8", "replace")
argv = []
with open(cmddump, "rb") as f:
    for a in f.read().split(b"\0"):
        if a:
            argv.append(a.decode("utf-8", "replace"))
if not argv:
    argv = [fallback_cmd]
cmd = argv[0]
if "/" not in cmd:
    for d in env.get("PATH", "/usr/bin:/bin").split(":"):
        cand = (d.rstrip("/") or "/") + "/" + cmd
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            cmd = cand
            break
argv[0] = cmd
pid = os.fork()
if pid > 0:
    sys.exit(0)
os.setsid()
devnull = os.open(os.devnull, os.O_RDWR)
for fd in (0, 1, 2):
    os.dup2(devnull, fd)
os.execve(cmd, argv, env)
PYWREOF
            _own_back "$_envdump" "$_cmddump" "$_pyrelaunch"
            if [ "$RUN_AS_ROOT" -eq 1 ]; then
                runuser -u "$TARGET_USER" -- python3 "$_pyrelaunch" "$_envdump" "$_cmddump" "$launch_cmd" >/dev/null 2>&1 && _ok=1 || true
            else
                python3 "$_pyrelaunch" "$_envdump" "$_cmddump" "$launch_cmd" >/dev/null 2>&1 && _ok=1 || true
            fi
        fi
    fi

    # 验证：2 秒后 waybar 必须在跑，否则给出明确的手动恢复路径
    sleep 2
    if pgrep -x waybar >/dev/null 2>&1; then
        success "$(_t "waybar restarted — the battery module is live now." "waybar restarted — the battery module is live now.")"
    else
        warn "$(_t "waybar did not come back automatically (config is already written). Recover manually: re-login, or run: $launch_cmd" "waybar did not come back automatically (config is already written). Recover manually: re-login, or run: $launch_cmd")"
    fi
}

# ==============================================================================
# 5. Main
# ==============================================================================

usage() {
    cat <<USAGEEOF
eilNiri laptop-need-install.sh v$SCRIPT_VERSION

补装脚本（搭配 arch-install.sh / deb-install.sh / RHEL-install.sh 使用）。
任一主安装脚本完成 eilNiri 安装后运行，为已配置好的 waybar 添加电量模块
（外观与现有模块一致，每 10 秒刷新一次）。三种主脚本的全部产物形态均兼容；
笔记本与台式机通用（无电池机器 waybar 自动隐藏该模块，无害）。

Usage:
  sudo ./laptop-need-install.sh [-y|--yes] [--dry-run]
  ./laptop-need-install.sh [-y|--yes] [--dry-run]

Options:
  -y, --yes    自动确认提示，非交互式运行（适用于自动化测试）
  --dry-run    只打印将要执行的动作，不做任何修改
  -h, --help   显示本帮助

修改的文件（写前自动备份 *.bak-bat-<timestamp>）:
  ~/.config/waybar/config (或 config.jsonc) 注入 battery 模块（interval 10s）
  ~/.config/waybar/style.css                幂等追加 #battery 基础样式

回滚:
  cp ~/.config/waybar/config.bak-bat-<ts>      ~/.config/waybar/config
  cp ~/.config/waybar/style.css.bak-bat-<ts>   ~/.config/waybar/style.css
USAGEEOF
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --dry-run) DRY_RUN=1; shift ;;
            -y|--yes)  ASSUME_YES=1; shift ;;
            *)         error "$(_t "Unknown option: $1 (try --help)" "Unknown option: $1 (try --help)")"; exit 1 ;;
        esac
    done

    echo ""
    echo -e "${H_PURPLE}╭────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${H_PURPLE}│${NC} ${BOLD}${H_WHITE}eilNiri Laptop Supplement — waybar battery module${NC}  ${DIM}v$SCRIPT_VERSION${NC}"
    echo -e "${H_PURPLE}│${NC} ${H_CYAN}after arch/deb/RHEL-install.sh · laptop & desktop · idempotent${NC}"
    echo -e "${H_PURPLE}╰────────────────────────────────────────────────────────────────────────╯${NC}"
    echo ""
    write_log "SECTION" "laptop-need-install v$SCRIPT_VERSION started (dry-run=$DRY_RUN, yes=$ASSUME_YES)"

    detect_target_user
    preflight
    detect_battery
    info_kv "$(_t "Waybar Config" "Waybar Config")" "$WAYBAR_CFG"
    info_kv "$(_t "Battery" "Battery")" "$([ "$BAT_DETECTED" = "Y" ] && echo "detected" || echo "not found")"
    if [ "$BAT_DETECTED" != "Y" ]; then
        log "$(_t "No battery detected — the module is written anyway; waybar auto-hides it on battery-less machines (desktops), which is harmless." "No battery detected — the module is written anyway; waybar auto-hides it on battery-less machines (desktops), which is harmless.")"
    fi

    if ! confirm "$(_t "Add the waybar battery module? [Y/n] (default Y, 15s):" "Add the waybar battery module? [Y/n] (default Y, 15s):")" "Y" 15; then
        log "$(_t "Battery module not added — nothing was changed." "Battery module not added — nothing was changed.")"
        exit 0
    fi

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    backup_files "$ts" || exit 1
    inject_battery_json || exit 1
    append_battery_css
    restart_waybar

    echo ""
    success "$(_t "waybar battery module added (interval 10s). Backups: *.bak-bat-$ts" "waybar battery module added (interval 10s). Backups: *.bak-bat-$ts")"
    log "$(_t "Roll back any time: cp <file>.bak-bat-$ts <file>" "Roll back any time: cp <file>.bak-bat-$ts <file>")"
    echo ""
}

main "$@"
