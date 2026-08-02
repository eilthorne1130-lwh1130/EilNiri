#!/usr/bin/env bash
# ==============================================================================
# eilNiri - replicate.sh
#
#   把当前机器的 niri 桌面套件（软件包 + 桌面配置 + 系统服务）采集为快照，
#   并在全新的 Arch 系 / RHEL 系 系统上一键重现。
#
#   Usage:
#     ./replicate.sh export  [--keep-typos]   采集快照（普通用户运行，只读系统）
#     ./replicate.sh restore [--dry-run]      在新系统重现（root 运行）
#     ./replicate.sh rollback                 从已有快照回滚配置（root 运行）
#     ./replicate.sh --help
#
#   快照产物（export 生成于本脚本所在目录）:
#     pkglist/official.txt   官方仓库包
#     pkglist/aur.txt        AUR 包
#     pkglist/services.txt   已启用系统服务（格式: "unit 提供包"）
#     config/                桌面配置镜像
#
#   交互风格与视觉引擎参考: https://github.com/SHORiN-KiWATA/shorin-arch-setup
#   快照回滚设计参考:       https://github.com/ech678/NyxNiri
# ==============================================================================
echo "The author assumes no responsibility for any changes made to the server, computer, etc., and the author reserves the right of final interpretation.
set -uo pipefail"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$BASE_DIR/.replicate_progress"
BACKUP_DIR="$BASE_DIR/backups"

declare -a CLEANUP_TEMP_PATHS=()
register_temp_path() { CLEANUP_TEMP_PATHS+=("$1"); }

cleanup() {
    local rc=$?
    local p
    for p in "${CLEANUP_TEMP_PATHS[@]:-}"; do
        [ -n "$p" ] && rm -rf "$p" 2>/dev/null
    done
    if [ $rc -ne 0 ] && [ $rc -ne 130 ] && [ "${_ERROR_REPORTED:-0}" -ne 1 ]; then
        echo -e "\n\e[1;31m[-] Action interrupted or terminated. (Exit: $rc)\e[0m" >&2
    fi
    exit $rc
}
trap cleanup EXIT INT TERM

MODE=""
DRY_RUN=0
KEEP_TYPOS=0
_ERROR_REPORTED=0

# TTY 检测：无图形会话（linux console / ssh without X）时自动切英文纯文本
# 若已通过环境变量 TTY_MODE 指定，则跳过自动检测
if [ "${TTY_MODE:-unset}" = "unset" ]; then
    if [ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] || [ "$TERM" = "linux" ]; then
        TTY_MODE=1
        NC=""; BOLD=""; DIM=""; H_RED=""; H_GREEN=""; H_YELLOW=""
        H_BLUE=""; H_PURPLE=""; H_CYAN=""; H_WHITE=""; H_GRAY=""; H_MAGENTA=""
        TICK="* "; CROSS="x "; WARN_I="! "; ARROW="> "
    else
        TTY_MODE=0
    fi
fi
_t() { [ "$TTY_MODE" = "1" ] && echo "$2" || echo "$1"; }

# ==============================================================================
# 1. 视觉引擎 (参考 00-utils.sh)
# ==============================================================================

export NC='\033[0m' BOLD='\033[1m' DIM='\033[2m'
export H_RED='\033[1;31m' H_GREEN='\033[1;32m' H_YELLOW='\033[1;33m'
export H_BLUE='\033[1;34m' H_PURPLE='\033[1;35m' H_CYAN='\033[1;36m'
export H_WHITE='\033[1;37m' H_GRAY='\033[1;90m' H_MAGENTA='\033[1;35m'

export TICK="${H_GREEN}✔${NC}"
export CROSS="${H_RED}✘${NC}"
export WARN_I="${H_YELLOW}⚠${NC}"
export ARROW="${H_CYAN}➜${NC}"

# 日志目录：sudo 下 $HOME 是 /root，改用真实用户的 home（与 export 非 sudo 保持一致）
_LOG_USER="${SUDO_USER:-$USER}"
_LOG_HOME="$HOME"
if [ -n "$_LOG_USER" ] && [ "$_LOG_USER" != "root" ]; then
    _LOG_HOME=$(getent passwd "$_LOG_USER" 2>/dev/null | cut -d: -f6)
fi
[ -z "$_LOG_HOME" ] && _LOG_HOME="$HOME"
LOG_DIR="${XDG_STATE_HOME:-$_LOG_HOME/.local/state}/eilNiri"
unset _LOG_USER _LOG_HOME
mkdir -p "$LOG_DIR" 2>/dev/null || true
export TEMP_LOG_FILE="$LOG_DIR/replicate.log"

init_logger() {
    if [ -f "$TEMP_LOG_FILE" ]; then
        local tmp_log
        tmp_log=$(tail -n 800 "$TEMP_LOG_FILE" 2>/dev/null || true)
        echo "$tmp_log" > "$TEMP_LOG_FILE"
    fi
    echo "==================================================" >> "$TEMP_LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] eilNiri session started" >> "$TEMP_LOG_FILE"
    echo "==================================================" >> "$TEMP_LOG_FILE"
}

write_log() {
    local clean_msg
    clean_msg=$(echo -e "$2" | sed 's/\x1b\[[0-9;]*m//g')
    echo "[$(date '+%H:%M:%S')] [$1] $clean_msg" >> "$TEMP_LOG_FILE" 2>/dev/null || true
}

section() {
    echo ""
    echo -e "${H_PURPLE}╭──────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${H_PURPLE}│${NC} ${BOLD}${H_WHITE}$1${NC}"
    echo -e "${H_PURPLE}│${NC} ${H_CYAN}$2${NC}"
    echo -e "${H_PURPLE}╰──────────────────────────────────────────────────────────────────────────────╯${NC}"
    write_log "SECTION" "$1 - $2"
}

info_kv() {
    printf "   ${H_BLUE}●${NC} %-15s : ${BOLD}%s${NC} ${DIM}%s${NC}\n" "$1" "$2" "${3:-}"
    write_log "INFO" "$1=$2"
}

log()     { echo -e "   $ARROW $1"; write_log "LOG" "$1"; }
success() { echo -e "   $TICK ${H_GREEN}$1${NC}"; write_log "SUCCESS" "$1"; }
warn()    { echo -e "   $WARN_I ${H_YELLOW}${BOLD}WARNING:${NC} ${H_YELLOW}$1${NC}"; write_log "WARN" "$1"; }

error() {
    _ERROR_REPORTED=1
    echo ""
    echo -e "${H_RED}   ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e "${H_RED}   ┃  ERROR: $1${NC}"
    echo -e "${H_RED}   ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    echo ""
    write_log "ERROR" "$1"
}

# 核心命令执行器：可视化 + 日志 + dry-run 拦截
# dry-run 下返回 99（DRY_RUN_RC）以便调用方区分"未实际安装"与"真成功"
DRY_RUN_RC=99
exe() {
    local full_command="$*"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "   ${H_GRAY}│${NC} ${H_YELLOW}[DRY-RUN]${NC} ${BOLD}$full_command${NC}"
        write_log "DRYRUN" "$full_command"
        return "$DRY_RUN_RC"
    fi
    echo -e "   ${H_GRAY}┌──[ ${H_MAGENTA}EXEC${H_GRAY} ]────────────────────────────────────────────────────${NC}"
    echo -e "   ${H_GRAY}│${NC} ${H_CYAN}$ ${NC}${BOLD}$full_command${NC}"
    write_log "EXEC" "$full_command"
    "$@"
    local status=$?
    if [ $status -eq 0 ]; then
        echo -e "   ${H_GRAY}└──────────────────────────────────────────────────────── ${H_GREEN}OK${H_GRAY} ─┘${NC}"
    else
        echo -e "   ${H_GRAY}└────────────────────────────────────────────────────── ${H_RED}FAIL${H_GRAY} ─┘${NC}"
        write_log "FAIL" "Exit Code: $status ($full_command)"
        return $status
    fi
}

# 带超时的确认提示: confirm "问题" [默认Y|N] [超时秒]
# 返回 0 = 是, 1 = 否
confirm() {
    local prompt="$1" default="${2:-Y}" timeout="${3:-30}" ans
    echo -ne "   ${H_CYAN}${prompt} ${NC}"
    if ! read -t "$timeout" -r ans; then echo ""; fi
    ans=${ans:-$default}
    [[ "$ans" =~ ^[Yy] ]]
}

# ==============================================================================
# 2. 数据区 —— niri 套件定义（唯一权威清单，export/restore 共用）
# ==============================================================================

GROUP_ORDER=(core lock wallpaper clip media audio ime fonts keyring)

declare -A GROUP_ZH=(
    [core]="核心组件"
    [lock]="锁屏/空闲"
    [wallpaper]="壁纸"
    [clip]="剪贴板/截图"
    [media]="媒体/亮度"
    [audio]="音频"
    [ime]="输入法"
    [fonts]="字体"
    [keyring]="密钥环"
)

# AUR: 前缀表示该包需要用 AUR helper (yay) 安装
declare -A GROUP_PKGS=(
    [core]="niri waybar mako fuzzel kitty polkit-gnome xwayland-satellite xdg-desktop-portal-gnome wl-clipboard libnotify zsh"
    [lock]="hyprlock hypridle"
    [wallpaper]="awww AUR:waypaper"
    [clip]="copyq satty"
    [media]="playerctl brightnessctl"
    [audio]="pipewire-pulse wireplumber"
    [ime]="fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt fcitx5-rime AUR:rime-ice-pinyin-git"
    [fonts]="ttf-jetbrains-mono-nerd wqy-zenhei"
    [keyring]="gnome-keyring"
)

# pkg -> 分组 反查表（运行时构建）
declare -A PKG_GROUP=()
for _g in "${GROUP_ORDER[@]}"; do
    for _p in ${GROUP_PKGS[$_g]:-}; do
        PKG_GROUP["${_p#AUR:}"]="$_g"
    done
done
unset _g _p

# 配置采集白名单（~/.config 下的目录）+ 家目录散文件
CONFIG_DIRS=(niri waybar mako kitty hypr copyq satty waypaper fcitx5 fcitx environment.d xdg-desktop-portal gtk-3.0 gtk-4.0)
CONFIG_FILES=(.pam_environment)

# 服务 -> 提供包 映射（export 时按 is-enabled 过滤后写入 services.txt）
SVC_ORDER=(bluetooth.service libvirtd.service power-profiles-daemon.service)
declare -A SVC_PROVIDER=(
    [bluetooth.service]=bluez
    [libvirtd.service]=libvirt
    [power-profiles-daemon.service]=power-profiles-daemon
)

# --- Arch -> RHEL 系 翻译层 ---
# 改名映射
declare -A RHEL_MAP=(
    [ttf-jetbrains-mono-nerd]=jetbrains-mono-nerd-fonts
    [wqy-zenhei]=wqy-zenhei-fonts
    [pipewire-pulse]=pipewire-pulseaudio
)
# RHEL 系无官方包 -> 进"需手动安装"报告（值为原因/建议）
declare -A RHEL_MANUAL=(
    [awww]="无官方 RPM；可 cargo install --git https://github.com/LGFae/awww 或下载 release 二进制"
    [satty]="无官方 RPM；可 cargo install satty"
    [rime-ice-pinyin-git]="雾凇拼音需手动部署词库到 ~/.local/share/fcitx5/rime"
    [ly]="仅 Arch 提供；RHEL 系建议 gdm/sddm，或 tty 登录后执行 niri-session"
)
# 可用 pip 兜底安装的
declare -A RHEL_PIP=(
    [waypaper]=waypaper
)

# 汇总报告收集器
INSTALLED_PKGS=() SKIPPED_PKGS=() FAILED_PKGS=() MANUAL_ITEMS=() ENABLED_SVCS=()
DRY_PKGS=() DRY_SVCS=()  # dry-run 模式下"将执行"的项，分开汇总避免虚高

# ==============================================================================
# 3. export 模式 —— 采集快照（普通用户运行；只扫描+复制，不改系统）
# ==============================================================================

do_export() {
    init_logger
    if [ "$EUID" -eq 0 ]; then
        error "$(_t "export 需要以【普通用户】运行（要读取你的 ~/.config），不要用 sudo。" "export must run as normal user (needs ~/.config), do not use sudo.")"
        exit 1
    fi

    local SNAP_PKGLIST="$BASE_DIR/pkglist"
    local SNAP_CONFIG="$BASE_DIR/config"

    section "Export" "$(_t "采集 niri 套件快照" "Collect Niri Suite Snapshot")"
    info_kv "$(_t "快照目录" "Snapshot Dir")" "$BASE_DIR"

    # --- 3.1 包清单 ---
    log "$(_t "扫描已安装的 niri 套件软件包..." "Scanning installed niri suite packages...")"
    mkdir -p "$SNAP_PKGLIST"
    : > "$SNAP_PKGLIST/official.txt"
    : > "$SNAP_PKGLIST/aur.txt"

    local missing=()
    for g in "${GROUP_ORDER[@]}"; do
        for raw in ${GROUP_PKGS[$g]:-}; do
            local p="${raw#AUR:}"
            if ! pacman -Qq "$p" &>/dev/null; then
                missing+=("$p")
                continue
            fi
            if [[ "$raw" == AUR:* ]] || pacman -Qqm "$p" &>/dev/null; then
                echo "$p" >> "$SNAP_PKGLIST/aur.txt"
            else
                echo "$p" >> "$SNAP_PKGLIST/official.txt"
            fi
        done
    done
    sort -u -o "$SNAP_PKGLIST/official.txt" "$SNAP_PKGLIST/official.txt"
    sort -u -o "$SNAP_PKGLIST/aur.txt" "$SNAP_PKGLIST/aur.txt"
    info_kv "$(_t "官方仓库包" "Official pkgs")" "$(wc -l < "$SNAP_PKGLIST/official.txt") 个"
    info_kv "$(_t "AUR 包" "AUR pkgs")" "$(wc -l < "$SNAP_PKGLIST/aur.txt") 个"
    if [ ${#missing[@]} -gt 0 ]; then
        warn "$(_t "以下清单内软件包当前未安装，未写入快照:" "The following packages are not installed, not written to snapshot:")${missing[*]}"
    fi

    # --- 3.2 服务清单 ---
    log "$(_t "扫描已启用的系统服务..." "Scanning enabled system services...")"
    : > "$SNAP_PKGLIST/services.txt"
    for unit in "${SVC_ORDER[@]}"; do
        if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            echo "$unit ${SVC_PROVIDER[$unit]}" >> "$SNAP_PKGLIST/services.txt"
            log "  $(_t "[enabled]" "[enabled]") $unit"
        fi
    done
    info_kv "$(_t "服务" "Services")" "$(wc -l < "$SNAP_PKGLIST/services.txt") 项"

    # --- 3.3 配置镜像 ---
    log "$(_t "复制桌面配置（白名单）..." "Copying desktop config (whitelist)...")"
    rm -rf "$SNAP_CONFIG"
    mkdir -p "$SNAP_CONFIG/.config"

    for d in "${CONFIG_DIRS[@]}"; do
        if [ -d "$HOME/.config/$d" ]; then
            cp -r "$HOME/.config/$d" "$SNAP_CONFIG/.config/$d"
            log "  $(_t "[config]" "[config]") ~/.config/$d"
        else
            warn "  $(_t "[skip]" "[skip]") ~/.config/$d 不存在"
        fi
    done
    for f in "${CONFIG_FILES[@]}"; do
        if [ -f "$HOME/$f" ]; then
            cp "$HOME/$f" "$SNAP_CONFIG/$f"
            log "  $(_t "[config]" "[config]") ~/$f"
        fi
    done

    # 清理无用的缓存目录（不进入快照）
    rm -rf "$SNAP_CONFIG/.config/mako/__pycache__" 2>/dev/null

    # --- 3.4 修正快照副本中的已知笔误（不碰 live 配置）---
    local NIRI_KDL="$SNAP_CONFIG/.config/niri/config.kdl"
    if [ -f "$NIRI_KDL" ] && [ "$KEEP_TYPOS" -eq 0 ]; then
        local fixed=()
        if grep -q "swww-daemon" "$NIRI_KDL"; then
            sed -i 's/swww-daemon/awww-daemon/g' "$NIRI_KDL"
            fixed+=("swww-daemon -> awww-daemon")
        fi
        if grep -q "authenntication" "$NIRI_KDL"; then
            sed -i 's/authenntication/authentication/g' "$NIRI_KDL"
            fixed+=("polkit-gnome-authenntication -> polkit-gnome-authentication")
        fi
        if [ ${#fixed[@]} -gt 0 ]; then
            warn "$(_t "已在快照副本中修正配置笔误（live 配置未改动；--keep-typos 可关闭此行为）:" "Fixed typos in snapshot copy (live config unchanged; --keep-typos to disable):")"
            for fx in "${fixed[@]}"; do echo -e "     ${H_YELLOW}· $fx${NC}"; done
            write_log "FIX" "${fixed[*]}"
        fi
    fi

    section "$(_t "Export 完成" "Export Done")" "$(_t "快照已生成" "Snapshot Created")"
    info_kv "$(_t "包清单" "Pkglist")" "$SNAP_PKGLIST/"
    info_kv "$(_t "配置镜像" "Config Mirror")" "$SNAP_CONFIG/"
    log "下一步: 把整个 eilNiri 目录带到新机器，运行 ${BOLD}sudo ./replicate.sh restore${NC}"
}

# ==============================================================================
# 4. restore 模式 —— 在新系统重现（root 运行）
# ==============================================================================

DISTRO_FAMILY=""   # arch | rhel
TARGET_USER=""
HOME_DIR=""

# --- 4.0 基础 ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "$(_t "restore 需要 root 权限，请使用: sudo ./replicate.sh restore" "restore requires root. Use: sudo ./replicate.sh restore")"
        exit 1
    fi
}

detect_distro() {
    local id_like="" id=""
    if [ -f /etc/os-release ]; then
        id=$(. /etc/os-release; echo "${ID:-}")
        id_like=$(. /etc/os-release; echo "${ID_LIKE:-}")
    fi
    case " $id $id_like " in
        *arch*|*manjaro*|*endeavouros*) DISTRO_FAMILY=arch ;;
        *rhel*|*fedora*|*centos*)       DISTRO_FAMILY=rhel ;;
        *)
            error "无法识别的发行版 (ID=$id ID_LIKE=$id_like)。仅支持 Arch 系与 RHEL 系。"
            exit 1
            ;;
    esac
    info_kv "$(_t "发行版家族" "Distro")" "$DISTRO_FAMILY" "(ID=$id)"
}

pkg_installed() { # $1 = 包名
    if [ "$DISTRO_FAMILY" = arch ]; then
        pacman -Qi "$1" &>/dev/null
    else
        rpm -q "$1" &>/dev/null
    fi
}

pm_install() { # $@ = 包名
    if [ "$DISTRO_FAMILY" = arch ]; then
        exe pacman -S --noconfirm --needed "$@"
    else
        exe dnf install -y "$@"
    fi
}

as_user() {
    runuser -u "$TARGET_USER" -- "$@"
}

# 断点续装（dry-run 不读写进度文件）
stage_done() { [ "$DRY_RUN" -eq 1 ] && return 1; grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
stage_mark() { [ "$DRY_RUN" -eq 1 ] && return 0; echo "$1" >> "$STATE_FILE"; }

# 目标用户检测（参考 detect_target_user，简化版）
detect_target_user() {
    local uid1000
    uid1000=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd | head -n 1)
    mapfile -t HUMAN_USERS < <(awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd)

    # dry-run：跳过交互，直接选 UID 1000 / 第一个普通用户
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ ${#HUMAN_USERS[@]} -gt 0 ]; then
            TARGET_USER="${uid1000:-${HUMAN_USERS[0]}}"
            log "$(_t "[DRY-RUN] 自动选择目标用户:" "[DRY-RUN] auto-selecting target user: ") $TARGET_USER"
        else
            TARGET_USER="eilniri-dryrun"
            log "$(_t "[DRY-RUN] 未检测到普通用户，使用占位用户名:" "[DRY-RUN] no regular users found, using placeholder: ") $TARGET_USER"
        fi
        HOME_DIR=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)
        [ -z "$HOME_DIR" ] && HOME_DIR="/home/$TARGET_USER"
        export TARGET_USER HOME_DIR
        info_kv "$(_t "目标用户" "Target User")" "$TARGET_USER" "($HOME_DIR)"
        return
    fi

    if [ ${#HUMAN_USERS[@]} -gt 0 ]; then
        local default_user="${uid1000:-${HUMAN_USERS[0]}}"
        echo -e "   ${H_YELLOW}$(_t ">>> 检测到已有用户，选择配置部署目标:" ">>> Existing users found, select target:")${NC}"
        local i
        for i in "${!HUMAN_USERS[@]}"; do
            local mark=""
            [ "${HUMAN_USERS[$i]}" = "$default_user" ] && mark="${H_CYAN}*${NC}"
            echo -e "       [$((i+1))] ${mark}${HUMAN_USERS[$i]}"
        done
        echo -e "       [0] ${H_GREEN}$(_t "创建新用户 ++" "Create New User ++")${NC}"

        local idx
        while true; do
            echo -ne "   ${H_CYAN}$(_t "输入序号 [0-${#HUMAN_USERS[@]}] (默认 ${default_user}, 30s 超时): " "Enter number [0-${#HUMAN_USERS[@]}] (default ${default_user}, 30s timeout): ")${NC}"
            if ! read -t 30 -r idx; then
                echo ""
                TARGET_USER="$default_user"
                log "$(_t "超时，自动选择默认用户:" "Timeout, auto-selecting: ")$TARGET_USER"
                break
            fi
            if [ -z "$idx" ]; then TARGET_USER="$default_user"; break; fi
            if [ "$idx" = "0" ]; then TARGET_USER=""; break; fi
            if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#HUMAN_USERS[@]}" ]; then
                TARGET_USER="${HUMAN_USERS[$((idx-1))]}"
                break
            fi
            warn "$(_t "无效输入。" "Invalid input.")"
        done
    fi

    if [ -z "$TARGET_USER" ]; then
        local new_user
        while true; do
            echo -ne "   ${H_GREEN}$(_t "输入要创建的新用户名: " "Enter new username: ")${NC} "
            read -r new_user
            if [[ "$new_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                if exe useradd -m -s /bin/bash "$new_user"; then
                    TARGET_USER="$new_user"
                    warn "请随后用 passwd $new_user 设置密码。"
                    break
                fi
                warn "$(_t "用户创建失败（可能已存在），请重试。" "User creation failed (may already exist), retry.")"
                continue
            fi
            warn "$(_t "用户名格式非法。" "Invalid username format.")"
        done
    fi

    HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    # dry-run 下新用户尚未真正创建，getent 为空时回退默认家目录路径
    [ -z "$HOME_DIR" ] && HOME_DIR="/home/$TARGET_USER"
    export TARGET_USER HOME_DIR
    info_kv "$(_t "目标用户" "Target User")" "$TARGET_USER" "($HOME_DIR)"
}

ensure_fzf() {
    if command -v fzf &>/dev/null; then return 0; fi
    log "$(_t "安装交互菜单依赖: fzf ..." "Installing interactive menu dependency: fzf ...")"
    local _saved_dry="$DRY_RUN"
    DRY_RUN=0  # fzf 是交互前提，必须实际装（即使在 --dry-run 下）
    pm_install fzf || { error "$(_t "fzf 安装失败，无法继续。" "fzf install failed, cannot continue.")"; exit 1; }
    DRY_RUN="$_saved_dry"
}

# fzf 多选（参考 99-apps.sh：默认全选 / TAB 切换 / Ctrl-A 全选 / Ctrl-D 全不选）
#  stdin: "字段1\t字段2" 行；stdout: 用户选中的行
fzf_multi() {
    fzf --multi --layout=reverse --border=rounded --margin=1,2 \
        --delimiter=$'\t' --with-nth=1,2 \
        --bind 'load:select-all' \
        --bind 'ctrl-a:select-all,ctrl-d:deselect-all,j:down,k:up' \
        --pointer=">" --marker="* " --ansi \
        --header="$1"
}

# fzf 单选（回滚等场景：不预选，TAB/Ctrl-D 无意义）
fzf_single() {
    fzf --layout=reverse --border=rounded --margin=1,2 \
        --delimiter=$'\t' --with-nth=1,2 \
        --pointer=">" --marker="" --ansi \
        --header="$1"
}

# --- 4.1 Pre-flight ---

stage_preflight() {
    section "$(_t "Pre-Flight" "Pre-Flight")" "$(_t "系统更新" "System Update")"
    if stage_done preflight; then
        log "$(_t "Pre-flight 已完成，跳过（删除 .replicate_progress 可强制重跑）。" "Pre-flight done, skipping (delete .replicate_progress to force rerun).")"
        return
    fi
    if [ "$DISTRO_FAMILY" = arch ]; then
        exe pacman -Sy --noconfirm archlinux-keyring || warn "$(_t "keyring 刷新失败，继续尝试。" "keyring refresh failed, continuing.")"
        if ! exe pacman -Su --noconfirm; then
            error "$(_t "系统更新失败，请检查网络。" "System update failed. Check network.")"
            exit 1
        fi
    else
        if ! exe dnf -y upgrade --refresh; then
            warn "$(_t "系统更新未完全成功，继续尝试安装。" "System update partially failed, continuing.")"
        fi
    fi
    success "$(_t "系统已就绪。" "System ready.")"
    stage_mark preflight
}

# --- 4.2 应用选择 ---

REPO_UNIVERSE=() AUR_UNIVERSE=()

load_app_universe() {
    # 优先使用 export 快照清单（用户可手改），否则回退到内置权威清单
    local off="$BASE_DIR/pkglist/official.txt" aur="$BASE_DIR/pkglist/aur.txt"
    if [ -s "$off" ] || [ -s "$aur" ]; then
        log "$(_t "使用快照清单: pkglist/" "Using snapshot pkglist: pkglist/")"
        [ -s "$off" ] && mapfile -t REPO_UNIVERSE < <(sed '/^\s*$/d' "$off")
        [ -s "$aur" ] && mapfile -t AUR_UNIVERSE < <(sed '/^\s*$/d' "$aur")
    else
        log "$(_t "未找到快照清单，使用内置 niri 套件清单。" "No snapshot pkglist, using built-in list.")"
        local g raw
        for g in "${GROUP_ORDER[@]}"; do
            for raw in ${GROUP_PKGS[$g]:-}; do
                if [[ "$raw" == AUR:* ]]; then
                    AUR_UNIVERSE+=("${raw#AUR:}")
                else
                    REPO_UNIVERSE+=("$raw")
                fi
            done
        done
    fi
}

group_tag() { # $1 = pkg
    local g="${PKG_GROUP[$1]:-}"
    if [ -n "$g" ]; then echo "[${GROUP_ZH[$g]}]"; else echo "[快照]"; fi
}

stage_apps_select() {
    section "$(_t "应用选择" "App Selection")" "$(_t "TAB 切换 | 默认全选 | Ctrl-D 全不选 | Enter 确认" "TAB toggle | Select All | Ctrl-D deselect | Enter")"
    load_app_universe

    # 中文组件选择
    if ! confirm "$(_t "安装中文输入法（fcitx5+rime）和中文字体（wqy-zenhei）？[Y/n] (默认 Y, 15s):" "Install Chinese IME (fcitx5+rime) and font (wqy-zenhei)? [Y/n] (default Y, 15s):")" "Y" 15; then
        local _cn_exclude=(fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt fcitx5-rime rime-ice-pinyin-git wqy-zenhei)
        local _tmp_arr=() _p
        for _p in ${REPO_UNIVERSE[@]+"${REPO_UNIVERSE[@]}"}; do
            local _keep=1 _ex
            for _ex in "${_cn_exclude[@]}"; do
                [ "$_p" = "$_ex" ] && { _keep=0; break; }
            done
            [ "$_keep" -eq 1 ] && _tmp_arr+=("$_p")
        done
        REPO_UNIVERSE=("${_tmp_arr[@]}")
        _tmp_arr=()
        for _p in ${AUR_UNIVERSE[@]+"${AUR_UNIVERSE[@]}"}; do
            local _keep=1 _ex
            for _ex in "${_cn_exclude[@]}"; do
                [ "$_p" = "$_ex" ] && { _keep=0; break; }
            done
            [ "$_keep" -eq 1 ] && _tmp_arr+=("$_p")
        done
        AUR_UNIVERSE=("${_tmp_arr[@]}")
    fi

    local lines=() p
    for p in ${REPO_UNIVERSE[@]+"${REPO_UNIVERSE[@]}"}; do
        lines+=("$p"$'\t'"$(group_tag "$p")")
    done
    for p in ${AUR_UNIVERSE[@]+"${AUR_UNIVERSE[@]}"}; do
        lines+=("AUR:$p"$'\t'"$(group_tag "$p")")
    done

    # dry-run：跳过 fzf 交互，直接全选（与 fzf load:select-all 默认行为一致）
    if [ "$DRY_RUN" -eq 1 ]; then
        REPO_SEL=("${REPO_UNIVERSE[@]}")
        AUR_SEL=("${AUR_UNIVERSE[@]}")
        log "$(_t "[DRY-RUN] 自动全选所有应用: 仓库 ${#REPO_SEL[@]} 个, AUR ${#AUR_SEL[@]} 个" "[DRY-RUN] auto-selected all: ${#REPO_SEL[@]} repo, ${#AUR_SEL[@]} AUR")"
        info_kv "$(_t "已选" "Selected")" "仓库 ${#REPO_SEL[@]} 个" "AUR ${#AUR_SEL[@]} 个"
        return 0
    fi

    # 空清单守卫：fzf 空输入会返回非零且无提示，直接跳过避免误报"用户中止"
    if [ ${#lines[@]} -eq 0 ]; then
        warn "$(_t "可用软件包列表为空，跳过应用安装阶段。" "Package list is empty, skipping app install.")"
        return 1
    fi

    local selected
    selected=$(printf "%s\n" "${lines[@]}" | fzf_multi " 选择要安装的 niri 套件应用 ") || {
        error "$(_t "用户中止选择。" "User aborted selection.")"
        exit 130
    }
    if [ -z "$selected" ]; then
        warn "$(_t "未选择任何应用，跳过安装阶段。" "No apps selected, skipping install.")"
        return 1
    fi

    REPO_SEL=() AUR_SEL=()
    local raw
    while IFS= read -r raw; do
        local name
        name=$(echo "$raw" | cut -f1 -d"$(printf '\t')" | xargs)
        [ -z "$name" ] && continue
        if [[ "$name" == AUR:* ]]; then
            AUR_SEL+=("${name#AUR:}")
        else
            REPO_SEL+=("$name")
        fi
    done <<< "$selected"
    info_kv "$(_t "已选" "Selected")" "仓库 ${#REPO_SEL[@]} 个" "AUR ${#AUR_SEL[@]} 个"
    return 0
}

# --- 4.3 应用安装 ---

setup_temp_sudo() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    local f="/etc/sudoers.d/99_eilniri_installer"
    echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" > "$f"
    chmod 440 "$f"
    register_temp_path "$f"
}

ensure_yay() {
    if command -v yay &>/dev/null; then return 0; fi
    log "$(_t "安装 AUR helper: yay ..." "Installing AUR helper: yay ...")"
    pm_install base-devel git || { error "$(_t "base-devel/git 安装失败。" "base-devel/git install failed.")"; return 1; }
    local build_dir="/tmp/yay-bin-build-$$"
    register_temp_path "$build_dir"
    if [ "$DRY_RUN" -eq 0 ]; then
        as_user git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$build_dir" || return 1
        ( cd "$build_dir" && as_user makepkg -si --noconfirm ) || return 1
    else
        DRY_PKGS+=("yay-bin (AUR helper)")
        log "$(_t "[DRY-RUN] git clone yay-bin && makepkg -si" "[DRY-RUN] git clone yay-bin && makepkg -si")"
        return 0
    fi
}

install_arch() {
    local p
    # --- 仓库包: 批量装，失败则逐个隔离 ---
    local queue=()
    for p in ${REPO_SEL[@]+"${REPO_SEL[@]}"}; do
        if pkg_installed "$p"; then
            SKIPPED_PKGS+=("$p (已安装)")
        else
            queue+=("$p")
        fi
    done
    if [ ${#queue[@]} -gt 0 ]; then
        local rc=0
        pm_install "${queue[@]}" || rc=$?
        if [ "$rc" -eq 0 ]; then
            INSTALLED_PKGS+=("${queue[@]}")
        elif [ "$rc" -eq "$DRY_RUN_RC" ]; then
            DRY_PKGS+=("${queue[@]}")
        else
            warn "$(_t "批量安装失败，切换为逐个安装以隔离问题包..." "Batch install failed, switching to individual installs...")"
            for p in "${queue[@]}"; do
                local prc=0
                pm_install "$p" || prc=$?
                if [ "$prc" -eq 0 ]; then
                    INSTALLED_PKGS+=("$p")
                elif [ "$prc" -eq "$DRY_RUN_RC" ]; then
                    DRY_PKGS+=("$p")
                else
                    FAILED_PKGS+=("repo:$p")
                fi
            done
        fi
    fi

    # --- AUR 包: 逐个装 + 重试 1 次 ---
    if [ ${#AUR_SEL[@]} -gt 0 ]; then
        ensure_yay || { FAILED_PKGS+=("${AUR_SEL[@]/#/aur:}"); return; }
        for p in "${AUR_SEL[@]}"; do
            if pkg_installed "$p"; then
                SKIPPED_PKGS+=("$p (已安装)")
                continue
            fi
            local ok=false i
            for i in 0 1; do
                [ "$i" -gt 0 ] && warn "重试 $i/1: $p"
                local erc=0
                exe as_user yay -S --noconfirm --needed "$p" || erc=$?
                if [ "$erc" -eq 0 ]; then
                    ok=true; INSTALLED_PKGS+=("$p"); break
                elif [ "$erc" -eq "$DRY_RUN_RC" ]; then
                    ok=true; DRY_PKGS+=("$p"); break
                fi
            done
            [ "$ok" = false ] && FAILED_PKGS+=("aur:$p")
        done
    fi
}

install_rhel() {
    local p name erc
    local all=(${REPO_SEL[@]+"${REPO_SEL[@]}"} ${AUR_SEL[@]+"${AUR_SEL[@]}"})

    # pip 兜底前置检查（仅一次）：确保 python3-pip 与 pip3 在循环开始前就位
    local has_pip_target=0
    for p in "${all[@]}"; do
        if [ -n "${RHEL_PIP[$p]:-}" ]; then has_pip_target=1; break; fi
    done
    if [ "$has_pip_target" -eq 1 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            DRY_PKGS+=("python3-pip")
        else
            pm_install python3-pip
        fi
        if [ "$DRY_RUN" -eq 0 ] && ! command -v pip3 &>/dev/null; then
            MANUAL_ITEMS+=("python3-pip —— pip3 未安装，请先: sudo dnf install python3-pip")
        fi
    fi

    for p in ${all[@]+"${all[@]}"}; do
        # 1) 无对应包 -> 手动报告
        if [ -n "${RHEL_MANUAL[$p]:-}" ]; then
            MANUAL_ITEMS+=("$p —— ${RHEL_MANUAL[$p]}")
            continue
        fi
        # 2) pip 兜底
        if [ -n "${RHEL_PIP[$p]:-}" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                DRY_PKGS+=("$p (pip)")
                continue
            fi
            if ! command -v pip3 &>/dev/null; then
                MANUAL_ITEMS+=("$p —— pip3 未安装，请先: sudo dnf install python3-pip")
                continue
            fi
            erc=0
            exe as_user pip3 install --user "${RHEL_PIP[$p]}" || erc=$?
            if [ "$erc" -eq 0 ]; then
                INSTALLED_PKGS+=("$p (pip)")
            else
                MANUAL_ITEMS+=("$p —— pip 安装失败，请手动: pip3 install --user ${RHEL_PIP[$p]}")
            fi
            continue
        fi
        # 3) 翻译 + dnf 安装
        name="${RHEL_MAP[$p]:-$p}"
        if pkg_installed "$name"; then
            SKIPPED_PKGS+=("$name (已安装)")
            continue
        fi
        erc=0
        pm_install "$name" || erc=$?
        if [ "$erc" -eq 0 ]; then
            INSTALLED_PKGS+=("$name")
        elif [ "$erc" -eq "$DRY_RUN_RC" ]; then
            DRY_PKGS+=("$name")
        else
            FAILED_PKGS+=("dnf:$name")
        fi
    done
}

stage_apps_install() {
    if stage_done apps; then
        log "$(_t "应用安装阶段已完成，跳过。" "App install stage done, skipping.")"
        return
    fi
    section "$(_t "应用安装" "App Install")" "$DISTRO_FAMILY 系"
    if [ "$DISTRO_FAMILY" = arch ]; then
        install_arch
    else
        install_rhel
    fi
    stage_mark apps
}

# --- 4.4 系统服务 ---

stage_services() {
    if stage_done services; then
        log "$(_t "服务启用阶段已完成，跳过。" "Service stage done, skipping.")"
        return
    fi
    local svc_file="$BASE_DIR/pkglist/services.txt"
    if [ ! -s "$svc_file" ]; then
        warn "$(_t "未找到 services.txt，跳过服务启用。" "services.txt not found, skipping.")"
        return
    fi

    section "$(_t "服务启用" "Services")" "$(_t "选择要启用的系统服务" "Select services to enable")"
    local selected
    selected=$(awk '{print $1 "\t提供包: " $2}' "$svc_file" | \
        fzf_multi " 选择要启用的服务 ") || {
        warn "$(_t "用户取消服务选择，跳过服务启用。" "User cancelled service selection, skipping.")"
        return
    }
    if [ -z "$selected" ]; then
        warn "$(_t "未选择任何服务。" "No services selected.")"
        return
    fi

    local line unit provider erc
    local any_failed=0
    while IFS= read -r line; do
        unit=$(echo "$line" | cut -f1 -d"$(printf '\t')" | xargs)
        [ -z "$unit" ] && continue
        provider=$(grep -m1 "^$unit " "$svc_file" | awk '{print $2}')

        # 提供包未装则补装
        if [ -n "$provider" ] && ! pkg_installed "$provider"; then
            log "$(_t "补装服务提供包:" "Installing service provider: ")$provider"
            erc=0
            pm_install "$provider" || erc=$?
            if [ "$erc" -ne 0 ] && [ "$erc" -ne "$DRY_RUN_RC" ]; then
                FAILED_PKGS+=("svc-provider:$provider")
                any_failed=1
                continue
            fi
            [ "$erc" -eq "$DRY_RUN_RC" ] && DRY_PKGS+=("$provider")
        fi

        erc=0
        exe systemctl enable --now "$unit" || erc=$?
        if [ "$erc" -eq 0 ]; then
            ENABLED_SVCS+=("$unit")
        elif [ "$erc" -eq "$DRY_RUN_RC" ]; then
            DRY_SVCS+=("$unit")
        else
            FAILED_PKGS+=("service:$unit")
            any_failed=1
        fi
        # libvirtd 附带 socket 一并启用（若存在）
        if [ "$unit" = libvirtd.service ]; then
            for sock in libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket virtlogd.socket virtlockd.socket; do
                exe systemctl enable "$sock" 2>/dev/null || true
            done
        fi
    done <<< "$selected"

    # 只有本阶段无失败时才标记完成；否则留给下次重试
    if [ "$any_failed" -eq 0 ]; then
        stage_mark services
    else
        warn "$(_t "服务启用阶段存在失败，未标记完成，下次运行将重试。" "Service stage has failures, not marked complete. Will retry.")"
    fi
}

# --- 4.5 显示管理器 ly（仅 Arch，默认不装）---

stage_dm() {
    if stage_done dm; then return; fi
    if [ "$DISTRO_FAMILY" != arch ]; then
        stage_mark dm
        return
    fi

    section "$(_t "显示管理器" "Display Manager")" "$(_t "ly（可选）" "ly (optional)")"
    local known_dms=(gdm sddm lightdm lxdm ly greetd plasma-login-manager lemurs)
    local dm found=""
    for dm in "${known_dms[@]}"; do
        if pkg_installed "$dm"; then found="$dm"; break; fi
    done

    if [ -n "$found" ]; then
        info_kv "$(_t "DM 冲突" "DM Conflict")" "$found" "已存在，跳过 ly"
    elif [ "$DRY_RUN" -eq 1 ]; then
        # dry-run：跳过交互默认 N；告知用户若想装可去掉 --dry-run
        log "$(_t "[DRY-RUN] 跳过 ly 安装（默认 N）。若需实际安装，请去掉 --dry-run 重跑。" "[DRY-RUN] skipping ly (default N). Remove --dry-run to install.")"
        DRY_SVCS+=("ly@tty1")
    elif confirm "$(_t "安装并启用 ly 显示管理器？[y/N] (默认 N, 20s):" "Install & enable ly DM? [y/N] (default N, 20s):")" "N" 20; then
        if pm_install ly && exe systemctl enable ly@tty1; then
            ENABLED_SVCS+=("ly@tty1")
        else
            FAILED_PKGS+=("dm:ly")
        fi
    else
        log "$(_t "跳过 ly。无显示管理器时，tty 登录后执行 niri-session 即可进桌面。" "Skipping ly. Without DM, run niri-session from tty.")"
    fi
    stage_mark dm
}

# --- 4.6 配置快照（部署前备份）---

stage_backup() {
    if stage_done backup; then return; fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "$(_t "[DRY-RUN] 跳过配置备份阶段。" "[DRY-RUN] Skipping config backup.")"
        stage_mark backup
        return
    fi

    section "$(_t "配置快照" "Config Snapshot")" "$(_t "部署前创建回滚点" "Create rollback point before deploy")"
    local snap_cfg="$BASE_DIR/config"
    if [ ! -d "$snap_cfg/.config" ]; then
        warn "$(_t "未找到 config/ 配置镜像，跳过备份。" "config/ mirror not found, skipping backup.")"
        stage_mark backup
        return
    fi

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local tgz="$BACKUP_DIR/snapshot-$ts.tar.gz"
    mkdir -p "$BACKUP_DIR"

    # 收集将被打包覆盖的现有配置路径
    local targets=()
    shopt -s nullglob dotglob
    local item name
    for item in "$snap_cfg/.config"/*; do
        name=$(basename "$item")
        [ -e "$HOME_DIR/.config/$name" ] && targets+=("$HOME_DIR/.config/$name")
    done
    for item in "$snap_cfg"/.*; do
        name=$(basename "$item")
        [[ "$name" = "." || "$name" = ".." || "$name" = ".config" ]] && continue
        [ -f "$item" ] && [ -e "$HOME_DIR/$name" ] && targets+=("$HOME_DIR/$name")
    done
    shopt -u nullglob dotglob

    if [ ${#targets[@]} -eq 0 ]; then
        log "$(_t "没有已有配置需要备份（目标为空），跳过。" "No existing config to backup, skipping.")"
    elif confirm "$(_t "备份当前已有配置到快照以备回滚？[Y/n] (默认 Y, 15s):" "Backup current config to snapshot? [Y/n] (default Y, 15s):")" "Y" 15; then
        if exe tar czf "$tgz" -C / "${targets[@]#/}" 2>/dev/null; then
            success "$(_t "快照已保存:" "Snapshot saved: ") $tgz"
            info_kv "$(_t "备份项数" "Backup Items")" "${#targets[@]} 个"
        else
            warn "$(_t "快照创建失败，将继续部署（无回滚点）。" "Snapshot creation failed, continuing without rollback point.")"
        fi
    else
        log "$(_t "跳过备份，继续部署。" "Skipping backup, continuing.")"
    fi
    stage_mark backup
}

# --- 4.7 配置部署 ---

deploy_one() { # $1 = 源路径, $2 = 目标路径
    local src="$1" dst="$2" ts="$3"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        log "$(_t "备份已有:" "Backup existing: ")$dst -> $dst.bak-$ts"
        exe mv "$dst" "$dst.bak-$ts"
    fi
    exe cp -r "$src" "$dst"
    exe chown -R "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$dst"
}

stage_configs() {
    if stage_done configs; then
        log "$(_t "配置部署阶段已完成，跳过。" "Config deploy stage done, skipping.")"
        return
    fi
    local snap="$BASE_DIR/config"
    if [ ! -d "$snap" ]; then
        warn "$(_t "未找到 config/ 配置镜像，跳过部署。" "config/ mirror not found, skipping deploy.")"
        return
    fi

    section "$(_t "配置部署" "Config Deploy")" "目标: $HOME_DIR"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)

    shopt -s nullglob dotglob
    local item name
    # ~/.config/<name>
    for item in "$snap/.config"/*; do
        name=$(basename "$item")
        deploy_one "$item" "$HOME_DIR/.config/$name" "$ts"
    done
    # 家目录散文件（如 .pam_environment）
    for item in "$snap"/.*; do
        name=$(basename "$item")
        [[ "$name" = "." || "$name" = ".." || "$name" = ".config" ]] && continue
        [ -f "$item" ] || continue
        deploy_one "$item" "$HOME_DIR/$name" "$ts"
    done
    shopt -u nullglob dotglob

    success "$(_t "配置部署完成。" "Config deploy complete.")"
    stage_mark configs
}

# --- 4.8 装后验证（对账 + 配置审计）---

stage_verify() {
    if stage_done verify; then return; fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "$(_t "[DRY-RUN] 跳过验证阶段。" "[DRY-RUN] Skipping verification.")"
        return
    fi

    section "$(_t "验证" "Verification")" "$(_t "安装对账 & 配置审计" "Install Audit & Config Audit")"
    local missing=()

    # 包对账
    local all_sel=(${REPO_SEL[@]+"${REPO_SEL[@]}"} ${AUR_SEL[@]+"${AUR_SEL[@]}"})
    if [ ${#all_sel[@]} -gt 0 ]; then
        if [ "$DISTRO_FAMILY" = arch ]; then
            local m
            m=$(pacman -T "${all_sel[@]}" 2>/dev/null) && true
            [ -n "$m" ] && mapfile -t missing <<< "$m"
        else
            local p name
            for p in "${all_sel[@]}"; do
                [ -n "${RHEL_MANUAL[$p]:-}" ] && continue
                name="${RHEL_MAP[$p]:-$p}"
                [ -n "${RHEL_PIP[$p]:-}" ] && continue
                pkg_installed "$name" || missing+=("$name")
            done
        fi
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        warn "$(_t "以下所选包未能装上:" "Selected packages failed to install:")"
        for p in "${missing[@]}"; do echo -e "     ${H_RED}->${NC} ${H_YELLOW}$p${NC}"; done
    else
        success "$(_t "所选软件包对账通过。" "Package audit passed.")"
    fi

    # 配置审计
    local cfg_errors=0 d
    for d in niri waybar kitty mako hypr; do
        if [ -e "$HOME_DIR/.config/$d" ]; then
            log "  [OK] $HOME_DIR/.config/$d"
        else
            echo -e "     ${H_RED}->${NC} ${H_YELLOW}$HOME_DIR/.config/$d 缺失${NC}"
            cfg_errors=$((cfg_errors+1))
        fi
    done
    [ "$cfg_errors" -eq 0 ] && success "$(_t "配置审计通过。" "Config audit passed.")" || warn "$cfg_errors 个关键配置目录缺失。"
    stage_mark verify
}

# --- 4.9 汇总报告 ---

print_summary() {
    section "$(_t "汇总报告" "Summary")" "$(_t "eilNiri restore" "eilNiri restore")"
    info_kv "$(_t "已安装包" "Installed")" "${#INSTALLED_PKGS[@]} 个"
    info_kv "$(_t "已跳过" "Skipped")" "${#SKIPPED_PKGS[@]} 个"
    info_kv "$(_t "已启用服务" "Enabled Services")" "${#ENABLED_SVCS[@]} 项"
    if [ ${#ENABLED_SVCS[@]} -gt 0 ]; then
        printf "     ${DIM}%s${NC}\n" "${ENABLED_SVCS[@]}"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info_kv "$(_t "[DRY-RUN] 将装包" "[DRY-RUN] Will install")" "${#DRY_PKGS[@]} 个"
        if [ ${#DRY_PKGS[@]} -gt 0 ]; then
            printf "     ${DIM}%s${NC}\n" "${DRY_PKGS[@]}"
        fi
        info_kv "$(_t "[DRY-RUN] 将启用服务" "[DRY-RUN] Will enable services")" "${#DRY_SVCS[@]} 项"
        if [ ${#DRY_SVCS[@]} -gt 0 ]; then
            printf "     ${DIM}%s${NC}\n" "${DRY_SVCS[@]}"
        fi
    fi
    if [ ${#FAILED_PKGS[@]} -gt 0 ]; then
        warn "失败 ${#FAILED_PKGS[@]} 项:"
        printf "     ${H_RED}->${NC} %s\n" "${FAILED_PKGS[@]}"
    fi
    if [ ${#MANUAL_ITEMS[@]} -gt 0 ]; then
        warn "需手动安装 ${#MANUAL_ITEMS[@]} 项:"
        printf "     ${H_YELLOW}->${NC} %s\n" "${MANUAL_ITEMS[@]}"
    fi
    echo ""
    info_kv "$(_t "日志" "Log")" "$TEMP_LOG_FILE"
    info_kv "$(_t "进度文件" "Progress File")" "$STATE_FILE" "(全部完成后可删除)"
    echo -e "   ${H_YELLOW}>>> 建议重启系统后进入 niri 桌面。${NC}"
}

do_restore() {
    init_logger
    check_root
    detect_distro

    section "$(_t "Restore" "Restore")" "$(_t "重现 niri 桌面环境" "Restore Niri Desktop")"
    [ "$DRY_RUN" -eq 1 ] && warn "$(_t "DRY-RUN 模式：只打印计划，不实际改动系统。" "DRY-RUN mode: printing plan only, no changes.")"

    # 先更新系统（新机器包数据库旧，直接装 fzf 可能失败）
    stage_preflight
    ensure_fzf
    detect_target_user

    # AUR 安装需要临时 sudo 权限（已在全局 cleanup 注册）
    if [ "$DISTRO_FAMILY" = arch ]; then
        setup_temp_sudo
    fi

    if stage_apps_select; then
        stage_apps_install
    fi
    stage_services
    stage_dm
    stage_backup
    stage_configs
    stage_verify
    print_summary
}

do_rollback() {
    init_logger
    check_root
    detect_distro
    detect_target_user

    section "$(_t "Rollback" "Rollback")" "$(_t "配置回滚" "Config Rollback")"
    if [ ! -d "$BACKUP_DIR" ]; then
        error "未找到任何快照（$BACKUP_DIR 不存在）。"
        exit 1
    fi

    local snapshots=()
    mapfile -t snapshots < <(find "$BACKUP_DIR" -maxdepth 1 -name 'snapshot-*.tar.gz' -printf '%T@ %f\n' 2>/dev/null | sort -rn | awk '{print $2}')
    if [ ${#snapshots[@]} -eq 0 ]; then
        error "$(_t "未找到任何快照文件。" "No snapshot files found.")"
        exit 1
    fi

    local lines=() s ts
    for s in "${snapshots[@]}"; do
        ts=$(stat -c '%Y' "$BACKUP_DIR/$s" 2>/dev/null)
        [ -z "$ts" ] && ts=0
        lines+=("$s"$'\t'"$(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '???')")
    done

    ensure_fzf
    local selected
    selected=$(printf "%s\n" "${lines[@]}" | fzf_single " 选择要恢复的快照 ") || {
        warn "$(_t "用户取消。" "User cancelled.")"
        return
    }
    if [ -z "$selected" ]; then
        warn "$(_t "未选择快照。" "No snapshot selected.")"
        return
    fi
    local snapshot
    snapshot=$(echo "$selected" | cut -f1 -d"$(printf '\t')" | head -1)

    section "$(_t "恢复中" "Restoring")" "$snapshot"
    if ! confirm "$(_t "确认从快照 ${snapshot} 恢复配置？[y/N] (默认 N, 15s):" "Confirm restore from snapshot ${snapshot}? [y/N] (default N, 15s):")" "N" 15; then
        log "$(_t "取消回滚。" "Rollback cancelled.")"
        return
    fi

    local tgz="$BACKUP_DIR/$snapshot"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local workdir
    workdir=$(mktemp -d)
    register_temp_path "$workdir"

    exe tar xzf "$tgz" -C "$workdir" || { error "$(_t "解包快照失败。" "Failed to extract snapshot.")"; exit 1; }

    local item name target
    shopt -s nullglob dotglob
    for item in "$workdir"/home/*/.config/*; do
        name=$(basename "$item")
        target="$HOME_DIR/.config/$name"
        if [ -e "$target" ] || [ -L "$target" ]; then
            exe mv "$target" "$target.bak-$ts"
        fi
        exe cp -r "$item" "$target"
        exe chown -R "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$target"
    done
    # 家目录散文件
    for item in "$workdir"/home/*/.*; do
        name=$(basename "$item")
        [[ "$name" = "." || "$name" = ".." ]] && continue
        target="$HOME_DIR/$name"
        [ -f "$item" ] || continue
        if [ -e "$target" ] || [ -L "$target" ]; then
            exe mv "$target" "$target.bak-$ts"
        fi
        exe cp "$item" "$target"
        exe chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$target"
    done
    shopt -u nullglob dotglob

    success "配置已从快照 $snapshot 恢复。原有配置备份为 .bak-$ts"
}

# ==============================================================================
# 5. main
# ==============================================================================

usage() {
    if [ "$TTY_MODE" = "1" ]; then
    cat <<'EOF'
eilNiri replicate.sh — niri desktop environment replication tool

Usage:
  ./replicate.sh export  [--keep-typos]   create snapshot (normal user, read-only)
  ./replicate.sh restore [--dry-run]      restore desktop on new system (root)
  ./replicate.sh rollback                 rollback from existing snapshot (root)
  ./replicate.sh --help                   show this help

Options:
  --dry-run      print plan only, no actual install/enable/deploy
  --keep-typos   keep config as-is during export, skip typo fixes

Workflow:
  1. On current Arch machine:   ./replicate.sh export
  2. Bring the eilNiri dir to new machine (git / USB / rsync)
  3. On new machine (Arch/RHEL): sudo ./replicate.sh restore
  4. Rollback config:            sudo ./replicate.sh rollback
EOF
    else
    cat <<'EOF'
eilNiri replicate.sh —— niri 桌面环境复制工具

用法:
  ./replicate.sh export  [--keep-typos]   采集快照（普通用户，只读系统不改动）
  ./replicate.sh restore [--dry-run]      在新系统重现桌面（需 root）
  ./replicate.sh rollback                 从已有快照回滚配置（需 root）
  ./replicate.sh --help                   显示本帮助

选项:
  --dry-run      restore 只打印将执行的操作，不实际安装/启用/部署
  --keep-typos   export 时保留配置原样，不修正已知笔误

流程:
  1. 在当前 Arch 机器:   ./replicate.sh export
  2. 把整个 eilNiri 目录带到新机器（git / U盘均可）
  3. 在新机器(Arch/RHEL系): sudo ./replicate.sh restore
  4. 回滚配置:           sudo ./replicate.sh rollback
EOF
    fi
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            export|restore|rollback) MODE="$arg" ;;
            --dry-run)      DRY_RUN=1 ;;
            --keep-typos)   KEEP_TYPOS=1 ;;
            -h|--help)      usage; exit 0 ;;
            *) error "$(_t "未知参数:" "Unknown argument: ") $arg"; usage; exit 1 ;;
        esac
    done

    case "$MODE" in
        export)   do_export ;;
        restore)  do_restore ;;
        rollback) do_rollback ;;
        *)        usage; exit 1 ;;
    esac
}

main "$@"
