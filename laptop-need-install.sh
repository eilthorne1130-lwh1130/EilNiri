#!/usr/bin/env bash
# ==============================================================================
# eilNiri — laptop-need-install.sh
#
# 笔记本补装脚本，搭配 arch-install.sh / deb-install.sh / RHEL-install.sh 使用：
# 在主安装脚本完成 eilNiri 安装后，在笔记本/带电池设备上运行本脚本，
# 为已配置好的 waybar 添加电量模块（外观与其余模块一致，每 10 秒刷新一次）。
#
# Usage:
#   sudo ./laptop-need-install.sh [--dry-run]   # 与主脚本一致，root 下自动定位目标用户
#   ./laptop-need-install.sh  [--dry-run]       # 普通用户直接运行，操作自己的配置
#
# 本脚本只修改（写前自动做时间戳备份 *.bak-bat-YYYYmmdd-HHMMSS）：
#   ~/.config/waybar/config      — modules-right 注入 "battery" + 模块定义
#   ~/.config/waybar/style.css   — 幂等追加 #battery 基础 pill 样式
# 状态变色规则（charging/warning/critical）部署的 style.css 已自带，不重复添加。
# ==============================================================================

set -uo pipefail

SCRIPT_VERSION="1.0.0"
DRY_RUN=0
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
    echo -ne "   ${H_CYAN}${prompt} ${NC}"
    if ! read -t "$timeout" -r ans; then echo ""; fi
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
    WAYBAR_CFG="$HOME_DIR/.config/waybar/config"
    WAYBAR_CSS="$HOME_DIR/.config/waybar/style.css"
    if [ ! -f "$WAYBAR_CFG" ]; then
        error "$(_t "waybar config not found at $WAYBAR_CFG — run one of the main installers (arch/deb/RHEL-install.sh) first." "waybar config not found at $WAYBAR_CFG — run one of the main installers (arch/deb/RHEL-install.sh) first.")"
        exit 1
    fi
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
# 模块定义。参考版/平铺版 JSON 通用；幂等（battery 已在 modules-right 则不重复插入，
# 定义整体刷新——可借此把旧 interval 30 更新为 10）。原子写入：先写 .tmp 再 replace，
# 解析失败时原文件不动。
inject_battery_json() {
    if [ "$DRY_RUN" -eq 1 ]; then
        dry_run_note "python3 — inject battery module into $WAYBAR_CFG"
        return 0
    fi
    local tmp="$WAYBAR_CFG.tmp-bat.$$"
    register_temp_path "$tmp"
    python3 - "$WAYBAR_CFG" "$tmp" <<'PYBATEOF'
import json, os, sys

path, tmp = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)

mods = cfg.get("modules-right", [])
if "battery" not in mods:
    pos = mods.index("tray") if "tray" in mods else 0
    mods.insert(pos, "battery")
cfg["modules-right"] = mods

cfg["battery"] = {
    "format": "{capacity}% {icon}",
    "format-charging": "{capacity}% \U000F0084",
    "format-plugged": "{capacity}% \U000F06A5",
    "format-icons": ["\U000F007A", "\U000F007C", "\U000F007E", "\U000F0080", "\U000F0082"],
    "states": {"warning": 30, "critical": 15},
    "interval": 10,
    "tooltip-format": "<tt>\u7535\u91cf: {capacity}%\n\u5269\u4f59: {timeTo}</tt>",
}

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

# CSS：追加 #battery 基础 pill 样式（状态色规则部署的 style.css 已自带，缺的只是
# 基础样式；幂等：已有 ^#battery { 则跳过——deb 安装时加过的机器直接跳过）。
append_battery_css() {
    if [ ! -f "$WAYBAR_CSS" ]; then
        warn "$(_t "style.css not found — base #battery style not added." "style.css not found — base #battery style not added.")"
        return 0
    fi
    if grep -q '^#battery {' "$WAYBAR_CSS"; then
        log "$(_t "#battery base style already present in style.css — skipped." "#battery base style already present in style.css — skipped.")"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        dry_run_note "append #battery base style to $WAYBAR_CSS"
        return 0
    fi
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
    _own_back "$WAYBAR_CSS"
    return 0
}

# ==============================================================================
# 4. waybar restart — only when a live waybar and a usable session env exist;
#    otherwise fall back to a manual hint (never kill without a way to relaunch)
# ==============================================================================

restart_waybar() {
    local wpid="" wenv="" launch_cmd=""
    wpid=$(pgrep -x waybar 2>/dev/null | head -n 1 || true)
    if [ -z "$wpid" ]; then
        log "$(_t "waybar is not running; the battery module appears on next login (niri spawn-at-startup)." "waybar is not running; the battery module appears on next login (niri spawn-at-startup).")"
        return 0
    fi
    # Prefer the installed single-instance guard — same launch source as niri
    if [ -x /usr/local/bin/eilniri-waybar-start ]; then
        launch_cmd="/usr/local/bin/eilniri-waybar-start"
    else
        launch_cmd="waybar"
    fi

    if [ "$RUN_AS_ROOT" -eq 1 ]; then
        # root: borrow the session env from the live waybar process, relaunch as target user
        wenv=$(tr '\0' '\n' < "/proc/$wpid/environ" 2>/dev/null \
            | grep -E '^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR|DISPLAY|DBUS_SESSION_BUS_ADDRESS)=' \
            | tr '\n' ' ' || true)
        if [ -z "$wenv" ]; then
            warn "$(_t "Could not read the running waybar session env — restart it manually (pkill waybar, then re-login)." "Could not read the running waybar session env — restart it manually (pkill waybar, then re-login).")"
            return 0
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            dry_run_note "pkill -x waybar; runuser -u $TARGET_USER -- setsid env $wenv$launch_cmd"
            return 0
        fi
        pkill -x waybar 2>/dev/null || true
        sleep 0.5
        as_user sh -c "setsid env $wenv $launch_cmd >/dev/null 2>&1 </dev/null &"
    else
        if [ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
            log "$(_t "No graphical session detected; the battery module appears on next login." "No graphical session detected; the battery module appears on next login.")"
            return 0
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            dry_run_note "pkill -x waybar; setsid $launch_cmd"
            return 0
        fi
        pkill -x waybar 2>/dev/null || true
        sleep 0.5
        setsid "$launch_cmd" >/dev/null 2>&1 </dev/null &
    fi
    success "$(_t "waybar restarted — the battery module is live now." "waybar restarted — the battery module is live now.")"
}

# ==============================================================================
# 5. Main
# ==============================================================================

usage() {
    cat <<USAGEEOF
eilNiri laptop-need-install.sh v$SCRIPT_VERSION

笔记本补装脚本（搭配 arch-install.sh / deb-install.sh / RHEL-install.sh 使用）。
在主安装脚本完成 eilNiri 安装后运行，为已配置好的 waybar 添加电量模块
（外观与现有模块一致，每 10 秒刷新一次）。

Usage:
  sudo ./laptop-need-install.sh [--dry-run]
  ./laptop-need-install.sh  [--dry-run]

Options:
  --dry-run    只打印将要执行的动作，不做任何修改
  -h, --help   显示本帮助

修改的文件（写前自动备份 *.bak-bat-<timestamp>）:
  ~/.config/waybar/config      注入 battery 模块（interval 10s）
  ~/.config/waybar/style.css   幂等追加 #battery 基础样式

回滚:
  cp ~/.config/waybar/config.bak-bat-<ts>      ~/.config/waybar/config
  cp ~/.config/waybar/style.css.bak-bat-<ts>   ~/.config/waybar/style.css
USAGEEOF
}

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        --dry-run) DRY_RUN=1 ;;
        "")        : ;;
        *)         error "$(_t "Unknown option: $1 (try --help)" "Unknown option: $1 (try --help)")"; exit 1 ;;
    esac

    echo ""
    echo -e "${H_PURPLE}╭────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${H_PURPLE}│${NC} ${BOLD}${H_WHITE}eilNiri Laptop Supplement — waybar battery module${NC}  ${DIM}v$SCRIPT_VERSION${NC}"
    echo -e "${H_PURPLE}│${NC} ${H_CYAN}after arch/deb/RHEL-install.sh · laptop only · idempotent${NC}"
    echo -e "${H_PURPLE}╰────────────────────────────────────────────────────────────────────────╯${NC}"
    echo ""
    write_log "SECTION" "laptop-need-install v$SCRIPT_VERSION started (dry-run=$DRY_RUN)"

    detect_target_user
    preflight
    detect_battery
    info_kv "$(_t "Battery" "Battery")" "$([ "$BAT_DETECTED" = "Y" ] && echo "detected" || echo "not found")"

    if ! confirm "$(_t "Add the waybar battery module (laptop/battery-powered device)? [Y/n] (default ${BAT_DETECTED}, 15s):" "Add the waybar battery module (laptop/battery-powered device)? [Y/n] (default ${BAT_DETECTED}, 15s):")" "$BAT_DETECTED" 15; then
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
