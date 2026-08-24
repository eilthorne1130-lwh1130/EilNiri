#!/usr/bin/env bash
# ==============================================================================
# eilNiri - arch-install.sh
#
#   One-click niri desktop setup for a fresh Arch / Manjaro / EndeavourOS system.
#   Packages come from a built-in list and the script installs everything:
#   niri/awww/satty builds, rime-ice dictionary, display manager (replacing any
#   existing one), services and config deploy. Desktop config is optional and read
#   from the repo's configs/.config/ if you choose to ship any.
#
#   Usage:
#     ./arch-install.sh restore [--dry-run]     restore on new system (root)
#     ./arch-install.sh status                  show background build progress
#     ./arch-install.sh rollback                rollback config from backup (root)
#     ./arch-install.sh --help
#
#   Interaction style & visual engine reference: https://github.com/SHORiN-KiWATA/shorin-arch-setup
#   Snapshot rollback design reference:          https://github.com/ech678/NyxNiri
# ==============================================================================
echo "The author assumes no responsibility for any changes made to the server, computer, etc., and the author reserves the right of final interpretation."
set -uo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$BASE_DIR/.replicate_progress"
BACKUP_DIR="$BASE_DIR/backups"

declare -a CLEANUP_TEMP_PATHS=()
register_temp_path() { CLEANUP_TEMP_PATHS+=("$1"); }

# Background cargo build jobs (niri/awww): "name pid logfile srcdir"
BG_JOBS=()
BG_PENDING_RC=98   # installer return code when the build was spawned in background
bg_build_start() { # $1=name $2=srcdir $3=logfile $4...=command
    local name="$1" srcdir="$2" logfile="$3"
    shift 3
    log "$(_t "Background build started: " "Background build started: ") $name (log: $logfile)"
    ( "$@" ) >> "$logfile" 2>&1 &
    BG_JOBS+=("$name|$!|$logfile|$srcdir")
    echo "$name|$!|$logfile|$srcdir" >> "$BUILD_STATE_FILE"
}

cleanup() {
    local rc=$?
    local p
    # kill any background builds still running (they own temp dirs being removed below)
    local _entry _bpid
    for _entry in ${BG_JOBS[@]+"${BG_JOBS[@]}"}; do
        _bpid=$(echo "$_entry" | awk -F'|' '{print $2}')
        [ -n "$_bpid" ] && kill "$_bpid" 2>/dev/null
    done
    rm -f "$BUILD_STATE_FILE" 2>/dev/null
    for p in ${CLEANUP_TEMP_PATHS[@]+"${CLEANUP_TEMP_PATHS[@]}"}; do
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
_ERROR_REPORTED=0

# Script version — printed at startup so a stale copy on the target machine is easy to spot
SCRIPT_VERSION="1.9.26"

# Output is always English with ANSI colors (TTY/desktop detection removed).
# _t always returns the English (2nd) argument; kept as a thin translation helper.
_t() { echo "$2"; }

# ==============================================================================
# 1. Visual engine (see 00-utils.sh)
# ==============================================================================

export NC='\033[0m' BOLD='\033[1m' DIM='\033[2m'
export H_RED='\033[1;31m' H_GREEN='\033[1;32m' H_YELLOW='\033[1;33m'
export H_BLUE='\033[1;34m' H_PURPLE='\033[1;35m' H_CYAN='\033[1;36m'
export H_WHITE='\033[1;37m' H_GRAY='\033[1;90m' H_MAGENTA='\033[1;35m'

export TICK="${H_GREEN}✔${NC}"
export CROSS="${H_RED}✘${NC}"
export WARN_I="${H_YELLOW}⚠${NC}"
export ARROW="${H_CYAN}➜${NC}"

# Log dir: under sudo $HOME is /root, so use the real user's home (same as non-sudo export)
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
# Per-build state for ./arch-install.sh status (name|pid|logfile|srcdir per line)
export BUILD_STATE_FILE="$LOG_DIR/builds.state"

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

# Core command executor: visual + logging + dry-run interception
# In dry-run it returns 99 (DRY_RUN_RC) so callers can distinguish "not actually installed" from "really succeeded"
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

# Confirmation prompt with timeout: confirm "question" [default Y|N] [timeout sec]
# Returns 0 = yes, 1 = no
confirm() {
    local prompt="$1" default="${2:-Y}" timeout="${3:-30}" ans
    echo -ne "   ${H_CYAN}${prompt} ${NC}"
    if ! read -t "$timeout" -r ans; then echo ""; fi
    ans=${ans:-$default}
    [[ "$ans" =~ ^[Yy] ]]
}

show_logo() {
    echo ""
    echo -e "${H_PURPLE}"
    cat <<'LOGO'
  ███████╗ ██╗ ██╗        ███╗   ██╗ ██╗ ██████╗  ██╗
  ██╔════╝ ██║ ██║        ████╗  ██║ ██║ ██╔══██╗ ██║
  █████╗   ██║ ██║        ██╔██╗ ██║ ██║ ██████╔╝ ██║
  ██╔══╝   ██║ ██║        ██║╚██╗██║ ██║ ██╔══██╗ ██║
  ███████╗ ██║ ███████╗   ██║ ╚████║ ██║ ██║  ██║ ██║
  ╚══════╝ ╚═╝ ╚══════╝   ╚═╝  ╚═══╝ ╚═╝ ╚═╝  ╚═╝ ╚═╝
LOGO
    echo -e "${NC}"
    echo -e "       ${H_CYAN}Niri Desktop Environment — One-Click Setup${NC}"
    echo ""
}

# ==============================================================================
# 2. Data section — niri suite definition (single source of truth for export/restore)
# ==============================================================================

GROUP_ORDER=(core lock wallpaper clip media audio ime fonts keyring)

declare -A GROUP_EN=(
    [core]="Core"
    [lock]="Lock/Idle"
    [wallpaper]="Wallpaper"
    [clip]="Clip/Screen"
    [media]="Media/Bright"
    [audio]="Audio"
    [ime]="IME"
    [fonts]="Fonts"
    [keyring]="Keyring"
)

declare -A GROUP_PKGS=(
    # NOTE: zsh-autosuggestions / zsh-syntax-highlighting are NOT listed here —
    # distro packages install them in /usr/share or /etc/zsh/zshrc.d, which oh-my-zsh's
    # plugins=() cannot use. install_zsh_extras clones them into ~/.oh-my-zsh/custom/plugins/
    # (works identically on Arch / RHEL / Debian families).
    [core]="niri waybar mako fuzzel kitty polkit-gnome xwayland-satellite xdg-desktop-portal-gnome xdg-desktop-portal-gtk wl-clipboard libnotify zsh"
    [lock]="hyprlock hypridle"
    [wallpaper]="awww waypaper"
    [clip]="copyq satty grim slurp"
    [media]="playerctl brightnessctl btop"
    [audio]="pipewire-pulse wireplumber"
    [ime]="fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt fcitx5-rime rime-ice-pinyin-git"
    [fonts]="ttf-jetbrains-mono-nerd wqy-zenhei"
    [keyring]="gnome-keyring"
)

# pkg -> group reverse lookup table (built at runtime)
declare -A PKG_GROUP=()
for _g in "${GROUP_ORDER[@]}"; do
    for _p in ${GROUP_PKGS[$_g]:-}; do
        PKG_GROUP["$_p"]="$_g"
    done
done
unset _g _p

# service -> provider package mapping (filtered by is-enabled during export and written to services.txt)
SVC_ORDER=(bluetooth.service libvirtd.service power-profiles-daemon.service)
declare -A SVC_PROVIDER=(
    [bluetooth.service]=bluez
    [libvirtd.service]=libvirt
    [power-profiles-daemon.service]=power-profiles-daemon
)


# System components (from other desktop environments) to disable when restoring
# on a multi-DE target machine.  Only masked / hidden, NEVER uninstalled — the user
# can switch back to the other DE at any time.  Each item is existence-checked first
# so it is safe on Arch (most entries won't exist) and RHEL/Debian alike.
# type: autostart  — write ~/.config/autostart/<name> with Hidden=true as override + kill process
#       userunit   — systemctl --user mask <name> + systemctl --user stop <name>
#       systemunit — systemctl mask <name> + systemctl stop <name>
DISABLE_SYS=(
    # --- notification daemons (replaced by mako) ---
    "userunit|evolution-alarm-notify.service|GNOME notifications"
    "autostart|evolution-alarm-notify.desktop|GNOME notifications"
    "userunit|xfce4-notifyd.service|XFCE notifications"
    "autostart|xfce4-notifyd.desktop|XFCE notifications"
    
    # --- GNOME settings daemon (replaced by waybar + power-profiles-daemon) ---
    "autostart|org.gnome.SettingsDaemon.MediaKeys.desktop|GNOME media keys daemon"
    "autostart|org.gnome.SettingsDaemon.Power.desktop|GNOME power daemon (replaced by hypridle)"
    "autostart|org.gnome.SettingsDaemon.Sound.desktop|GNOME sound daemon"
    "autostart|org.gnome.SettingsDaemon.Clipboard.desktop|GNOME clipboard daemon"
    "userunit|org.gnome.SettingsDaemon.MediaKeys.service|GNOME media keys service"
    "userunit|org.gnome.SettingsDaemon.Power.service|GNOME power service (replaced by hypridle)"
    "userunit|org.gnome.SettingsDaemon.Sound.service|GNOME sound service"
    "userunit|org.gnome.SettingsDaemon.Clipboard.service|GNOME clipboard service"
    
    # --- GNOME screensaver / lock screen (replaced by hyprlock + hypridle) ---
    "userunit|org.gnome.ScreenSaver.service|GNOME screensaver (replaced by hyprlock)"
    "autostart|org.gnome.ScreenSaver.desktop|GNOME screensaver (replaced by hyprlock)"
    "systemunit|gnome-screensaver.service|GNOME screensaver system service (replaced by hyprlock)"
    
    # --- GDM / display manager session helpers (niri handles display) ---
    # Do NOT mask GDM Wayland session on RHEL系 — this causes black screen on login.
    # Only mask if the user explicitly wants to switch back to another DE.
    # "systemunit|gdm-launch-environment.service|GDM launch environment"
    # "systemunit|gdm-x11-session.service|GDM X11 session"
    # "systemunit|gdm-wayland-session.service|GDM Wayland session"
    
    # --- misc GNOME system services ---
    "systemunit|gnome-remote-desktop.service|GNOME remote desktop"
    
    # --- PulseAudio (Ubuntu 24.04+ uses PipeWire by default, but legacy units may exist) ---
    "userunit|pulseaudio.service|PulseAudio service (replaced by PipeWire)"
    "userunit|pulseaudio.socket|PulseAudio socket (replaced by PipeWire)"
    "systemunit|pulseaudio.service|PulseAudio system service (replaced by PipeWire)"
    
    # --- XFCE power management (replaced by power-profiles-daemon) ---
    "userunit|xfce4-power-manager.service|XFCE power manager"
    "autostart|xfce4-power-manager.desktop|XFCE power manager (replaced by power-profiles-daemon)"
    
    # --- KDE power management (replaced by power-profiles-daemon) ---
    "userunit|org.kde.powerdevil.service|KDE power manager"
    "autostart|org.kde.powerdevil.desktop|KDE power manager (replaced by power-profiles-daemon)"

    # --- tuned vs power-profiles-daemon (RHEL 8/9) ---
    # tuned is the RHEL default power-management service and conflicts with
    # power-profiles-daemon.service (both ride the same power framework), so with
    # tuned running power-profiles-daemon fails to start. Masked on RHEL (existence-
    # checked — absent on Arch/Debian, harmless there); user can enable tuned again.
    "systemunit|tuned.service|tuned (RHEL default power mgmt, conflicts with power-profiles-daemon)"
    
    # --- XFCE screen saver (replaced by hyprlock + hypridle) ---
    "userunit|xfce4-screensaver.service|XFCE screensaver (replaced by hyprlock)"
    "autostart|xfce4-screensaver.desktop|XFCE screensaver (replaced by hyprlock)"
    "systemunit|xfce4-screensaver.service|XFCE screensaver system (replaced by hyprlock)"
    
    # --- KDE screen locker (replaced by hyprlock + hypridle) ---
    "systemunit|kscreenlocker.service|KDE screen locker (replaced by hyprlock)"
    "autostart|kscreenlocker.desktop|KDE screen locker (replaced by hyprlock)"
)


# Summary report collectors
INSTALLED_PKGS=() SKIPPED_PKGS=() FAILED_PKGS=() MANUAL_ITEMS=() ENABLED_SVCS=()
DRY_PKGS=() DRY_SVCS=()  # items "that would be executed" in dry-run mode; kept separate to avoid inflated counts


# 4. restore mode — reproduce desktop on new system (run as root)
# ==============================================================================

DISTRO_FAMILY=""   # arch | rhel | debian
DISTRO_ID=""       # os-release ID (e.g. ubuntu, debian, arch)
DISTRO_ID_LIKE=""  # os-release ID_LIKE (detect Ubuntu-derived distros like openkylin/deepin)
UBUNTU_VER_NUM=0   # numeric Ubuntu version (e.g. 2404), 0 = not Ubuntu
TARGET_USER=""
HOME_DIR=""

# --- 4.0 basics ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "$(_t "restore requires root. Use: sudo ./arch-install.sh restore" "restore requires root. Use: sudo ./arch-install.sh restore")"
        exit 1
    fi
}

detect_distro() {
    local id_like="" id=""
    if [ -f /etc/os-release ]; then
        id=$(. /etc/os-release; echo "${ID:-}")
        id_like=$(. /etc/os-release; echo "${ID_LIKE:-}")
    fi
    DISTRO_ID="$id"
    DISTRO_ID_LIKE="$id_like"
    case " $id $id_like " in
        *arch*|*manjaro*|*endeavouros*) DISTRO_FAMILY=arch ;;
        *)
            error "This script is for Arch / Manjaro / EndeavourOS (ID=$id ID_LIKE=$id_like). Use ./RHEL-install.sh or ./deb-install.sh instead."
            exit 1
            ;;
    esac
    info_kv "$(_t "Distro" "Distro")" "$DISTRO_FAMILY" "(ID=$id)"
}

pkg_installed() { # $1 = package name
    pacman -Qi "$1" &>/dev/null
}


pm_install() { # $@ = package names
    exe pacman -S --noconfirm --needed "$@"
}

# Install as many packages of a batch as possible; return non-zero only when one or more
# names are genuinely unavailable. Used for build-deps batches that must be resilient to a
# few absent names (so a single renamed -dev package no longer aborts the whole build).
BDEPS_MISSING=()
as_user() {
    runuser -u "$TARGET_USER" -- "$@"
}

# Resume support (dry-run does not read/write the progress file).
# The progress file carries a script-version marker; progress files written by older
# script versions are ignored (stages are re-run instead of being silently skipped).
PROGRESS_VERSION="v40"
stage_done() {
    [ "$DRY_RUN" -eq 1 ] && return 1
    grep -q "^# eilniri-progress $PROGRESS_VERSION" "$STATE_FILE" 2>/dev/null || return 1
    grep -qx "$1" "$STATE_FILE" 2>/dev/null
}
stage_mark() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    # reset stale progress files (missing marker = written by an older script version)
    if ! grep -q "^# eilniri-progress $PROGRESS_VERSION" "$STATE_FILE" 2>/dev/null; then
        echo "# eilniri-progress $PROGRESS_VERSION" > "$STATE_FILE"
    fi
    grep -qx "$1" "$STATE_FILE" 2>/dev/null || echo "$1" >> "$STATE_FILE"
}

# Target user detection (simplified detect_target_user)
detect_target_user() {
    local uid1000
    uid1000=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd | head -n 1)
    mapfile -t HUMAN_USERS < <(awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd)

    # dry-run: skip interaction, auto-pick UID 1000 / first regular user
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ ${#HUMAN_USERS[@]} -gt 0 ]; then
            TARGET_USER="${uid1000:-${HUMAN_USERS[0]}}"
            log "$(_t "[DRY-RUN] auto-selecting target user: " "[DRY-RUN] auto-selecting target user: ") $TARGET_USER"
        else
            TARGET_USER="eilniri-dryrun"
            log "$(_t "[DRY-RUN] no regular users found, using placeholder: " "[DRY-RUN] no regular users found, using placeholder: ") $TARGET_USER"
        fi
        HOME_DIR=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)
        [ -z "$HOME_DIR" ] && HOME_DIR="/home/$TARGET_USER"
        export TARGET_USER HOME_DIR
        info_kv "$(_t "Target User" "Target User")" "$TARGET_USER" "($HOME_DIR)"
        return
    fi

    if [ ${#HUMAN_USERS[@]} -gt 0 ]; then
        local default_user="${uid1000:-${HUMAN_USERS[0]}}"
        echo -e "   ${H_YELLOW}$(_t ">>> Existing users found, select target:" ">>> Existing users found, select target:")${NC}"
        local i
        for i in "${!HUMAN_USERS[@]}"; do
            local mark=""
            [ "${HUMAN_USERS[$i]}" = "$default_user" ] && mark="${H_CYAN}*${NC}"
            echo -e "       [$((i+1))] ${mark}${HUMAN_USERS[$i]}"
        done
        echo -e "       [0] ${H_GREEN}$(_t "Create New User ++" "Create New User ++")${NC}"

        local idx
        while true; do
            echo -ne "   ${H_CYAN}$(_t "Enter number [0-${#HUMAN_USERS[@]}] (default ${default_user}, 30s timeout): " "Enter number [0-${#HUMAN_USERS[@]}] (default ${default_user}, 30s timeout): ")${NC}"
            if ! read -t 30 -r idx; then
                echo ""
                TARGET_USER="$default_user"
                log "$(_t "Timeout, auto-selecting: " "Timeout, auto-selecting: ")$TARGET_USER"
                break
            fi
            if [ -z "$idx" ]; then TARGET_USER="$default_user"; break; fi
            if [ "$idx" = "0" ]; then TARGET_USER=""; break; fi
            if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#HUMAN_USERS[@]}" ]; then
                TARGET_USER="${HUMAN_USERS[$((idx-1))]}"
                break
            fi
            warn "$(_t "Invalid input." "Invalid input.")"
        done
    fi

    if [ -z "$TARGET_USER" ]; then
        local new_user
        while true; do
            echo -ne "   ${H_GREEN}$(_t "Enter new username: " "Enter new username: ")${NC} "
            read -r new_user
            if [[ "$new_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                if exe useradd -m -s /bin/bash "$new_user"; then
                    TARGET_USER="$new_user"
                    warn "Set a password later with: passwd $new_user"
                    break
                fi
                warn "$(_t "User creation failed (may already exist), retry." "User creation failed (may already exist), retry.")"
                continue
            fi
            warn "$(_t "Invalid username format." "Invalid username format.")"
        done
    fi

    HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    # in dry-run the new user is not created yet; fall back to the default home path when getent is empty
    [ -z "$HOME_DIR" ] && HOME_DIR="/home/$TARGET_USER"
    export TARGET_USER HOME_DIR
    info_kv "$(_t "Target User" "Target User")" "$TARGET_USER" "($HOME_DIR)"
}

ensure_fzf() {
    if command -v fzf &>/dev/null; then return 0; fi
    log "$(_t "Installing interactive menu dependency: fzf ..." "Installing interactive menu dependency: fzf ...")"
    local _saved_dry="$DRY_RUN"
    DRY_RUN=0  # fzf is required for interaction, so install it even in --dry-run
    if pm_install fzf; then
        DRY_RUN="$_saved_dry"
        return 0
    fi
    DRY_RUN="$_saved_dry"
    error "$(_t "fzf install failed, cannot continue." "fzf install failed, cannot continue.")"
    exit 1
}

# fzf multi-select (see 99-apps.sh: select all by default / TAB toggle / Ctrl-A select all / Ctrl-D deselect all)
#  stdin: lines of "field1\tfield2"; stdout: lines selected by the user
fzf_multi() {
    fzf --multi --layout=reverse --border=rounded --margin=1,2 \
        --delimiter=$'\t' --with-nth=1,2 \
        --bind 'load:select-all' \
        --bind 'ctrl-a:select-all,ctrl-d:deselect-all,j:down,k:up' \
        --pointer=">" --marker="* " --ansi \
        --header="$1"
}

# fzf single-select (rollback etc.: nothing preselected, TAB/Ctrl-D meaningless)
fzf_single() {
    fzf --layout=reverse --border=rounded --margin=1,2 \
        --delimiter=$'\t' --with-nth=1,2 \
        --pointer=">" --marker="" --ansi \
        --header="$1"
}

# Resolve the DRM connector at session startup, after GDM has handed the device
# to the user session. Installation-time detection can see a different connector
# (or no connector at all) on virtual machines.
install_niri_output_wrapper() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    local _wrapper=/usr/local/bin/eilniri-niri-session
    cat > "$_wrapper" <<'WRAPEOF'
#!/usr/bin/env bash
set -u

cfg="${XDG_CONFIG_HOME:-$HOME/.config}/niri/config.kdl"
tmp="${cfg}.eilniri-output.$$"
export WLR_NO_HARDWARE_CURSORS=1
export WLR_RENDERER_ALLOW_SOFTWARE=1
out=""; mode=""
for status in /sys/class/drm/card*-*/status; do
    [ -f "$status" ] || continue
    [ "$(<"$status")" = connected ] || continue
    dir=${status%/status}
    candidate=${dir##*/}
    candidate=${candidate#card[0-9]-}
    candidate_mode=$(sed -n '1p' "$dir/modes" 2>/dev/null || true)
    [ -n "$candidate" ] && [ -n "$candidate_mode" ] || continue
    out="$candidate"; mode="$candidate_mode"; break
done

if [ -n "$out" ] && [ -n "$mode" ] && [ -f "$cfg" ]; then
    w=${mode%x*}; h=${mode#*x}; mode_line="mode \"${w}x${h}@60\""
    awk -v output="$out" -v mode_line="$mode_line" '
        BEGIN { replaced=0; inside=0 }
        !replaced && $0 ~ /^[[:space:]]*output[[:space:]]+"/ {
            print "output \"" output "\" {"; print "    " mode_line
            replaced=1; inside=1; next
        }
        inside && $0 ~ /^[[:space:]]*}/ { print "}"; inside=0; next }
        inside { next }
        { print }
    ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
fi

exec /usr/local/bin/niri-session.real "$@"
WRAPEOF
    chmod 755 "$_wrapper"
}

# --- Debian/Ubuntu apt mirror switch (offered when apt-get update or install fails ---
# with 404 / 无法下载 / connection errors).  Rewrites the apt host in the source
# files (both deb-format .list and deb822 .sources) to a selected mirror, backs up
# the originals, then reruns apt-get update and VERIFIES the previously-missing
# .deb is actually served by the new mirror (curl probe).
# NOTE: fzf may not be installed yet at this point (ensure_fzf runs after
# preflight, and apt being broken can block its install), so this falls back to a
# plain numbered prompt when fzf is absent.
stage_preflight() {
    section "$(_t "Pre-Flight" "Pre-Flight")" "$(_t "System Update" "System Update")"
    if stage_done preflight; then
        log "$(_t "Pre-flight done, skipping (delete .replicate_progress to force rerun)." "Pre-flight done, skipping (delete .replicate_progress to force rerun).")"
        return
    fi
            # Parallel download speedup
            sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf 2>/dev/null || true
            # Reflector mirror optimization (CN timezone -> China mirrors, otherwise skip)
            local tz
            tz=$(readlink -f /etc/localtime 2>/dev/null || echo "")
            if [[ "$tz" =~ Shanghai|Beijing|Asia/Chongqing|Asia/Urumqi|Asia/Hong_Kong ]]; then
                if command -v reflector &>/dev/null; then
                    log "$(_t "Detected CN timezone, refreshing CN mirrors..." "Detected CN timezone, refreshing CN mirrors...")"
                    exe reflector --country China --protocol https --sort rate --save /etc/pacman.d/mirrorlist --latest 10 2>/dev/null || \
                        warn "$(_t "Reflector failed, using existing mirrors." "Reflector failed, using existing mirrors.")"
                fi
            fi
            exe pacman -Sy --noconfirm archlinux-keyring || warn "$(_t "keyring refresh failed, continuing." "keyring refresh failed, continuing.")"
            if [ "$DRY_RUN" -eq 1 ]; then
                log "$(_t "[DRY-RUN] Skipping system upgrade." "[DRY-RUN] Skipping system upgrade.")"
            elif ! exe pacman -Su --noconfirm; then
                error "$(_t "System update failed. Check network." "System update failed. Check network.")"
                exit 1
            fi
        success "$(_t "System ready." "System ready.")"
    stage_mark preflight
}

# --- 4.2 app selection ---

REPO_UNIVERSE=()

load_app_universe() {
    # Built-in authoritative package list (no snapshot/pkglist in the snapshot-free mode)
    local g raw
    for g in "${GROUP_ORDER[@]}"; do
        for raw in ${GROUP_PKGS[$g]:-}; do
            REPO_UNIVERSE+=("$raw")
        done
    done
}

group_tag() { # $1 = pkg
    local g="${PKG_GROUP[$1]:-}"
    if [ -n "$g" ]; then
        echo "[${GROUP_EN[$g]}]"
    else
        echo "[Snapshot]"
    fi
}

stage_apps_select() {
    section "$(_t "App Selection" "App Selection")" "$(_t "TAB toggle | Select All | Ctrl-D deselect | Enter" "TAB toggle | Select All | Ctrl-D deselect | Enter")"
    load_app_universe

    # Chinese component selection
    if ! confirm "$(_t "Install Chinese IME (fcitx5+rime) and font (wqy-zenhei)? [Y/n] (default Y, 15s):" "Install Chinese IME (fcitx5+rime) and font (wqy-zenhei)? [Y/n] (default Y, 15s):")" "Y" 15; then
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
    fi

    local lines=() p
    for p in ${REPO_UNIVERSE[@]+"${REPO_UNIVERSE[@]}"}; do
        lines+=("$p"$'\t'"$(group_tag "$p")")
    done

    # dry-run: skip fzf interaction, select everything (same as the fzf load:select-all default)
    if [ "$DRY_RUN" -eq 1 ]; then
        REPO_SEL=("${REPO_UNIVERSE[@]}")
        log "$(_t "[DRY-RUN] auto-selected all: ${#REPO_SEL[@]} packages" "[DRY-RUN] auto-selected all: ${#REPO_SEL[@]} packages")"
        info_kv "$(_t "Selected" "Selected")" "${#REPO_SEL[@]} packages" ""
        return 0
    fi

    # Empty list guard: fzf with empty input returns non-zero silently, so skip to avoid a false "user aborted"
    if [ ${#lines[@]} -eq 0 ]; then
        warn "$(_t "Package list is empty, skipping app install." "Package list is empty, skipping app install.")"
        return 1
    fi

    local selected
    selected=$(printf "%s\n" "${lines[@]}" | fzf_multi " Select niri suite apps to install ") || {
        error "$(_t "User aborted selection." "User aborted selection.")"
        exit 130
    }
    if [ -z "$selected" ]; then
        warn "$(_t "No apps selected, skipping install." "No apps selected, skipping install.")"
        return 1
    fi

    REPO_SEL=()
    local raw
    while IFS= read -r raw; do
        local name
        name=$(echo "$raw" | cut -f1 -d"$(printf '\t')" | xargs)
        [ -z "$name" ] && continue
        REPO_SEL+=("$name")
    done <<< "$selected"
    info_kv "$(_t "Selected" "Selected")" "${#REPO_SEL[@]} packages" ""
    return 0
}

# --- 4.3 app install ---

install_arch() {
    local p
    # --- repo packages: batch install, fall back to per-package isolation on failure ---
    local queue=()
    for p in ${REPO_SEL[@]+"${REPO_SEL[@]}"}; do
        if [ -n "${PIP_PKGS[$p]:-}" ]; then
            # pip fallback install
            if [ "$DRY_RUN" -eq 1 ]; then
                DRY_PKGS+=("$p (pip)")
                continue
            fi
            pm_install python-pip
            local per=0
            exe as_user pip install --user "${PIP_PKGS[$p]}" || per=$?
            if [ "$per" -eq 0 ]; then
                INSTALLED_PKGS+=("$p (pip)")
            else
                MANUAL_ITEMS+=("$p — pip install failed, do it manually: pip install --user ${PIP_PKGS[$p]}")
            fi
            continue
        fi
        if pkg_installed "$p"; then
            SKIPPED_PKGS+=("$p (already installed)")
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
            warn "$(_t "Batch install failed, switching to individual installs..." "Batch install failed, switching to individual installs...")"
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
}

_dl_gh_bounded() { # $1=github asset url, $2=outfile, $3=seconds cap (default 90)
    local url="$1" out="$2" cap="${3:-90}" prox full
    [ -n "$url" ] && [ -n "$out" ] || return 1
    rm -f "$out"
    if curl -fsSL --retry 1 --connect-timeout 8 --max-time "$cap" -o "$out" "$url" 2>/dev/null && [ -s "$out" ]; then
        return 0
    fi
    for prox in ${EILNIRI_GH_PROXY:-$GH_MIRRORS}; do
        full="${prox%/}/$url"
        rm -f "$out"
        if curl -fsSL --retry 1 --connect-timeout 8 --max-time "$cap" -o "$out" "$full" 2>/dev/null && [ -s "$out" ]; then
            return 0
        fi
    done
    return 1
}

# Clone a GitHub repo, falling back to the CN mirror proxies when direct git fails
# (git smart-HTTP works through ghfast.top and friends; verified with git ls-remote).
# Bounded so a blocked GitHub never hangs the install (git has no default timeout).
git_clone_gh() { # $1 = github repo URL, $2 = dest dir; returns 0 on success
    local repo="$1" dest="$2" prox full
    [ -n "$repo" ] && [ -n "$dest" ] || return 1
    if git -c http.connectTimeout=15 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
        clone --depth 1 "$repo" "$dest" >/dev/null 2>&1; then
        return 0
    fi
    for prox in ${EILNIRI_GH_PROXY:-$GH_MIRRORS}; do
        full="${prox%/}/$repo"
        rm -rf "$dest"
        if git -c http.connectTimeout=15 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
            clone --depth 1 "$full" "$dest" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# one download attempt with resume support; rc 33 = server rejects range requests -> restart
try_dl() { # $1 = URL, $2 = output file; returns 0 on success
    local url="$1" out="$2" rc
    curl "${CURL_DL_FLAGS[@]}" -C - -o "$out" "$url" 2>/dev/null
    rc=$?
    if [ "$rc" -eq 33 ]; then
        rm -f "$out"
        curl "${CURL_DL_FLAGS[@]}" -o "$out" "$url" 2>/dev/null
        rc=$?
    fi
    return "$rc"
}

download_gh() { # $1 = URL, $2 = output file; returns 0 on success, else the curl exit code
    local url="$1" out="$2"
    if try_dl "$url" "$out"; then
        return 0
    fi
    local rc=$?
    # direct download failed — try mirror proxies (CN-friendly; configurable via EILNIRI_GH_PROXY)
    log "$(_t "Direct download failed (curl " "Direct download failed (curl ") $rc), trying mirror proxies..."
    local proxy prefix
    for proxy in ${EILNIRI_GH_PROXY:-$GH_MIRRORS}; do
        prefix="${proxy%/}"
        if try_dl "${prefix}/${url}" "$out"; then
            return 0
        fi
    done
    log "$(_t "Download failed after all proxies (last curl exit code: " "Download failed after all proxies (last curl exit code: ") $rc)"
    return "$rc"
}

# Cargo/rustup mirror for CN timezones (builds fetch from crates.io / static.rust-lang.org).
# Sets CRATES_IO_OK=1 when at least one registry (crates.io or rsproxy) is reachable —
# install_niri_binary uses it to pick the network build vs the vendored-dependencies offline build.
CRATES_IO_OK=0
_ensure_wallpaper() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    command -v awww >/dev/null 2>&1 || return 0   # awww 缺失由 install_awww 处理

    local _img="" _cand _ext=""
    # 1) 固定使用仓库根目录的壁纸图（用户放在 script 旁的那张 QQ图片.../wallpaper 图）。
    #    每次部署都会把它复制到 ~/.local/share/backgrounds/wallpaper.<ext>（若文件已存在且
    #    相同则跳过；之前不显示是因为早退逻辑/未主动 set——这里不早退，并最终主动 set）。
    for _cand in "$BASE_DIR"/*.jpg "$BASE_DIR"/*.jpeg "$BASE_DIR"/*.png "$BASE_DIR"/*.webp; do
        [ -f "$_cand" ] || continue
        case "$_cand" in *.jpg|*.jpeg) _ext=jpg;; *.png) _ext=png;; *.webp) _ext=webp;; *) continue;; esac
        mkdir -p "$HOME_DIR/.local/share/backgrounds"
        _img="$HOME_DIR/.local/share/backgrounds/wallpaper.$_ext"
        if [ ! -f "$_img" ] || ! cmp -s "$_cand" "$_img" 2>/dev/null; then
            cp -f "$_cand" "$_img" 2>/dev/null || true
        fi
        chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$_img" 2>/dev/null || true
        log "$(_t "Wallpaper deployed from repo: " "Wallpaper deployed from repo: ") $(basename "$_cand") -> $_img"
        break
    done
    # 2) 仓库没有图 → 用现有图片
    if [ -z "$_img" ]; then
        for _cand in "$HOME_DIR"/Pictures/*.png "$HOME_DIR"/Pictures/*.jpg "$HOME_DIR"/Pictures/*.jpeg \
                     "$HOME_DIR"/.local/share/backgrounds/*.png "$HOME_DIR"/.local/share/backgrounds/*.jpg; do
            [ -f "$_cand" ] && { _img="$_cand"; break; }
        done
    fi
    # 3) 都没有 → 生成默认渐变壁纸
    if [ -z "$_img" ]; then
        _img="$HOME_DIR/.local/share/backgrounds/eilniri-default.png"
        mkdir -p "$(dirname "$_img")"
        log "$(_t "No wallpaper found — generating a default gradient wallpaper..." "No wallpaper found — generating a default gradient wallpaper...")"
        exe python3 - "$_img" <<'PYEOF' 2>/dev/null || true
import struct, zlib, sys
w, h = 1920, 1080
out = sys.argv[1]
def chunk(t, data):
    c = t + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
raw = bytearray()
for y in range(h):
    raw.append(0)
    for x in range(w):
        t = y / h
        raw.extend((int(18 + 30*t), int(28 + 55*t), int(58 + 130*t)))
png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(bytes(raw), 6))
png += chunk(b'IEND', b'')
open(out, 'wb').write(png)
PYEOF
        chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$_img" 2>/dev/null || true
    fi

    if [ -f "$_img" ]; then
        mkdir -p "$HOME_DIR/.config/awww"
        printf '%s\n' "$_img" > "$HOME_DIR/.config/awww/wallpaper"
        chown -R "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$HOME_DIR/.config/awww" 2>/dev/null || true
        log "$(_t "Wallpaper state written: " "Wallpaper state written: ") $_img"
        # 修正 waypaper config.ini 里指向参考机的绝对路径（新机器上不存在则换成壁纸图）
        local _wpconf="$HOME_DIR/.config/waypaper/config.ini"
        if [ -f "$_wpconf" ]; then
            local _oldwp
            _oldwp=$(grep -E '^wallpaper\s*=' "$_wpconf" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d ' \r')
            if [ -n "$_oldwp" ] && [ ! -f "$_oldwp" ]; then
                log "$(_t "waypaper config.ini points to missing path " "waypaper config.ini points to missing path ") $_oldwp$(_t " -> " " -> ") $_img"
                sed -i "s#^wallpaper\s*=.*#wallpaper = $_img#" "$_wpconf" 2>/dev/null || true
            fi
            # stylesheet 键：配置里的参考机绝对路径通常是 $HOME 字面量，这里展开成绝对路径
            local _oldss
            _oldss=$(grep -E '^stylesheet\s*=' "$_wpconf" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d ' \r')
            if [ -n "$_oldss" ] && [ ! -f "$_oldss" ]; then
                local _newss="${_oldss/#\~/$HOME_DIR}"
                if [ -f "$_newss" ]; then
                    sed -i "s#^stylesheet\s*=.*#stylesheet = $_newss#" "$_wpconf" 2>/dev/null || true
                fi
            fi
            chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$_wpconf" 2>/dev/null || true
        fi
        # 修正 hyprlock 锁屏壁纸路径（参考机绝对路径在新机器上无效 → 锁屏背景空白）
        local _hlconf="$HOME_DIR/.config/hypr/hyprlock.conf"
        if [ -f "$_hlconf" ] && grep -qE '^\s*path\s*=' "$_hlconf" 2>/dev/null; then
            log "$(_t "hyprlock wallpaper path -> " "hyprlock wallpaper path -> ") $_img"
            sed -i -E "s#^(\s*path\s*=).*#\1 $_img#" "$_hlconf" 2>/dev/null || true
            chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$_hlconf" 2>/dev/null || true
        fi
        # 主动 set：只写状态文件不够——显式让 awww-daemon 应用这张壁纸（daemon 若已响应
        # 自己读状态文件并应用；此处再主动调用一次确保生效，失败不影响已写状态）。
        if [ -x /usr/local/bin/awww-daemon ] && command -v as_user >/dev/null 2>&1; then
            exe as_user awww-daemon set-wallpaper "$_img" 2>>"$LOG_DIR/awww-set.log" || \
                exe as_user awww set-wallpaper "$_img" 2>>"$LOG_DIR/awww-set.log" || true
            log "$(_t "awww set-wallpaper invoked: " "awww set-wallpaper invoked: ") $_img"
        fi
    fi
}

# pip --user 装的 waypaper 没有 .desktop 入口 → fuzzel 启动器里不显示/无图标。
# 生成一个标准桌面入口（图标用 Adwaita 的 preferences-desktop-wallpaper）。
_ensure_waypaper_desktop() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    command -v waypaper >/dev/null 2>&1 || [ -x "$HOME_DIR/.local/bin/waypaper" ] || return 0
    local _wp
    _wp=$(command -v waypaper 2>/dev/null || echo "$HOME_DIR/.local/bin/waypaper")
    mkdir -p "$HOME_DIR/.local/share/applications"
    local _wpd="$HOME_DIR/.local/share/applications/waypaper.desktop"
    if [ ! -f "$_wpd" ] || ! grep -q "^Exec=" "$_wpd" 2>/dev/null; then
        cat > "$_wpd" <<EOF
[Desktop Entry]
Name=Waypaper
Comment=Wallpaper manager (awww/swww)
Exec=$_wp
Icon=preferences-desktop-wallpaper
Terminal=false
Type=Application
Categories=Utility;Graphics;
EOF
        chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$_wpd" 2>/dev/null || true
        log "$(_t "waypaper.desktop created (fuzzel icon)" "waypaper.desktop created (fuzzel icon)")"
    fi
}

# --- satty install (Debian/RHEL families; no package) ---
# Strategy: 1) official prebuilt binary from GitHub releases (satty-<arch>-unknown-linux-gnu.tar.gz)
#           2) cargo install fallback (needs GTK4/libadwaita/librsvg dev packages) 3) manual report
SATTY_GH="https://github.com/Satty-org/Satty/releases"

install_nerd_font() {
    local _has_nf=0 _p
    for _p in ${REPO_SEL[@]+"${REPO_SEL[@]}"}; do
        [ "$_p" = "ttf-jetbrains-mono-nerd" ] && _has_nf=1
    done
    [ "$_has_nf" -eq 1 ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        DRY_PKGS+=("JetBrainsMono Nerd Font (download)")
        return "$DRY_RUN_RC"
    fi
    local _font_dir="$HOME_DIR/.local/share/fonts"
    # 幂等：已在系统里装过带有 JetBrainsMono Nerd 字形的字体，或目标目录已有 Nerd Font
    # 的 .ttf，则直接跳过（绝不在每次 restore 都重新下载几十~上百 MB）。
    # 正则兼容两种 family 命名：包管理器装的 "JetBrains Mono Nerd" 与 release 下载的
    # "JetBrainsMono Nerd"（Fedora 的 jetbrains-mono-nerd-fonts 包即据此被识别而跳过下载）。
    if fc-list 2>/dev/null | grep -qiE 'jetbrains[[:space:]-]?mono.*nerd|nerd.*jetbrains[[:space:]-]?mono'; then
        log "$(_t "Nerd Font already installed, skipping." "Nerd Font already installed, skipping.")"
        return 0
    fi
    if [ -d "$_font_dir" ] && find "$_font_dir" \( -iname '*.ttf' -o -iname '*.otf' \) 2>/dev/null | head -100 | grep -qiE 'jetbrains[[:space:]-]?mono.*nerd|nerd.*jetbrains[[:space:]-]?mono'; then
        log "$(_t "Nerd Font present in ~/.local/share/fonts, skipping." "Nerd Font present in ~/.local/share/fonts, skipping.")"
        return 0
    fi
    mkdir -p "$_font_dir"
    # 可选依赖：这是个 ~50MB 的大文件，且部分地区直连 GitHub 很慢/被墙。
    # 不能走 download_gh —— 它全局用 --max-time 1800（30 分钟/次）+ 多代理轮询，
    # 一旦源站慢或不通，整次 install 会被这个可选项拖死（表现为"一直卡住"）。
    # 这里走统一的 _dl_gh_bounded：直连 + 实测可用的 CN 镜像各试一轮，每次硬性
    # 90 秒封顶、连接超时 8s、最多 1 次重试；失败立刻降级为"未装上"提示。
    log "$(_t "Downloading JetBrainsMono Nerd Font (icons, optional)..." "Downloading JetBrainsMono Nerd Font (icons, optional)...")"
    local _zip _url _ok=0
    _zip=$(mktemp); register_temp_path "$_zip"
    _url="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"
    if _dl_gh_bounded "$_url" "$_zip" 90; then
        _ok=1
    fi
    if [ "$_ok" -eq 1 ]; then
        if command -v unzip >/dev/null 2>&1; then
            exe unzip -o "$_zip" -d "$_font_dir" >/dev/null 2>&1 || true
        else
            exe python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$_zip" "$_font_dir" 2>/dev/null || true
        fi
        exe fc-cache -f "$_font_dir" >/dev/null 2>&1 || true
        INSTALLED_PKGS+=("JetBrainsMono Nerd Font")
        success "$(_t "Nerd Font installed (waybar icons)" "Nerd Font installed (waybar icons)")"
    fi
    # 下载失败或解压后仍无 nerd 字体 → 记录一条提示但不中止后续安装
    if [ "$_ok" -eq 0 ] || ! fc-list 2>/dev/null | grep -qi 'jetbrainsmono.*nerd'; then
        warn "$(_t "Nerd Font 未装上（可选）— waybar 部分图标可能显示为方框; 可稍后手动安装" "Nerd Font not installed (optional) — some waybar icons may render as boxes; install manually later")"
    fi
}

# QEMU/KVM 虚拟机：安装并启用 spice-vdagent。
# 解决两个常见问题：① 宿主机↔虚拟机 剪贴板/复制粘贴不通；② 光标在合成器下无硬件
# cursor plane 时的拖影/残影（spice 提供客户端光标同步）。
install_vm_agent() {
    [ "$DRY_RUN" -eq 1 ] && { DRY_PKGS+=("spice-vdagent"); return "$DRY_RUN_RC"; }
    command -v spice-vdagent >/dev/null 2>&1 && return 0
    log "$(_t "Installing spice-vdagent (VM clipboard + cursor sync)..." "Installing spice-vdagent (VM clipboard + cursor sync)...")"
    pm_install spice-vdagent 2>/dev/null || { warn "$(_t "spice-vdagent install failed (non-VM?)" "spice-vdagent install failed (non-VM?)")"; return 0; }
    # 系统 daemon（spice-vdagentd）与用户会话 agent（spice-vdagent）
    systemctl enable --now spice-vdagentd 2>/dev/null || true
    as_user systemctl --user enable --now spice-vdagent 2>/dev/null || true
    INSTALLED_PKGS+=("spice-vdagent")
    success "$(_t "spice-vdagent installed" "spice-vdagent installed")"
}

stage_apps_install() {
    if stage_done apps; then
        log "$(_t "App install stage done, skipping." "App install stage done, skipping.")"
        return
    fi
    section "$(_t "App Install" "App Install")" "$DISTRO_FAMILY family"
    # warn early about low disk: cargo builds (niri vendored source + target) need several GB
    local _disk_mb
    _disk_mb=$(df -m "$BASE_DIR" 2>/dev/null | awk 'NR==2{print $4}')
    if [ "${_disk_mb:-0}" -gt 0 ] && [ "$_disk_mb" -lt 6144 ]; then
        warn "$(_t "Low disk space: " "Low disk space: ") $((_disk_mb/1024))GB $(_t "free — cargo builds need ~6GB, the build may fail." "free — cargo builds need ~6GB, the build may fail.")"
    fi
    # baseline failure counts: the stage is only marked complete when nothing new failed
    local _bf=${#FAILED_PKGS[@]} _bm=${#MANUAL_ITEMS[@]}
    install_arch
    install_nerd_font   # waybar 图标字体（Debian/RHEL 的 apt 包不带 Nerd Font 图标）
    install_vm_agent    # QEMU/虚拟机：spice-vdagent（剪贴板桥 + 光标同步）
    # Defer the progress mark while background builds (niri/awww) are still running
    # (stage_wait_builds marks the stage complete once they finish), and when anything
    # failed in this run — otherwise a rerun would skip retrying the failed installs.
    if [ ${#BG_JOBS[@]} -gt 0 ]; then
        log "$(_t "Background builds pending (niri/awww); stage marked complete after they finish." "Background builds pending (niri/awww); stage marked complete after they finish.")"
    elif [ ${#FAILED_PKGS[@]} -gt "$_bf" ] || [ ${#MANUAL_ITEMS[@]} -gt "$_bm" ]; then
        warn "$(_t "Some packages failed or need manual install; apps stage not marked complete — rerun (without deleting progress) retries them." "Some packages failed or need manual install; apps stage not marked complete — rerun (without deleting progress) retries them.")"
    else
        stage_mark apps
    fi
}

# --- 4.3b wait for background cargo builds and install their outputs ---

# Latest meaningful line from a build log (the crate cargo is currently compiling)
build_progress_line() { # $1 = logfile
    tail -n 300 "$1" 2>/dev/null \
        | grep -E 'Compiling|Finished|error\[|error:|warning: unused|^error|Building|Downloading' \
        | tail -n 1
}

stage_wait_builds() {
    [ ${#BG_JOBS[@]} -eq 0 ] && { stage_mark apps; return; }
    section "$(_t "Background Builds" "Background Builds")" "$(_t "waiting for cargo builds (niri/awww)" "waiting for cargo builds (niri/awww)")"
    log "$(_t "Run './arch-install.sh status' in another terminal to watch progress live." "Run './arch-install.sh status' in another terminal to watch progress live.")"
    local entry name pid logfile srcdir rc tailmsg start now prog any_failed=0
    for entry in "${BG_JOBS[@]}"; do
        IFS='|' read -r name pid logfile srcdir <<< "$entry"
        log "$(_t "Waiting for " "Waiting for ") $name $(_t " build..." " build...")"
        start=$(date +%s)
        while kill -0 "$pid" 2>/dev/null; do
            sleep 15
            now=$(( $(date +%s) - start ))
            prog=$(build_progress_line "$logfile")
            if [ -n "$prog" ]; then
                log "$(_t "[bg] " "[bg] ") $name ${H_CYAN}$((now/60))m $((now%60))s${NC} $(_t "elapsed — " "elapsed — ") ${DIM}$prog${NC}"
            else
                log "$(_t "[bg] " "[bg] ") $name $((now/60))m $((now%60))s $(_t "elapsed" "elapsed")"
            fi
        done
        rc=0
        wait "$pid" 2>/dev/null || rc=$?
        if [ "$rc" -eq 0 ]; then
            case "$name" in
                niri) install_niri_from_build "$srcdir" "$logfile" ;;
                awww) install_awww_from_build "$srcdir" "$logfile" ;;
            esac
        else
            any_failed=1
            tailmsg=$(tail -n 8 "$logfile" 2>/dev/null | tr '\n' ' ')
            MANUAL_ITEMS+=("$name — build failed ($tailmsg)")
            warn "$(_t "Background build failed: " "Background build failed: ") $name ($(_t "see log " "see log ") $logfile)"
        fi
        # drop this job from the state file so `status` reflects it accurately
        sed -i "\|^$name|d" "$BUILD_STATE_FILE" 2>/dev/null
    done
    rm -f "$BUILD_STATE_FILE"
    BG_JOBS=()
    if [ "$any_failed" -eq 0 ]; then
        stage_mark apps
    else
        warn "$(_t "Some background builds failed; apps stage not marked complete — rerun (without deleting progress) retries them." "Some background builds failed; apps stage not marked complete — rerun (without deleting progress) retries them.")"
    fi
}

# --- 4.3c build status (./arch-install.sh status, run from another terminal while restore is building) ---

do_status() {
    if [ ! -f "$BUILD_STATE_FILE" ]; then
        echo ""
        info_kv "$(_t "Build Status" "Build Status")" "$(_t "no background builds running" "no background builds running")"
        echo "   $(_t "(restore spawns niri/awww builds in background; the state file is removed when they finish)" "(restore spawns niri/awww builds in background; the state file is removed when they finish)")"
        return 0
    fi
    section "$(_t "Build Status" "Build Status")" "$(_t "live progress (refresh manually or use watch)" "live progress (refresh manually or use watch)")"
    local line name pid logfile srcdir alive elapsed prog
    while IFS='|' read -r name pid logfile srcdir; do
        [ -z "$name" ] && continue
        if kill -0 "$pid" 2>/dev/null; then
            elapsed=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
            [ -z "$elapsed" ] && elapsed="?"
            prog=$(build_progress_line "$logfile")
            echo -e "   ${H_CYAN}●${NC} ${H_GREEN}${name}${NC} ${H_YELLOW}RUNNING${NC} (${elapsed}s)"
            [ -n "$prog" ] && echo -e "       ${DIM}→ $prog${NC}"
        else
            if grep -qE '^error(\[|:)|error: could not' "$logfile" 2>/dev/null; then
                echo -e "   ${H_RED}✘${NC} ${H_GREEN}${name}${NC} ${H_RED}FAILED${NC} — see $logfile"
            else
                echo -e "   ${TICK} ${H_GREEN}${name}${NC} ${H_GREEN}finished${NC} — see $logfile"
            fi
        fi
    done < "$BUILD_STATE_FILE"
    echo ""
    echo -e "   ${DIM}$(_t "Live tail (log streams to):" "Live tail (log streams to):")${NC}"
    if [ -s "$BUILD_STATE_FILE" ]; then
        while IFS='|' read -r name pid logfile srcdir; do
            [ -n "$logfile" ] && [ -f "$logfile" ] && echo -e "       ${H_CYAN}tail -f $logfile${NC}"
        done < "$BUILD_STATE_FILE"
    fi
    echo -e "   ${DIM}$(_t "or: watch -n 5 ./arch-install.sh status" "or: watch -n 5 ./arch-install.sh status")${NC}"
}

# --- 4.4 system services (built-in list, fzf selection; snapshot-free mode) ---

stage_services() {
    if stage_done services; then
        log "$(_t "Service stage done, skipping." "Service stage done, skipping.")"
        return
    fi

    section "$(_t "Services" "Services")" "$(_t "Select services to enable (built-in list)" "Select services to enable (built-in list)")"
    local selected
    selected=$(for unit in "${SVC_ORDER[@]}"; do
        printf '%s\tprovider: %s\n' "$unit" "${SVC_PROVIDER[$unit]}"
    done | fzf_multi " Select services to enable ") || {
        warn "$(_t "User cancelled service selection, skipping." "User cancelled service selection, skipping.")"
        return
    }
    if [ -z "$selected" ]; then
        warn "$(_t "No services selected." "No services selected.")"
        return
    fi

    local line unit provider erc
    local any_failed=0
    while IFS= read -r line; do
        unit=$(echo "$line" | cut -f1 -d"$(printf '\t')" | xargs)
        [ -z "$unit" ] && continue
        provider="${SVC_PROVIDER[$unit]:-}"
        # install the provider package if it is missing
        if [ -n "$provider" ] && ! pkg_installed "$provider"; then
            log "$(_t "Installing service provider: " "Installing service provider: ")$provider"
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
            # diagnostics: distinguish a *missing/masked unit* from a *start failure*
            # so the failure is actionable on the rerun instead of repeating silently.
            local _desc
            _desc=$(systemctl show "$unit" --property=Description 2>/dev/null | sed 's/^Description=//')
            if [ -z "$_desc" ]; then
                warn "$(_t "Service unit not found: " "Service unit not found: ")$unit (package may not ship this unit on this distro)"
            fi
            systemctl --no-pager --lines=5 status "$unit" >"$LOG_DIR/service-$unit.log" 2>&1 || true
            log "$(_t "Enable failed for " "Enable failed for ")$unit — details: $LOG_DIR/service-$unit.log"
            FAILED_PKGS+=("service:$unit")
            any_failed=1
        fi
        # also enable the sockets that ship with libvirtd (if present)
        if [ "$unit" = libvirtd.service ]; then
            for sock in libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket virtlogd.socket virtlockd.socket; do
                exe systemctl enable "$sock" 2>/dev/null || true
            done
        fi
    done <<< "$selected"

    # mark complete only when this stage had no failures; otherwise leave it for the next run to retry
    if [ "$any_failed" -eq 0 ]; then
        stage_mark services
    else
        warn "$(_t "Service stage has failures, not marked complete. Will retry." "Service stage has failures, not marked complete. Will retry.")"
    fi
}

# --- 4.5 display manager (automatic, all families) ---
# One-script goal: after reboot the machine boots straight into the niri desktop.
#   Arch  : ly (lightweight, fits niri)
#   Debian/RHEL: gdm (fallback: gdm3 -> sddm)
# An existing display manager (e.g. gdm3 preinstalled on Ubuntu Desktop) is DISABLED and
# replaced by the chosen one. Safety: the replacement is installed FIRST and only then is
# the old DM disabled — if the install fails the current DM stays untouched.
# Escape hatch: EILNIRI_KEEP_DM=1 keeps the existing DM as-is.

stage_dm() {
    if stage_done dm; then return; fi

    section "$(_t "Display Manager" "Display Manager")" "$(_t "auto (ly / gdm, replaces existing)" "auto (ly / gdm, replaces existing)")"

    # A DM only ever starts under graphical.target. If the system default target is not
    # graphical (Ubuntu Server / previously switched to multi-user), the machine boots to a
    # plain tty login and NO display manager runs — fix the default target explicitly.
    if [ "$DRY_RUN" -eq 1 ]; then
        log "$(_t "[DRY-RUN] would ensure default target: graphical.target" "[DRY-RUN] would ensure default target: graphical.target")"
    elif [ "$(systemctl get-default 2>/dev/null)" != "graphical.target" ]; then
        log "$(_t "Default target is not graphical.target, switching to graphical.target..." "Default target is not graphical.target, switching to graphical.target...")"
        if exe systemctl set-default graphical.target; then
            success "$(_t "Default target set to graphical.target" "Default target set to graphical.target")"
        else
            warn "$(_t "Failed to set default target to graphical.target; the machine may still boot to a plain tty." "Failed to set default target to graphical.target; the machine may still boot to a plain tty.")"
        fi
    fi

    local known_dms=(gdm3 gdm sddm lxdm ly greetd plasma-login-manager lemurs)
    local dm_pkgs dm_unit
    dm_pkgs="ly"; dm_unit="ly@tty1"

    # what is currently configured/installed?
    local current=""
    if [ -e /etc/systemd/system/display-manager.service ]; then
        current=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || echo "display-manager.service")
        current=$(basename "$current" .service)   # strip the .service suffix for unit comparison
    fi
    if [ -z "$current" ]; then
        local dm
        for dm in "${known_dms[@]}"; do
            if pkg_installed "$dm"; then current="$dm"; break; fi
        done
    fi

    # keep the existing DM on request, or when it already is the chosen one
    if [ -n "$current" ] && { [ "${EILNIRI_KEEP_DM:-0}" = "1" ] || [ "$current" = "$dm_unit" ]; }; then
        local reason="already the chosen DM"
        [ "${EILNIRI_KEEP_DM:-0}" = "1" ] && reason="EILNIRI_KEEP_DM=1, keep"
        info_kv "$(_t "DM" "DM")" "$current" "$reason"
        stage_mark dm
        return
    fi
    [ -n "$current" ] && info_kv "$(_t "DM" "DM")" "$current" "will be replaced by $dm_pkgs"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "$(_t "[DRY-RUN] would install & enable: " "[DRY-RUN] would install & enable: ") $dm_pkgs${current:+ ($(_t "disabling " "disabling ") $current)}"
        DRY_PKGS+=("$dm_pkgs")
        DRY_SVCS+=("$dm_unit")
        stage_mark dm
        return
    fi

    # --- install the chosen DM first; never disable the current one before the replacement is in place ---
    local ok=0
    for tried in "$dm_pkgs|$dm_unit" "gdm3|gdm3" "sddm|sddm"; do
        local tpkg="${tried%%|*}" tunit="${tried##*|}"
        if pm_install "$tpkg"; then
            dm_pkgs="$tpkg"; dm_unit="$tunit"; ok=1
            break
        fi
        warn "$(_t "Display manager install failed, trying next..." "Display manager install failed, trying next...") ($tpkg)"
    done
    if [ "$ok" -eq 0 ]; then
        FAILED_PKGS+=("dm:$dm_unit")
        warn "$(_t "No display manager could be installed; keeping the existing one (") $current$(_t ") unchanged — run niri-session from tty after reboot." ") unchanged — run niri-session from tty after reboot.")"
        return   # not marked: rerun retries
    fi

    # --- disable every known DM and the display-manager.service entry ---
    local dm
    for dm in "${known_dms[@]}"; do
        exe systemctl disable "$dm" 2>/dev/null || true
    done
    if [ -e /etc/systemd/system/display-manager.service ]; then
        exe systemctl disable display-manager.service 2>/dev/null || rm -f /etc/systemd/system/display-manager.service
    fi

    # --- enable the chosen DM ---
    if exe systemctl enable "$dm_unit"; then
        # verify: the unit must be enabled, and (except ly, which runs on tty1 directly)
        # display-manager.service must point at the new DM
        local _verify_ok=1
        if ! systemctl is-enabled --quiet "$dm_unit" 2>/dev/null; then
            _verify_ok=0
            warn "$(_t "Verification failed: " "Verification failed: ") $dm_unit $(_t "is not enabled." "is not enabled.")"
        fi
        if [ "$dm_unit" != "ly@tty1" ] && [ -e /etc/systemd/system/display-manager.service ]; then
            local _dm_link
            _dm_link=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || echo "")
            if [ "$(basename "$_dm_link" .service)" != "$dm_unit" ]; then
                _verify_ok=0
                warn "$(_t "Verification failed: display-manager.service points to " "Verification failed: display-manager.service points to ") ${_dm_link:-unknown}$(_t ", expected " ", expected ") $dm_unit"
            fi
        fi
        if [ "$_verify_ok" -eq 1 ]; then
            ENABLED_SVCS+=("$dm_unit")
            success "$(_t "Display manager switched to: " "Display manager switched to: ") $dm_pkgs"
            stage_mark dm
        else
            FAILED_PKGS+=("dm:$dm_unit")
            warn "$(_t "Display manager enable verification failed; run niri-session from tty after reboot." "Display manager enable verification failed; run niri-session from tty after reboot.")"
            # not marked: rerun retries
        fi
    else
        FAILED_PKGS+=("dm:$dm_unit")
        warn "$(_t "Display manager enable failed; run niri-session from tty after reboot." "Display manager enable failed; run niri-session from tty after reboot.")"
        # not marked: rerun retries
    fi
}

# --- 4.6 config snapshot (backup before deploy) ---

stage_backup() {
    if stage_done backup; then return; fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "$(_t "[DRY-RUN] Skipping config backup." "[DRY-RUN] Skipping config backup.")"
        stage_mark backup
        return
    fi

    section "$(_t "Config Snapshot" "Config Snapshot")" "$(_t "Create rollback point before deploy" "Create rollback point before deploy")"
    local snap_cfg="$BASE_DIR/configs"
    if [ ! -d "$snap_cfg/.config" ]; then
        log "$(_t "configs/ not present — skipping rollback backup." "configs/ not present — skipping rollback backup.")"
        stage_mark backup
        return
    fi

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local tgz="$BACKUP_DIR/snapshot-$ts.tar.gz"
    mkdir -p "$BACKUP_DIR"

    # collect existing config paths that will be overwritten and packed
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
        log "$(_t "No existing config to backup, skipping." "No existing config to backup, skipping.")"
    elif confirm "$(_t "Backup current config to snapshot? [Y/n] (default Y, 15s):" "Backup current config to snapshot? [Y/n] (default Y, 15s):")" "Y" 15; then
        if exe tar czf "$tgz" -C / "${targets[@]#/}" 2>/dev/null; then
            success "$(_t "Snapshot saved: " "Snapshot saved: ") $tgz"
            info_kv "$(_t "Backup Items" "Backup Items")" "${#targets[@]} items"
        else
            warn "$(_t "Snapshot creation failed, continuing without rollback point." "Snapshot creation failed, continuing without rollback point.")"
        fi
    else
        log "$(_t "Skipping backup, continuing." "Skipping backup, continuing.")"
    fi
    stage_mark backup
}

# --- 4.7 config deploy ---

# Install the zsh runtime that configs/.zshrc depends on (oh-my-zsh + its custom
# plugins + starship + eza + bat).  The distro packages for zsh-autosuggestions /
# zsh-syntax-highlighting cannot satisfy oh-my-zsh's plugins=() list, and
# oh-my-zsh itself is not packaged in Debian/RHEL at all — this is why the
# collected .zshrc only ever worked on the Arch reference machine.  Runs only
# when zsh was selected; every step is best-effort with a MANUAL_ITEMS note on
# failure (the .zshrc itself is tolerant of missing pieces).
install_zsh_extras() {
    local _has_zsh=0 _p
    for _p in ${REPO_SEL[@]+"${REPO_SEL[@]}"}; do
        [ "$_p" = "zsh" ] && _has_zsh=1
    done
    [ "$_has_zsh" -eq 1 ] || return 0

    if [ "$DRY_RUN" -eq 1 ]; then
        DRY_PKGS+=("oh-my-zsh (git clone) starship eza bat")
        return "$DRY_RUN_RC"
    fi

    # git is needed for the clones; not guaranteed present on Debian/RHEL.
    command -v git >/dev/null 2>&1 || pm_install git 2>/dev/null || true

    # 1) oh-my-zsh itself (official repo first; gitee mirror fallback for CN networks)
    if [ ! -d "$HOME_DIR/.oh-my-zsh" ]; then
        log "$(_t "Installing oh-my-zsh..." "Installing oh-my-zsh...")"
        if as_user git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME_DIR/.oh-my-zsh" 2>/dev/null \
            || as_user git clone --depth=1 https://gitee.com/mirrors/oh-my-zsh.git "$HOME_DIR/.oh-my-zsh" 2>/dev/null; then
            INSTALLED_PKGS+=("oh-my-zsh")
        else
            MANUAL_ITEMS+=("oh-my-zsh — clone failed (GitHub 与 gitee 镜像均不可达); 手动: git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git $HOME_DIR/.oh-my-zsh")
        fi
    else
        log "$(_t "oh-my-zsh already present, skipping." "oh-my-zsh already present, skipping.")"
    fi

    # 2) the two plugins listed in configs/.zshrc — must live in $ZSH_CUSTOM/plugins
    #    for oh-my-zsh's plugins=() to find them (distro packages don't).
    if [ -d "$HOME_DIR/.oh-my-zsh" ]; then
        mkdir -p "$HOME_DIR/.oh-my-zsh/custom/plugins"
        local _plugin _plug_url
        for _plugin in zsh-autosuggestions zsh-syntax-highlighting; do
            if [ ! -d "$HOME_DIR/.oh-my-zsh/custom/plugins/$_plugin" ]; then
                case "$_plugin" in
                    zsh-autosuggestions)   _plug_url="https://github.com/zsh-users/zsh-autosuggestions" ;;
                    zsh-syntax-highlighting) _plug_url="https://github.com/zsh-users/zsh-syntax-highlighting" ;;
                esac
                log "$(_t "Installing oh-my-zsh plugin: " "Installing oh-my-zsh plugin: ") $_plugin"
                as_user git clone --depth=1 "$_plug_url" \
                    "$HOME_DIR/.oh-my-zsh/custom/plugins/$_plugin" 2>/dev/null \
                    || MANUAL_ITEMS+=("oh-my-zsh plugin $_plugin — clone failed")
            fi
        done
        chown -R "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" \
            "$HOME_DIR/.oh-my-zsh" 2>/dev/null || true
    fi

    # 3) starship (configs/.zshrc evals `starship init zsh`); not packaged on Debian
    if ! command -v starship >/dev/null 2>&1; then
        log "$(_t "Installing starship..." "Installing starship...")"
        if exe bash -c 'curl -sSfL https://starship.rs/install.sh | sh -s -- -y -b /usr/local/bin' 2>/dev/null; then
            INSTALLED_PKGS+=("starship")
        else
            MANUAL_ITEMS+=("starship — install failed; run: curl -sSfL https://starship.rs/install.sh | sh -s -- -y")
        fi
    fi
    # 保证 .zshrc 有可用的主题美化：即使 starship 没装上、或参考机配置是空主题，
    # 也把 ZSH_THEME 设为内置主题（agnoster，nerd font 提供 powerline 符号）。
    # 若 starship 可用，其 eval 在 .zshrc 末尾会覆盖 PROMPT，主题作为兜底。
    if [ -f "$HOME_DIR/.zshrc" ] && grep -q '^ZSH_THEME=""' "$HOME_DIR/.zshrc" 2>/dev/null; then
        sed -i 's/^ZSH_THEME=""/ZSH_THEME="agnoster"/' "$HOME_DIR/.zshrc" 2>/dev/null || true
        log "$(_t "Set ZSH_THEME=agnoster (oh-my-zsh beautification)" "Set ZSH_THEME=agnoster (oh-my-zsh beautification)")"
    fi

    # 4) eza (aliased in .zshrc): repo package first, cargo --root /usr/local as fallback
    #    (Debian 12 / Ubuntu 24.04 have no eza package yet; on RHEL eza lives in EPEL)
    if ! command -v eza >/dev/null 2>&1; then
        log "$(_t "Installing eza..." "Installing eza...")"
        pm_install eza 2>/dev/null || true
        if ! command -v eza >/dev/null 2>&1; then
            # RHEL family: eza is in EPEL, not the base repos (Fedora has it in base)
            if [ "$DISTRO_FAMILY" = rhel ] && ! rpm -q epel-release >/dev/null 2>&1; then
                log "$(_t "eza not in base RHEL repos — enabling EPEL and retrying..." "eza not in base RHEL repos — enabling EPEL and retrying...")"
                pm_install epel-release 2>/dev/null || true
                pm_install eza 2>/dev/null || true
            fi
            if ! command -v eza >/dev/null 2>&1; then
                if command -v cargo >/dev/null 2>&1 && exe cargo install --locked --root /usr/local eza 2>/dev/null; then
                    INSTALLED_PKGS+=("eza (cargo build)")
                else
                    MANUAL_ITEMS+=("eza — no repo package and cargo build failed; install manually (dnf --enablerepo=epel install eza / apt install eza / cargo install eza)")
                fi
            fi
        fi
    fi

    # 5) bat (aliased in .zshrc): on Debian/Ubuntu the binary is named batcat,
    #    so provide /usr/local/bin/bat -> batcat when needed.
    if ! command -v bat >/dev/null 2>&1; then
        pm_install bat 2>/dev/null || true
        if ! command -v bat >/dev/null 2>&1 && command -v batcat >/dev/null 2>&1; then
            ln -sf /usr/bin/batcat /usr/local/bin/bat
        fi
    fi
}

prune_config_backups() { # $1 = directory, $2 = basename glob
    local dir="$1" pattern="$2" backup
    [ -d "$dir" ] || return 0
    mapfile -t backups < <(
        find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | awk 'NR > 1 { sub(/^[^ ]+ /, ""); print }'
    )
    for backup in "${backups[@]}"; do
        [ -n "$backup" ] && rm -f -- "$backup"
    done
}

deploy_one() { # $1 = source path, $2 = destination path
    local src="$1" dst="$2" ts="$3"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        log "$(_t "Backup existing: " "Backup existing: ")$dst -> $dst.bak-$ts"
        exe mv "$dst" "$dst.bak-$ts"
        prune_config_backups "$(dirname "$dst")" "$(basename "$dst").bak-*"
    fi
    exe cp -r "$src" "$dst"
    exe chown -R "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$dst"
}

stage_configs() {
    if stage_done configs; then
        log "$(_t "Config deploy stage done, skipping." "Config deploy stage done, skipping.")"
        return
    fi
    local snap="$BASE_DIR/configs"
    if [ ! -d "$snap" ]; then
        log "$(_t "configs/ not present — skipping config deploy." "configs/ not present — skipping config deploy.")"
        return
    fi

    section "$(_t "Config Deploy" "Config Deploy")" "Target: $HOME_DIR"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)

    shopt -s nullglob dotglob
    local item name
    # ~/.config/<name>
    for item in "$snap/.config"/*; do
        name=$(basename "$item")
        deploy_one "$item" "$HOME_DIR/.config/$name" "$ts"
    done
    # ~/.local/share/<name> (fixed niri-session etc.)
    for item in "$snap/.local/share"/*; do
        name=$(basename "$item")
        [ -d "$item" ] || continue
        mkdir -p "$HOME_DIR/.local/share"
        deploy_one "$item" "$HOME_DIR/.local/share/$name" "$ts"
    done 2>/dev/null
    # ~/.local/share/applications (custom desktop files)
    for item in "$snap/.local/share/applications"/*; do
        [ -f "$item" ] || continue
        mkdir -p "$HOME_DIR/.local/share/applications"
        deploy_one "$item" "$HOME_DIR/.local/share/applications/$(basename "$item")" "$ts"
    done 2>/dev/null
    # ~/.local/bin (fixed niri-session etc.)
    for item in "$snap/.local/bin"/*; do
        [ -f "$item" ] || continue
        mkdir -p "$HOME_DIR/.local/bin"
        deploy_one "$item" "$HOME_DIR/.local/bin/$(basename "$item")" "$ts"
    done 2>/dev/null
    # home dotfiles (e.g. .pam_environment)
    for item in "$snap"/.*; do
        name=$(basename "$item")
        [[ "$name" = "." || "$name" = ".." || "$name" = ".config" ]] && continue
        [ -f "$item" ] || continue
        deploy_one "$item" "$HOME_DIR/$name" "$ts"
    done
    shopt -u nullglob dotglob

    # enable PipeWire user services (if the audio group was installed)
    local _pw=0
    for _p in ${REPO_SEL[@]+"${REPO_SEL[@]}"}; do
        [ "$_p" = "pipewire-pulse" ] || [ "$_p" = "wireplumber" ] && _pw=1
    done
    if [ "$_pw" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        log "$(_t "Enabling PipeWire user services..." "Enabling PipeWire user services...")"
        as_user systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true
    fi

    # enable waypaper user services (wallpaper restore on login + random-change timer),
    # deployed from configs/.config/systemd/user/. Only when waypaper was selected.
    if [ "$DRY_RUN" -eq 0 ]; then
        # 修正 user unit 里 ExecStart 的二进制绝对路径：参考机是 Arch，二进制多在
        # /usr/bin；Debian/RHEL 系 pip(--user)、源码构建装到的可能是 /usr/local/bin
        # 或 ~/.local/bin。路径对不上会 "Failed at step EXEC spawning ... No such file"
        # （waypaper/hypridle 都中过招）。按 basename 在三个常见位置找真实二进制并改写。
        local _sf _exe _base _new _cand
        for _sf in "$HOME_DIR"/.config/systemd/user/*.service; do
            [ -f "$_sf" ] || continue
            while IFS= read -r _exe; do
                _exe=${_exe%% *}                    # 去掉尾部参数
                case "$_exe" in /*) ;; *) continue ;; esac
                [ -x "$_exe" ] && continue          # 路径存在就不用改
                _base=$(basename "$_exe")
                _new=""
                for _cand in /usr/bin/$_base /usr/local/bin/$_base "$HOME_DIR/.local/bin/$_base"; do
                    [ -x "$_cand" ] && { _new="$_cand"; break; }
                done
                if [ -n "$_new" ]; then
                    log "$(_t "fix ExecStart in " "fix ExecStart in ") $(basename "$_sf")$(_t ": " ": ") $_exe -> $_new"
                    sed -i "s#^ExecStart=$_exe#ExecStart=$_new#" "$_sf" 2>/dev/null || true
                fi
            done < <(sed -n 's/^ExecStart=//p' "$_sf" 2>/dev/null)
        done

        # waybar 由 GDM/systemd session 启动；niri 中的 spawn-at-startup 会
        # 产生第二个实例，因此将该启动项注释掉。
        if [ -f "$HOME_DIR/.config/niri/config.kdl" ] \
            && grep -q 'spawn-at-startup.*"waybar"' "$HOME_DIR/.config/niri/config.kdl" 2>/dev/null; then
            sed -i -E 's/^([[:space:]]*)spawn-at-startup[[:space:]]+"waybar"/\1# spawn-at-startup "waybar" (started by GDM\/systemd)/' "$HOME_DIR/.config/niri/config.kdl"
            chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$HOME_DIR/.config/niri/config.kdl" 2>/dev/null || true
            pkill -u "$TARGET_USER" -x waybar 2>/dev/null || true
            sleep 1
            log "$(_t "Disabled niri Waybar startup; GDM/systemd will provide the only instance" "Disabled niri Waybar startup; GDM/systemd will provide the only instance")"
        fi

        # 光标拖影：QEMU/KVM 虚拟机常因虚拟硬件 cursor plane 与 Niri 不兼容。
        # Keep the environment file for user services, and export the same
        # variables from the niri-session wrapper so GDM definitely inherits them.
        if command -v systemd-detect-virt >/dev/null 2>&1; then
            local _virt
            _virt=$(systemd-detect-virt 2>/dev/null || true)
            case "$_virt" in
                qemu|kvm)
                    local _cursor_env="$HOME_DIR/.config/environment.d/90-eilniri-cursor.conf"
                    mkdir -p "$(dirname "$_cursor_env")"
                    if [ ! -f "$_cursor_env" ] || ! grep -q '^WLR_NO_HARDWARE_CURSORS=1$' "$_cursor_env" 2>/dev/null; then
                        printf '%s\n' 'WLR_NO_HARDWARE_CURSORS=1' 'WLR_RENDERER_ALLOW_SOFTWARE=1' > "$_cursor_env"
                        chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$_cursor_env" 2>/dev/null || true
                        log "$(_t "Enabled software cursor fallback for QEMU/KVM to prevent ghosting" "Enabled software cursor fallback for QEMU/KVM to prevent ghosting")"
                    fi
                    warn "$(_t "检测到 QEMU/KVM：已启用软件光标回退。若仍有拖影，请将虚拟显卡设为 virtio-gpu 并开启 3D 加速（gl=on），或改用 SPICE 显示协议。" "QEMU/KVM detected: software cursor fallback is enabled. If ghosting remains, use virtio-gpu with 3D acceleration (gl=on), or use the SPICE display protocol.")"
                    ;;
            esac
        fi

        # niri 配置自检：部署后若 niri 可用，validate 一次；失败说明配置被破坏，
        # 给出明确提示（下次重跑 stage_configs 会用仓库干净配置重新部署）。
        if command -v niri >/dev/null 2>&1 && [ -f "$HOME_DIR/.config/niri/config.kdl" ] && [ "$DRY_RUN" -eq 0 ]; then
            if ! as_user niri validate -c "$HOME_DIR/.config/niri/config.kdl" >/dev/null 2>&1; then
                warn "$(_t "niri config validation FAILED — 配置可能被破坏，快捷键/壁纸会失效。重跑 restore 会自动用仓库干净配置恢复。" "niri config validation FAILED — the config may be broken (hotkeys/wallpaper will fail). Rerun restore to redeploy the clean config.")"
            else
                log "$(_t "niri config validated OK" "niri config validated OK")"
            fi
        fi

        local _has_wp=0
        for _p in ${REPO_SEL[@]+"${REPO_SEL[@]}"}; do
            [ "$_p" = "waypaper" ] && _has_wp=1
        done
        if [ "$_has_wp" -eq 1 ] && [ -f "$HOME_DIR/.config/systemd/user/waypaper.service" ]; then
            log "$(_t "Enabling waypaper user services..." "Enabling waypaper user services...")"
            as_user systemctl --user daemon-reload 2>/dev/null || true
            as_user systemctl --user enable --now waypaper.service waypaper-random.timer 2>/dev/null || true
        fi

        # 壁纸自愈：awww 已装则确保有壁纸状态文件（生成默认渐变壁纸 / 修正 waypaper 路径）
        _ensure_wallpaper
        _ensure_waypaper_desktop   # pip 装的 waypaper 无 .desktop → fuzzel 无图标
    fi

    # fcitx5 IME environment variables: ~/.pam_environment is disabled by default on
    # Debian 12+ / Ubuntu 22.04+ (pam_env user_readenv removed), so the IME vars shipped
    # there never load on modern systems. Write them to environment.d (systemd reads it)
    # as a fallback when fcitx5 was selected and no ime.conf is already present.
    if [ "$DRY_RUN" -eq 0 ]; then
        local _has_ime=0
        for _p in ${REPO_SEL[@]+"${REPO_SEL[@]}"}; do
            case "$_p" in fcitx5|fcitx5-*) _has_ime=1; break ;; esac
        done
        if [ "$_has_ime" -eq 1 ] && [ -n "$TARGET_USER" ]; then
            local _imed="$HOME_DIR/.config/environment.d"
            mkdir -p "$_imed"
            if [ ! -f "$_imed/ime.conf" ]; then
                cat > "$_imed/ime.conf" <<'IMEEOF'
GTK_IM_MODULE=fcitx5
QT_IM_MODULE=fcitx5
XMODIFIERS=@im=fcitx5
SDL_IM_MODULE=fcitx5
GLFW_IM_MODULE=fcitx5
IMEEOF
                chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$_imed/ime.conf" 2>/dev/null || true
                log "$(_t "Wrote ~/.config/environment.d/ime.conf (fcitx5 IME vars; .pam_environment is ignored on Debian 12+/Ubuntu 22.04+)" "Wrote ~/.config/environment.d/ime.conf (fcitx5 IME vars; .pam_environment is ignored on Debian 12+/Ubuntu 22.04+)")"
            fi
        fi
    fi
    # Keep zsh and its shell customization exclusive to Arch. Debian/RHEL use
    # the system bash without installing or changing the user's login shell.
    for _p in ${REPO_SEL[@]+"${REPO_SEL[@]}"}; do
        if [ "$_p" = "zsh" ] && [ "$DRY_RUN" -eq 0 ] && [ "$(getent passwd "$TARGET_USER" | cut -d: -f7)" != "/usr/bin/zsh" ]; then
            exe chsh -s /usr/bin/zsh "$TARGET_USER" 2>/dev/null || warn "$(_t "Failed to set zsh as default shell" "Failed to set zsh as default shell")"
            break
        fi
    done

    # oh-my-zsh + starship + eza + bat (the runtime configs/.zshrc needs)
    install_zsh_extras

    success "$(_t "Config deploy complete." "Config deploy complete.")"
    stage_mark configs
}

# --- 4.7b disable system components from other desktop environments ---
# No DE other than niri is needed on this machine; disable the conflicting components
# (notifications, settings daemons, etc.) so the niri session runs cleanly.  Every action
# is recorded in $BASE_DIR/.system_disabled and is reversible via `restore-system`.
DISABLE_MANIFEST="$BASE_DIR/.system_disabled"

# Older eilNiri versions masked these GDM helpers, which makes a valid niri
# Wayland session handoff appear as an immediate black screen. Always remove
# those stale masks on RHEL-family restores; they are never valid cleanup targets.
unmask_gdm_wayland() {
    return 0
}

stage_disable_system() {
    if stage_done sysdisable; then return; fi
    if [ "${EILNIRI_KEEP_SYS:-0}" = "1" ]; then
        log "$(_t "EILNIRI_KEEP_SYS=1: skipping system component disable." "EILNIRI_KEEP_SYS=1: skipping system component disable.")"
        stage_mark sysdisable
        return
    fi

    section "$(_t "System Cleanup" "System Cleanup")" "$(_t "disabling other-DE components (mask/stop/hidden)" "disabling other-DE components (mask/stop/hidden)")"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "$(_t "[DRY-RUN] Would disable system components of other desktop environments." "[DRY-RUN] Would disable system components of other desktop environments.")"
        stage_mark sysdisable
        return
    fi

    > "$DISABLE_MANIFEST"  # Clear manifest before rebuild
    
    local line type name reason _rc _adir _afile valid
    local disabled_count=0 skipped_count=0 failed_items=()
    
    for line in "${DISABLE_SYS[@]}"; do
        IFS='|' read -r type name reason <<< "$line"
        valid=0
        
        case "$type" in
            autostart)
                # Check if autostart file exists in system
                if [ -f "/etc/xdg/autostart/$name" ]; then
                    _adir="$HOME_DIR/.config/autostart"
                    mkdir -p "$_adir"
                    _afile="$_adir/$name"
                    
                    # Write Hidden=true override
                    cat > "$_afile" <<ASEOF
[Desktop Entry]
Hidden=true
ASEOF
                    chown -R "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$_afile" 2>/dev/null || true
                    
                    # Verify file was created and contains Hidden=true
                    if [ -f "$_afile" ] && grep -q "Hidden=true" "$_afile"; then
                        log "$(_t "  [✓ DISABLED] autostart: " "  [✓ DISABLED] autostart: ")$name"
                        echo "   $(_t "   └─ Reason: " "   └─ Reason: ")$reason"
                        valid=1
                        disabled_count=$((disabled_count + 1))
                        
                        # Try to kill running process (extract binary name from .desktop name)
                        local _proc_base="${name%.desktop}"
                        if pkill -u "$TARGET_USER" -f "$_proc_base" 2>/dev/null; then
                            log "$(_t "   └─ Killed running process: " "   └─ Killed running process: ")$_proc_base"
                        fi
                    else
                        failed_items+=("autostart|$name")
                    fi
                else
                    skipped_count=$((skipped_count + 1))
                fi
                ;;
                
            userunit)
                # Check if unit exists for this user
                local _unit_exists=0
                if as_user systemctl --user list-unit-files 2>/dev/null | grep -q "^$name"; then
                    _unit_exists=1
                fi
                
                if [ "$_unit_exists" -eq 1 ]; then
                    # Stop the unit first (if running)
                    as_user systemctl --user stop "$name" 2>/dev/null || true
                    
                    # Mask the unit
                    _rc=0
                    as_user systemctl --user mask "$name" 2>/dev/null || _rc=$?
                    
                    if [ "$_rc" -eq 0 ]; then
                        # Verify mask was successful
                        if as_user systemctl --user is-enabled "$name" 2>/dev/null | grep -q "masked"; then
                            log "$(_t "  [✓ DISABLED] user unit: " "  [✓ DISABLED] user unit: ")$name"
                            echo "   $(_t "   └─ Reason: " "   └─ Reason: ")$reason"
                            valid=1
                            disabled_count=$((disabled_count + 1))
                        else
                            failed_items+=("userunit|$name")
                        fi
                    else
                        failed_items+=("userunit|$name")
                    fi
                else
                    skipped_count=$((skipped_count + 1))
                fi
                ;;
                
            systemunit)
                # Check if unit exists on system
                local _unit_exists=0
                if systemctl list-unit-files 2>/dev/null | grep -q "^$name"; then
                    _unit_exists=1
                fi
                
                if [ "$_unit_exists" -eq 1 ]; then
                    # Stop the unit first (if running)
                    systemctl stop "$name" 2>/dev/null || true
                    
                    # Mask the unit
                    _rc=0
                    systemctl mask "$name" 2>/dev/null || _rc=$?
                    
                    if [ "$_rc" -eq 0 ]; then
                        # Verify mask was successful
                        if systemctl is-enabled "$name" 2>/dev/null | grep -q "masked"; then
                            log "$(_t "  [✓ DISABLED] system unit: " "  [✓ DISABLED] system unit: ")$name"
                            echo "   $(_t "   └─ Reason: " "   └─ Reason: ")$reason"
                            valid=1
                            disabled_count=$((disabled_count + 1))
                        else
                            failed_items+=("systemunit|$name")
                        fi
                    else
                        failed_items+=("systemunit|$name")
                    fi
                else
                    skipped_count=$((skipped_count + 1))
                fi
                ;;
        esac
        
        # Record successful disables in manifest (for future restore-system)
        if [ "$valid" -eq 1 ]; then
            echo "$type|$name" >> "$DISABLE_MANIFEST"
        fi
    done
    
    # Summary
    echo ""
    info_kv "$(_t "System Components Disabled" "System Components Disabled")" "$disabled_count successfully disabled"
    if [ "$skipped_count" -gt 0 ]; then
        info_kv "$(_t "Not Found (Skipped)" "Not Found (Skipped)")" "$skipped_count components (not installed on this system)"
    fi
    
    if [ ${#failed_items[@]} -gt 0 ]; then
        warn "$(_t "Failed to disable ${#failed_items[@]} components:" "Failed to disable ${#failed_items[@]} components:")"
        for item in "${failed_items[@]}"; do
            echo -e "       ${H_YELLOW}-${NC} $item"
        done
        warn "$(_t "Stage not marked complete — rerun retries." "Stage not marked complete — rerun retries.")"
    else
        stage_mark sysdisable
        success "$(_t "All replaceable system components disabled successfully." "All replaceable system components disabled successfully.")"
    fi
}

# --- 4.8 hardware adapt (auto-detect output/resolution) ---

stage_hardware_adapt() {
    if stage_done hwadapt; then return; fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "$(_t "[DRY-RUN] Skipping hardware adapt." "[DRY-RUN] Skipping hardware adapt.")"
        stage_mark hwadapt
        return
    fi
    if [ ! -d /sys/class/drm ] || [ -z "$(ls /sys/class/drm/card*-*/status 2>/dev/null)" ]; then
        log "$(_t "No DRM device, skipping hardware adapt." "No DRM device, skipping hardware adapt.")"
        stage_mark hwadapt
        return
    fi

    section "$(_t "Hardware Adapt" "Hardware Adapt")" "$(_t "Auto-detect display" "Auto-detect display")"
    local niri_cfg="$HOME_DIR/.config/niri/config.kdl"
    local waybar_cfg="$HOME_DIR/.config/waybar/config"

    # --- 1) detect the actual output name + resolution ---
    local detected_out="" detected_mode="" p
    for p in /sys/class/drm/card*-*/status; do
        [ "$(cat "$p" 2>/dev/null)" = "connected" ] || continue
        local dir
        dir=$(dirname "$p")
        detected_out=$(basename "$dir" | sed 's/^card[0-9]-//')
        detected_mode=$(head -1 "$dir/modes" 2>/dev/null)
        [ -n "$detected_out" ] && break
    done

    if [ -z "$detected_out" ]; then
        warn "$(_t "No connected display found, skipping adapt." "No connected display found, skipping adapt.")"
        # On QEMU/KVM this usually means the virtual GPU/render backend isn't
        # producing an active output — the classic cause of niri's
        # "display output is not active" / black screen at the greeter.
        local _virt=""
        command -v systemd-detect-virt >/dev/null 2>&1 && _virt=$(systemd-detect-virt 2>/dev/null || true)
        case "$_virt" in
            qemu|kvm)
                warn "$(_t "检测到 QEMU/KVM 且无可用显示输出 — niri 进桌面可能黑屏 / 提示 display output is not active。请在虚拟机上：① 显卡设为 virtio-gpu 并开 3D（gl=on）；② 显示协议用 SPICE；③ 确保安装了对应的图形驱动（mesa/virtio_gpu）；④ libvirt 里 <video> 的 model 为 virtio 并开启渲染。改完重启即可。" "QEMU/KVM detected with no active display output — niri may black-screen / show 'display output is not active'. On the VM: 1) set the video card to virtio-gpu with 3D (gl=on); 2) use the SPICE display protocol; 3) ensure the graphics driver (mesa/virtio_gpu) is installed; 4) set libvirt <video> model=virtio with rendering enabled. Reboot after changing.")"
                ;;
        esac
        # Do not rewrite output settings when the installer cannot observe a
        # connected DRM output. The GDM session may expose it later.
        stage_mark hwadapt
        return
    fi

    # resolution format: 1920x1080 -> mode "1920x1080@60"
    local mode_line=""
    if [ -n "$detected_mode" ]; then
        local w h refresh
        w=$(echo "$detected_mode" | cut -dx -f1)
        h=$(echo "$detected_mode" | cut -dx -f2)
        # EDID offset 12 is NOT the refresh rate; proper refresh requires parsing
        # the detailed timing descriptor. Default to 60Hz to avoid bogus values.
        refresh=60
        mode_line="mode \"${w}x${h}@${refresh}\""
    fi

    info_kv "$(_t "Detected output" "Detected output")" "$detected_out" "${detected_mode:-?}"

    # --- 2) fix niri config ---
    if [ -f "$niri_cfg" ]; then
        log "$(_t "Adapting niri output config..." "Adapting niri output config...")"
        # backup
        cp "$niri_cfg" "$niri_cfg.bak-hw-$(date +%Y%m%d-%H%M%S)"
        prune_config_backups "$(dirname "$niri_cfg")" "$(basename "$niri_cfg").bak-hw-*"

        # find the first active output block and replace its name and mode
        local tmp
        tmp=$(mktemp)
        register_temp_path "$tmp"
        local in_first_output=0 found_output=0
        while IFS= read -r line; do
            if [ "$found_output" -eq 0 ] && echo "$line" | grep -qP '^\s*output\s+"'; then
                found_output=1
                in_first_output=1
                echo "output \"$detected_out\" {" >> "$tmp"
                [ -n "$mode_line" ] && echo "    $mode_line" >> "$tmp"
                continue
            fi
            if [ "$in_first_output" -eq 1 ]; then
                # skip mode lines inside the original output block
                if echo "$line" | grep -qP '^\s*mode\s+"'; then
                    [ -z "$mode_line" ] && echo "$line" >> "$tmp"
                    continue
                fi
                if echo "$line" | grep -qP '^\s*\}'; then
                    in_first_output=0
                    [ -n "$mode_line" ] && echo "}" >> "$tmp" || echo "}" >> "$tmp"
                    continue
                fi
                # skip other content inside the output block (left for the new empty block)
                continue
            fi
            # comment out the 2nd and later output blocks
            if [ "$found_output" -eq 1 ] && echo "$line" | grep -qP '^\s*output\s+"'; then
                echo "/-output $(echo "$line" | sed 's/^\s*output\s*//')" >> "$tmp"
                continue
            fi
            echo "$line" >> "$tmp"
        done < "$niri_cfg"
        mv "$tmp" "$niri_cfg"
        exe chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$niri_cfg"
        success "$(_t "niri output adapted" "niri output adapted")"
    fi

    # --- 3) fix the hardware sink in waybar config ---
    if [ -f "$waybar_cfg" ]; then
        if grep -q 'ignored-sinks' "$waybar_cfg" 2>/dev/null; then
            sed -i 's/^\(\s*"ignored-sinks":[^]]*\]\)/\/* \1 *\//' "$waybar_cfg"
            log "$(_t "waybar ignored-sinks commented" "waybar ignored-sinks commented")"
        fi
    fi


    # GPU driver hint
    if command -v lspci &>/dev/null; then
        local gpu_info
        gpu_info=$(lspci | grep -E -i 'vga|3d|display' 2>/dev/null | head -2)
        [ -n "$gpu_info" ] && info_kv "$(_t "GPU detected" "GPU detected")" "$(echo "$gpu_info" | head -1 | cut -d: -f3- | xargs)" ""
    fi

    stage_mark hwadapt
}

# --- 4.9 post-install verification (package audit + config audit) ---

stage_verify() {
    if stage_done verify; then return; fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "$(_t "[DRY-RUN] Skipping verification." "[DRY-RUN] Skipping verification.")"
        return
    fi

    section "$(_t "Verification" "Verification")" "$(_t "Install Audit & Config Audit" "Install Audit & Config Audit")"
    local missing=()

    # package audit
    local all_sel=(${REPO_SEL[@]+"${REPO_SEL[@]}"})
    if [ ${#all_sel[@]} -gt 0 ]; then
        local m
        m=$(pacman -T "${all_sel[@]}" 2>/dev/null) && true
        [ -n "$m" ] && mapfile -t missing <<< "$m"
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        warn "$(_t "Selected packages failed to install:" "Selected packages failed to install:")"
        for p in "${missing[@]}"; do echo -e "     ${H_RED}->${NC} ${H_YELLOW}$p${NC}"; done
    else
        success "$(_t "Package audit passed." "Package audit passed.")"
    fi

    # config audit
    local cfg_errors=0 d
    for d in niri waybar kitty mako hypr; do
        if [ -e "$HOME_DIR/.config/$d" ]; then
            log "  [OK] $HOME_DIR/.config/$d"
        else
            echo -e "     ${H_RED}->${NC} ${H_YELLOW}$HOME_DIR/.config/$d missing${NC}"
            cfg_errors=$((cfg_errors+1))
        fi
    done
    [ "$cfg_errors" -eq 0 ] && success "$(_t "Config audit passed." "Config audit passed.")" || warn "$cfg_errors critical config directories missing."
    stage_mark verify
}

# --- 4.10 summary report ---

print_summary() {
    section "$(_t "Summary" "Summary")" "$(_t "eilNiri restore" "eilNiri restore")"
    info_kv "$(_t "Installed" "Installed")" "${#INSTALLED_PKGS[@]} packages"
    info_kv "$(_t "Skipped" "Skipped")" "${#SKIPPED_PKGS[@]} packages"
    info_kv "$(_t "Enabled Services" "Enabled Services")" "${#ENABLED_SVCS[@]} services"
    if [ ${#ENABLED_SVCS[@]} -gt 0 ]; then
        printf "     ${DIM}%s${NC}\n" "${ENABLED_SVCS[@]}"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info_kv "$(_t "[DRY-RUN] Will install" "[DRY-RUN] Will install")" "${#DRY_PKGS[@]} packages"
        if [ ${#DRY_PKGS[@]} -gt 0 ]; then
            printf "     ${DIM}%s${NC}\n" "${DRY_PKGS[@]}"
        fi
        info_kv "$(_t "[DRY-RUN] Will enable services" "[DRY-RUN] Will enable services")" "${#DRY_SVCS[@]} services"
        if [ ${#DRY_SVCS[@]} -gt 0 ]; then
            printf "     ${DIM}%s${NC}\n" "${DRY_SVCS[@]}"
        fi
    fi
    if [ ${#FAILED_PKGS[@]} -gt 0 ]; then
        warn "Failed ${#FAILED_PKGS[@]} items:"
        printf "     ${H_RED}->${NC} %s\n" "${FAILED_PKGS[@]}"
    fi
    if [ ${#MANUAL_ITEMS[@]} -gt 0 ]; then
        warn "Manual install needed (${#MANUAL_ITEMS[@]}):"
        printf "     ${H_YELLOW}->${NC} %s\n" "${MANUAL_ITEMS[@]}"
    fi
    echo ""
    info_kv "$(_t "Log" "Log")" "$TEMP_LOG_FILE"
    info_kv "$(_t "Progress File" "Progress File")" "$STATE_FILE" "(delete after everything completes)"
    echo -e "   ${H_YELLOW}>>> It is recommended to reboot and enter the niri desktop. ${NC}"
}

do_restore() {
    init_logger
    check_root
    detect_distro

    section "$(_t "Restore" "Restore")" "v$SCRIPT_VERSION — $(_t "Restore Niri Desktop" "Restore Niri Desktop")"
    [ "$DRY_RUN" -eq 1 ] && warn "$(_t "DRY-RUN mode: printing plan only, no changes." "DRY-RUN mode: printing plan only, no changes.")"
    show_logo

    # configs/ is optional: if present it's deployed as the desktop config; if absent
    # the script still installs and configures everything else and niri runs with
    # default config. Never block or prompt the user about it — a plain `./arch-install.sh
    # restore` must just work with no prep.
    if [ ! -d "$BASE_DIR/configs" ]; then
        log "$(_t "configs/ not present — desktop config deploy skipped (niri will run with default config). To ship your own dotfiles, put them under configs/.config/" "configs/ not present — desktop config deploy skipped (niri will run with default config). To ship your own dotfiles, put them under configs/.config/")"
    fi

    # update the system first (a fresh machine has a stale package db, so installing fzf directly may fail)
    stage_preflight
    unmask_gdm_wayland
    ensure_fzf
    detect_target_user

    if stage_apps_select; then
        stage_apps_install
    fi
    # Disable other-DE components (mask tuned / GNOME / PulseAudio / ...) BEFORE
    # enabling our services — e.g. power-profiles-daemon.service fails to start if
    # tuned is still running (RHEL default), a conflict resolved by masking tuned here.
    stage_disable_system
    stage_services
    stage_dm
    stage_backup
    stage_configs
    stage_wait_builds
    stage_hardware_adapt
    stage_verify
    # clean the pacman cache to free disk space
    [ "$DISTRO_FAMILY" = arch ] && exe pacman -Sc --noconfirm 2>/dev/null || true
    ensure_dm_session   # idempotent: re-checks every run (niri build may have finished late)
    boot_env_check
    print_niri_status
    print_summary
    save_diag_bundle
}

# --- 4.10c one-line niri status (printed right before the summary) ---
print_niri_status() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    local _bin="MISSING" _desk="MISSING" _sess="unset"
    if command -v niri >/dev/null 2>&1 || [ -x /usr/local/bin/niri ]; then _bin="installed"; fi
    if [ -f /usr/local/share/wayland-sessions/niri.desktop ] || [ -f /usr/share/wayland-sessions/niri.desktop ]; then _desk="registered"; fi
    if [ -n "$TARGET_USER" ] && [ -f "/var/lib/AccountsService/users/$TARGET_USER" ]; then
        _sess=$(grep '^Session=' "/var/lib/AccountsService/users/$TARGET_USER" 2>/dev/null | sed 's/^Session=//' )
        [ -z "$_sess" ] && _sess="unset"
    fi
    echo ""
    info_kv "$(_t "NIRI STATUS" "NIRI STATUS")" "binary=$_bin | desktop=$_desk | gdm Session=$_sess"
}

# --- 4.10d diagnostic bundle (so a failed run can be shared for offline analysis) ---
save_diag_bundle() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    local _ts _bundle _tmpdir
    _ts=$(date +%Y%m%d-%H%M%S)
    _tmpdir=$(mktemp -d)
    register_temp_path "$_tmpdir"
    # gather plain-text snapshots (best effort; never fail the whole restore here)
    {
        echo "=== eilNiri diagnostic bundle ==="
        echo "Date: $(date)"
        echo "Script: v$SCRIPT_VERSION  Progress: $PROGRESS_VERSION"
        echo "Distro: $DISTRO_FAMILY ($DISTRO_ID)  Ubuntu: $UBUNTU_VER_NUM"
        echo "Target user: $TARGET_USER  Home: $HOME_DIR"
        echo
        echo "=== systemctl get-default ==="
        systemctl get-default 2>/dev/null
        echo
        echo "=== display-manager.service ==="
        readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || echo "(missing)"
        echo
        echo "=== enabled DMs ==="
        for _d in gdm gdm3 sddm ly lightdm; do systemctl is-enabled --quiet "$_d" 2>/dev/null && echo "$_d enabled"; done
        echo
        echo "=== AccountsService users/$TARGET_USER ==="
        cat "/var/lib/AccountsService/users/$TARGET_USER" 2>/dev/null || echo "(missing)"
        echo
        echo "=== gdm custom.conf ==="
        cat /etc/gdm/custom.conf /etc/gdm3/custom.conf 2>/dev/null || echo "(none)"
        echo
        echo "=== niri.desktop locations ==="
        ls -l /usr/local/share/wayland-sessions/niri.desktop /usr/share/wayland-sessions/niri.desktop 2>/dev/null || echo "(none)"
        echo
        echo "=== niri binary ==="
        command -v niri 2>/dev/null && niri --version 2>&1 | head -1 || echo "(not found)"
        echo
        echo "=== installed pkgs (gdm/niri/rust/accountsservice/hypr) ==="
        pacman -Q 2>/dev/null | grep -iE 'gdm|niri|rust|accountsservice|hypr'
        echo
        echo "=== build logs tail ==="
        for _f in "$LOG_DIR/niri-build.log" "$LOG_DIR/awww-build.log" "$LOG_DIR/xwayland-satellite-build.log" "$LOG_DIR/hyprlock-build.log" "$LOG_DIR/hypridle-build.log"; do
            [ -f "$_f" ] && { echo "--- $_f (tail 30) ---"; tail -n 30 "$_f" 2>/dev/null; }
        done
    } > "$_tmpdir/diag.txt" 2>/dev/null
    # attach the full replicate log too
    [ -f "$TEMP_LOG_FILE" ] && cp "$TEMP_LOG_FILE" "$_tmpdir/replicate.log" 2>/dev/null
    _bundle="$LOG_DIR/diag-$_ts.tar.gz"
    if tar czf "$_bundle" -C "$_tmpdir" . 2>/dev/null; then
        echo ""
        info_kv "$(_t "Diagnostic Bundle" "Diagnostic Bundle")" "$_bundle" "$(_t "(share this if niri fails to start)" "(share this if niri fails to start)")"
        write_log "DIAG" "bundle saved: $_bundle"
    fi
}

# --- 4.10b ensure display manager default session = niri (idempotent, runs on EVERY restore) ---
# The stage_dm write only happens while that stage runs, but the niri.desktop session file
# arrives later (background build). This step re-checks on every run so a late niri build
# still gets picked up as the DM default session.
# Mechanism is DM-specific: gdm uses AccountsService (Session=niri).

# gdm / gdm3: write /var/lib/AccountsService/users/<TARGET_USER> with Session=niri
ensure_gdm_session() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ -z "$TARGET_USER" ] && return 0
    local _niri_desktop=""
    [ -f /usr/local/share/wayland-sessions/niri.desktop ] && _niri_desktop=/usr/local/share/wayland-sessions/niri.desktop
    [ -z "$_niri_desktop" ] && [ -f /usr/share/wayland-sessions/niri.desktop ] && _niri_desktop=/usr/share/wayland-sessions/niri.desktop
    if [ -z "$_niri_desktop" ]; then
        warn "$(_t "niri.desktop session not registered (niri not installed / build unfinished) — login will go to the default desktop." "niri.desktop session not registered (niri not installed / build unfinished) — login will go to the default desktop.")"
        return 0
    fi

    # gdm custom.conf can override the session with DefaultSession / AutomaticLoginSession,
    # or bypass session selection entirely via AutomaticLogin (auto-login uses the default
    # session, i.e. GNOME on Ubuntu). Clear all of these so AccountsService Session=niri wins.
    local _gconf
    for _gconf in /etc/gdm/custom.conf /etc/gdm3/custom.conf; do
        if [ -f "$_gconf" ]; then
            local _changed=0
            if grep -q '^DefaultSession=' "$_gconf" 2>/dev/null; then
                sed -i 's/^DefaultSession=.*$/DefaultSession=/' "$_gconf"; _changed=1
            fi
            if grep -q '^AutomaticLoginSession=' "$_gconf" 2>/dev/null; then
                sed -i 's/^AutomaticLoginSession=.*$/AutomaticLoginSession=/' "$_gconf"; _changed=1
            fi
            # AutomaticLoginEnable=true + AutomaticLogin=<user> bypasses session selection
            # entirely (auto-login drops into the default desktop = GNOME). Disable it so the
            # user picks the session at the greeter (and AccountsService Session=niri applies).
            if grep -qi '^AutomaticLoginEnable=true' "$_gconf" 2>/dev/null; then
                sed -i 's/^AutomaticLoginEnable=.*/AutomaticLoginEnable=false/I' "$_gconf"; _changed=1
                warn "$(_t "Disabled AutomaticLoginEnable in " "Disabled AutomaticLoginEnable in ") $_gconf $(_t " (auto-login bypasses session selection)" " (auto-login bypasses session selection)")"
            fi
            [ "$_changed" -eq 1 ] && log "$(_t "Cleared session override(s) in " "Cleared session override(s) in ") $_gconf"
        fi
    done

    # gdm reads the default session via AccountsService (accounts-daemon). If the daemon is
    # missing, the Session=niri file we write below is silently ignored and login goes to GNOME.
    if ! pkg_installed accountsservice 2>/dev/null && ! pkg_installed accounts-daemon 2>/dev/null; then
        log "$(_t "Installing accountsservice (gdm reads the default session from it)..." "Installing accountsservice (gdm reads the default session from it)...")"
        pm_install accountsservice 2>/dev/null || warn "$(_t "accountsservice install failed; gdm may ignore Session=niri." "accountsservice install failed; gdm may ignore Session=niri.")"
    fi
    systemctl enable --now accounts-daemon 2>/dev/null || systemctl enable --now accountsservice 2>/dev/null || true

    local afile="/var/lib/AccountsService/users/$TARGET_USER"
    mkdir -p "$(dirname "$afile")"
    if [ -f "$afile" ] && grep -q '^Session=niri$' "$afile"; then
        log "$(_t "gdm default session already set to niri (AccountsService)" "gdm default session already set to niri (AccountsService)")"
    else
        if [ -f "$afile" ]; then
            if grep -q '^Session=' "$afile"; then
                sed -i 's/^Session=.*$/Session=niri/' "$afile"
            elif grep -q '^\[User\]' "$afile"; then
                sed -i '/^\[User\]/a Session=niri' "$afile"
            else
                # file exists but has no [User] section; append one
                echo -e '\n[User]\nSession=niri' >> "$afile"
            fi
        else
            cat > "$afile" <<'EOF'
[User]
Session=niri
EOF
            chown root:root "$afile" 2>/dev/null || true
            chmod 644 "$afile" 2>/dev/null || true
        fi
        log "$(_t "gdm default session set to niri (AccountsService Session=niri)" "gdm default session set to niri (AccountsService Session=niri)")"
    fi

    # accounts-daemon reads the file on startup; restart so it picks up the change NOW
    # (matters if the user logs in without rebooting first — the daemon may cache the old value)
    if systemctl is-active --quiet accounts-daemon 2>/dev/null; then
        exe systemctl try-restart accounts-daemon 2>/dev/null || true
    fi
}

# dispatch: pick the right mechanism for the DM that actually owns display-manager.service
ensure_dm_session() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ "$DISTRO_FAMILY" = arch ] && return 0
    local _dm
    if [ -e /etc/systemd/system/display-manager.service ]; then
        _dm=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || echo "")
        _dm=$(basename "$_dm" .service)
    else
        return 0
    fi
    case "$_dm" in
        gdm|gdm3) ensure_gdm_session ;;
        sddm)     warn "$(_t "sddm default session not supported by this script; login may go to the wrong desktop." "sddm default session not supported by this script; login may go to the wrong desktop.")" ;;
        *)        warn "$(_t "Unknown DM '$_dm' — cannot set niri as the default session." "Unknown DM '$_dm' — cannot set niri as the default session.")" ;;
    esac
}

# --- 4.11 boot environment self-check ---
# Printed right before the summary so a "still stuck at a tty login" problem is diagnosable
# in one glance: default target, display-manager.service target, DM enabled state.
boot_env_check() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    section "$(_t "Boot Environment Check" "Boot Environment Check")" "$(_t "default target & display manager" "default target & display manager")"
    info_kv "$(_t "Default Target" "Default Target")" "$(systemctl get-default 2>/dev/null || echo unknown)" "$(_t "(must be graphical.target)" "(must be graphical.target)")"
    if [ -e /etc/systemd/system/display-manager.service ]; then
        local _dl
        _dl=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || echo unknown)
        info_kv "$(_t "Display Manager" "Display Manager")" "$(basename "$_dl")" "display-manager.service → $_dl"
    else
        info_kv "$(_t "Display Manager" "Display Manager")" "$(_t "none configured" "none configured")" "$(_t "display-manager.service missing — boot will stay at a tty" "display-manager.service missing — boot will stay at a tty")"
    fi
    local _dm
    for _dm in sddm gdm3 gdm ly; do
        if systemctl is-enabled --quiet "$_dm" 2>/dev/null; then
            info_kv "$(_t "Enabled DM" "Enabled DM")" "$_dm" ""
            break
        fi
    done
    # niri session registration + DM default session
    local _niri_desktop=""
    [ -f /usr/local/share/wayland-sessions/niri.desktop ] && _niri_desktop=/usr/local/share/wayland-sessions/niri.desktop
    [ -z "$_niri_desktop" ] && [ -f /usr/share/wayland-sessions/niri.desktop ] && _niri_desktop=/usr/share/wayland-sessions/niri.desktop
    if [ -n "$_niri_desktop" ]; then
        info_kv "$(_t "Niri Session" "Niri Session")" "$(_t "registered" "registered")" "$_niri_desktop"
    else
        info_kv "$(_t "Niri Session" "Niri Session")" "$(_t "NOT registered" "NOT registered")" "$(_t "(niri build incomplete — login goes to the default desktop)" "(niri build incomplete — login goes to the default desktop)")"
    fi
    # gdm / gdm3: AccountsService
    if [ -n "$TARGET_USER" ] && [ -f "/var/lib/AccountsService/users/$TARGET_USER" ]; then
        local _as
        _as=$(grep '^Session=' "/var/lib/AccountsService/users/$TARGET_USER" 2>/dev/null | sed 's/^Session=//')
        if [ -n "$_as" ]; then
            info_kv "$(_t "gdm Session" "gdm Session")" "AccountsService=$_as" "$(_t "(must be niri)" "(must be niri)")"
            [ "$_as" != "niri" ] && warn "$(_t "gdm AccountsService Session=$_as — login will not go to niri." "gdm AccountsService Session=$_as — login will not go to niri.")"
        fi
    fi
    # session files visible to the DM
    local _sessions
    _sessions=$(ls /usr/share/xsessions /usr/local/share/xsessions /usr/share/wayland-sessions /usr/local/share/wayland-sessions 2>/dev/null | sort -u | tr '\n' ' ')
    info_kv "$(_t "Sessions (all)" "Sessions (all)")" "${_sessions:-none}" "$(_t "(niri present if niri.desktop listed)" "(niri present if niri.desktop listed)")"

    # final assertion: will gdm actually boot into niri?
    local _boot_ok=1 _reason=""
    [ -z "$_niri_desktop" ] && { _boot_ok=0; _reason="niri.desktop not registered (build incomplete)"; }
    if [ -n "$TARGET_USER" ] && [ -f "/var/lib/AccountsService/users/$TARGET_USER" ]; then
        local _as
        _as=$(grep '^Session=' "/var/lib/AccountsService/users/$TARGET_USER" 2>/dev/null | sed 's/^Session=//')
        if [ "$_as" != "niri" ]; then
            _boot_ok=0
            [ -n "$_reason" ] && _reason="; "
            _reason="${_reason}gdm AccountsService Session='${_as:-unset}' (expected niri)"
        fi
    fi
    if [ "$_boot_ok" -eq 1 ]; then
        success "$(_t "Boot check: gdm will start niri after reboot." "Boot check: gdm will start niri after reboot.")"
    else
        echo -e "   ${H_RED}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
        echo -e "   ${H_RED}┃  BOOT CHECK FAILED: gdm will NOT start niri.                       ┃${NC}"
        echo -e "   ${H_RED}┃  Reason: $_reason${NC}"
        echo -e "   ${H_RED}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
        write_log "FAIL" "boot check failed: $_reason"
    fi
}

do_rollback() {
    init_logger
    check_root
    detect_distro
    detect_target_user

    section "$(_t "Rollback" "Rollback")" "$(_t "Config Rollback" "Config Rollback")"
    if [ ! -d "$BACKUP_DIR" ]; then
        error "No snapshots found ($BACKUP_DIR does not exist)."
        exit 1
    fi

    local snapshots=()
    mapfile -t snapshots < <(find "$BACKUP_DIR" -maxdepth 1 -name 'snapshot-*.tar.gz' -printf '%T@ %f\n' 2>/dev/null | sort -rn | awk '{print $2}')
    if [ ${#snapshots[@]} -eq 0 ]; then
        error "$(_t "No snapshot files found." "No snapshot files found.")"
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
    selected=$(printf "%s\n" "${lines[@]}" | fzf_single " Select snapshot to restore ") || {
        warn "$(_t "User cancelled." "User cancelled.")"
        return
    }
    if [ -z "$selected" ]; then
        warn "$(_t "No snapshot selected." "No snapshot selected.")"
        return
    fi
    local snapshot
    snapshot=$(echo "$selected" | cut -f1 -d"$(printf '\t')" | head -1)

    section "$(_t "Restoring" "Restoring")" "$snapshot"
    if ! confirm "$(_t "Confirm restore from snapshot ${snapshot}? [y/N] (default N, 15s):" "Confirm restore from snapshot ${snapshot}? [y/N] (default N, 15s):")" "N" 15; then
        log "$(_t "Rollback cancelled." "Rollback cancelled.")"
        return
    fi

    local tgz="$BACKUP_DIR/$snapshot"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local workdir
    workdir=$(mktemp -d)
    register_temp_path "$workdir"

    exe tar xzf "$tgz" -C "$workdir" || { error "$(_t "Failed to extract snapshot." "Failed to extract snapshot.")"; exit 1; }

    local item name target
    shopt -s nullglob dotglob
    for item in "$workdir"/home/*/.config/*; do
        name=$(basename "$item")
        target="$HOME_DIR/.config/$name"
        if [ -e "$target" ] || [ -L "$target" ]; then
            exe mv "$target" "$target.bak-$ts"
            prune_config_backups "$(dirname "$target")" "$(basename "$target").bak-*"
        fi
        exe cp -r "$item" "$target"
        exe chown -R "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$target"
    done
    # restore ~/.local/share/ (fixed niri-session etc.)
    for item in "$workdir"/home/*/.local/share/*/*; do
        [ -f "$item" ] && continue
        name=$(basename "$item")
        local parent
        parent=$(basename "$(dirname "$item")")
        target="$HOME_DIR/.local/share/$parent/$name"
        mkdir -p "$(dirname "$target")"
        if [ -e "$target" ] || [ -L "$target" ]; then
            exe mv "$target" "$target.bak-$ts"
            prune_config_backups "$(dirname "$target")" "$(basename "$target").bak-*"
        fi
        exe cp -r "$item" "$target"
        exe chown -R "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$target"
    done 2>/dev/null
    for item in "$workdir"/home/*/.local/share/applications/*; do
        [ -f "$item" ] || continue
        target="$HOME_DIR/.local/share/applications/$(basename "$item")"
        mkdir -p "$(dirname "$target")"
        if [ -e "$target" ] || [ -L "$target" ]; then
            exe mv "$target" "$target.bak-$ts"
            prune_config_backups "$(dirname "$target")" "$(basename "$target").bak-*"
        fi
        exe cp "$item" "$target"
        exe chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$target"
    done 2>/dev/null
    # home dotfiles
    for item in "$workdir"/home/*/.*; do
        name=$(basename "$item")
        [[ "$name" = "." || "$name" = ".." ]] && continue
        target="$HOME_DIR/$name"
        [ -f "$item" ] || continue
        if [ -e "$target" ] || [ -L "$target" ]; then
            exe mv "$target" "$target.bak-$ts"
            prune_config_backups "$(dirname "$target")" "$(basename "$target").bak-*"
        fi
        exe cp "$item" "$target"
        exe chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$target"
    done
    shopt -u nullglob dotglob

    success "Config restored from snapshot $snapshot. Previous config backed up as .bak-$ts"
}

# --- 4.12 restore-system: re-enable system components that were disabled during restore ---
do_restore_system() {
    init_logger
    check_root
    detect_distro
    detect_target_user

    section "$(_t "Restore System" "Restore System")" "$(_t "Re-enable disabled DE components" "Re-enable disabled DE components")"
    local mf="$BASE_DIR/.system_disabled"
    if [ ! -f "$mf" ] || [ ! -s "$mf" ]; then
        log "$(_t "No disabled system components found (manifest missing or empty)." "No disabled system components found (manifest missing or empty).")"
        return 0
    fi

    local count=0 line type name _rc
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IFS='|' read -r type name <<< "$line"
        case "$type" in
            autostart)
                local _af="$HOME_DIR/.config/autostart/$name"
                if [ -f "$_af" ]; then
                    rm -f "$_af" && log "$(_t "Re-enabled autostart: " "Re-enabled autostart: ")$name"
                fi
                ;;
            userunit)
                _rc=0; as_user systemctl --user unmask "$name" 2>/dev/null || _rc=$?
                [ "$_rc" -eq 0 ] && log "$(_t "Unmasked user unit: " "Unmasked user unit: ")$name"
                ;;
            systemunit)
                _rc=0; systemctl unmask "$name" 2>/dev/null || _rc=$?
                [ "$_rc" -eq 0 ] && log "$(_t "Unmasked system unit: " "Unmasked system unit: ")$name"
                ;;
        esac
        count=$((count + 1))
    done < "$mf"
    as_user systemctl --user daemon-reload 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$mf"
    success "$(_t "$count system component(s) re-enabled; manifest cleared." "$count system component(s) re-enabled; manifest cleared.")"
}

# ==============================================================================
# 5. main
# ==============================================================================

usage() {
    cat <<EOF
eilNiri arch-install.sh v$SCRIPT_VERSION — niri desktop environment replication tool

Usage:
  ./arch-install.sh restore [--dry-run]      restore desktop on new system (root)
  ./arch-install.sh status                   show background build progress (run from another terminal)
  ./arch-install.sh rollback                 rollback config from backup (root)
  ./arch-install.sh restore-system           re-enable system components disabled by restore (root)
  ./arch-install.sh --help                   show this help

Options:
  --dry-run      print plan only, no actual install/enable/deploy

Environment:
  EILNIRI_KEEP_DM=1    keep existing display manager unchanged
  EILNIRI_KEEP_SYS=1   skip disabling other-DE components during restore
  EILNIRI_GH_PROXY     space-separated GitHub proxy URLs (default: ghfast.top gh-proxy.com ghproxy.net gh.llkk.cc)

Workflow:
  1. Copy this eilNiri directory to the target machine (USB / network)
  2. On the machine (Arch / Manjaro / EndeavourOS): sudo ./arch-install.sh restore   — no prep required;
     optionally drop your own dotfiles into configs/.config/ and they get deployed
     - niri/awww compile in background:  ./arch-install.sh status   (live progress)
     - watch logs:                       tail -f ~/.local/state/eilNiri/{niri,awww}-build.log
  3. Rollback config:            sudo ./arch-install.sh rollback
  4. Re-enable other-DE comps:   sudo ./arch-install.sh restore-system
EOF
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            restore|rollback|status|restore-system) MODE="$arg" ;;
            --dry-run)      DRY_RUN=1 ;;
            -h|--help)      usage; exit 0 ;;
            *) error "$(_t "Unknown argument: " "Unknown argument: ") $arg"; usage; exit 1 ;;
        esac
    done

    case "$MODE" in
        restore)         do_restore ;;
        status)          do_status ;;
        rollback)        do_rollback ;;
        restore-system)  do_restore_system ;;
        *)               usage; exit 1 ;;
    esac
}

main "$@"
