#!/usr/bin/env bash
# ==============================================================================
# eilNiri - install.sh
#
#   One-click niri desktop setup for a fresh Arch / RHEL / Debian family system.
#   Desktop config lives in the repo's configs/ directory (collect it from your
#   reference machine with `./install.sh collect-config`), packages come from a
#   built-in list, and the script installs everything: niri/awww/satty builds,
#   rime-ice dictionary, display manager (replacing any existing one), services
#   and config deploy.
#
#   Usage:
#     ./install.sh collect-config          collect this machine's config into configs/ (normal user)
#     ./install.sh restore [--dry-run]     restore on new system (root)
#     ./install.sh status                  show background build progress
#     ./install.sh rollback                rollback config from backup (root)
#     ./install.sh --help
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
SCRIPT_VERSION="1.9.22"

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
# Per-build state for ./install.sh status (name|pid|logfile|srcdir per line)
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

# Config capture whitelist (~/.config dirs) + home dotfiles
CONFIG_DIRS=(niri waybar mako kitty hypr copyq satty waypaper fcitx5 fcitx5 environment.d xdg-desktop-portal gtk-3.0 gtk-4.0 fontconfig systemd)
CONFIG_FILES=(.pam_environment .zshrc)

# service -> provider package mapping (filtered by is-enabled during export and written to services.txt)
SVC_ORDER=(bluetooth.service libvirtd.service power-profiles-daemon.service)
declare -A SVC_PROVIDER=(
    [bluetooth.service]=bluez
    [libvirtd.service]=libvirt
    [power-profiles-daemon.service]=power-profiles-daemon
)
# Debian-family service provider names (built-in Arch names; remapped per family on restore)
declare -A DEB_SVC_PROVIDER=(
    [bluetooth.service]=bluez
    [libvirtd.service]=libvirt-daemon-system
    [power-profiles-daemon.service]=power-profiles-daemon
)

# --- Arch -> RHEL family translation layer ---
# Rename mapping
declare -A RHEL_MAP=(
    [ttf-jetbrains-mono-nerd]=jetbrains-mono-nerd-fonts
    [wqy-zenhei]=wqy-zenhei-fonts
    [pipewire-pulse]=pipewire-pulseaudio
)
# Packages with no official RPM -> go to the "manual install" report (value = reason/advice)
# (awww/satty handled by install_awww / install_satty, rime-ice by install_rime_ice)
declare -A RHEL_MANUAL=(
)
# RHEL family: extra hint when dnf install fails (available in Fedora official repo, but not on Rocky/Alma/CentOS Stream)
# (xwayland-satellite falls back to cargo install automatically)
declare -A RHEL_FAIL_HINT=(
    [hyprlock]="Available in the Fedora official repo (dnf install hyprlock); on Rocky/Alma/CentOS try EPEL / Copr, or install the RPM from the Fedora repo manually"
    [hypridle]="Available in the Fedora official repo (dnf install hypridle); on Rocky/Alma/CentOS try EPEL / Copr, or install the RPM from the Fedora repo manually"
)
# --- Arch -> Debian family translation layer ---
# Rename mapping
declare -A DEB_MAP=(
    [mako]=mako-notifier
    [fcitx5-configtool]=fcitx5-config-qt
    # Ubuntu/Debian name the GTK/Qt frontends fcitx5-frontend-* (no fcitx5-gtk / fcitx5-qt binaries);
    # fcitx5-frontend-all covers gtk2/gtk3/gtk4 + qt5/qt6 frontends and exists on both Debian 13 and Ubuntu 24.04+
    [fcitx5-gtk]=fcitx5-frontend-all
    [fcitx5-qt]=fcitx5-frontend-all
    [ttf-jetbrains-mono-nerd]=fonts-jetbrains-mono
    [wqy-zenhei]=fonts-wqy-zenhei
    [libnotify]=libnotify-bin
    # polkit-gnome was renamed to policykit-1-gnome in Ubuntu 24.04+ / Debian 13+ (binary name unchanged)
    [polkit-gnome]=policykit-1-gnome
)
# Packages with no official .deb -> go to the "manual install" report (value = reason/advice)
# (awww/satty handled by install_awww / install_satty, rime-ice by install_rime_ice)
declare -A DEB_MANUAL=(
)
# Debian family: extra hint when apt install fails (not in repo but may have an alternative)
# (xwayland-satellite falls back to cargo install automatically)
declare -A DEB_FAIL_HINT=(
    [hyprlock]="Installable on Debian 13 via trixie-backports (apt-get install -t trixie-backports hyprlock); already in Ubuntu 26.04+ repos; otherwise build manually"
    [hypridle]="Installable on Debian 13 via trixie-backports (apt-get install -t trixie-backports hypridle); already in Ubuntu 26.04+ repos; otherwise build manually"
)
# Packages installable via pip as a fallback (common to Arch/RHEL/Debian)
declare -A PIP_PKGS=(
    [waypaper]=waypaper
)

# Packages to build from source when the distro repo has no package.
# key = arch-style pkg name, value = upstream git URL. Add entries here to extend
# the "apt/dnf failed -> build from source" fallback (install_debian / install_rhel).
declare -A SOURCE_PKGS=(
    [hyprlock]="https://github.com/hyprwm/hyprlock"
    [hypridle]="https://github.com/hyprwm/hypridle"
)

# hyprlock / hypridle system build dependencies (Debian/Ubuntu names).
# NOTE: upstream migrated hyprlock/hypridle from Rust to C++/CMake (repos no longer
# contain a Cargo.toml), so the list covers BOTH the old Rust build and the new CMake
# build. On distros where the hypr C++ stack (hyprwayland-scanner/hyprutils/hyprlang/
# hyprgraphics/hyprcursor) is NOT packaged (Rocky/Alma/CentOS Stream), those deps are
# absent and build_hypr_stack() compiles them from source in dependency order first.
# Missing entries are tolerated (apt_install_tolerant / dnf_install_tolerant), so a
# package absent on an older release never aborts the whole build-deps step.
HYPR_BUILD_DEPS_DEB=(build-essential cmake ninja-build pkg-config git libwayland-dev wayland-protocols hyprland-protocols
    libpango1.0-dev libgbm-dev libdrm-dev libxkbcommon-dev libxcb1-dev
    libcairo2-dev libpam0g-dev libpixman-1-dev libjpeg-dev libwebp-dev
    librsvg2-dev libmagic-dev libpng-dev libpugixml-dev
    libhyprutils-dev libhyprlang-dev libhyprgraphics-dev libhyprcursor-dev
    libsdbus-c++-dev hyprwayland-scanner)
# hyprlock / hypridle system build dependencies (RHEL family names)
HYPR_BUILD_DEPS_RHEL=(gcc gcc-c++ cmake ninja-build pkgconf-pkg-config git wayland-devel wayland-protocols-devel hyprland-protocols
    pango-devel mesa-libgbm-devel mesa-libEGL-devel mesa-libGLES-devel libdrm-devel libxkbcommon-devel libxcb-devel
    cairo-gobject-devel cairo-devel libpam-devel pixman-devel libjpeg-turbo-devel libwebp-devel
    librsvg2-devel file-devel libpng-devel pugixml-devel
    hyprutils-devel hyprlang-devel hyprgraphics-devel hyprcursor-devel
    sdbus-c++-devel hyprwayland-scanner)

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
    "systemunit|gdm-launch-environment.service|GDM launch environment"
    "systemunit|gdm-x11-session.service|GDM X11 session"
    "systemunit|gdm-wayland-session.service|GDM Wayland session"
    
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

# ==============================================================================
# 3. collect-config mode — collect this machine's desktop config into configs/ (normal user).
# Works on any distro (pure file copying; no package manager involved).

collect_config() {
    init_logger
    if [ "$EUID" -eq 0 ]; then
        error "$(_t "collect-config must run as normal user (needs ~/.config), do not use sudo." "collect-config must run as normal user (needs ~/.config), do not use sudo.")"
        exit 1
    fi

    local CFG_DIR="$BASE_DIR/configs"

    # configs/ must be a DIRECTORY; a same-named regular file would break collection
    if [ -e "$CFG_DIR" ] && [ ! -d "$CFG_DIR" ]; then
        warn "$(_t "A regular file exists at " "A regular file exists at ") $CFG_DIR$(_t " — the config mirror must be a directory. Move or delete the file first, then rerun." " — the config mirror must be a directory. Move or delete the file first, then rerun.")"
        return 1
    fi

    section "$(_t "Collect Config" "Collect Config")" "v$SCRIPT_VERSION — $(_t "desktop config -> configs/" "desktop config -> configs/")"
    info_kv "$(_t "Repo Dir" "Repo Dir")" "$BASE_DIR"

    # --- 3.1 config mirror (whitelist) ---
    log "$(_t "Copying desktop config (whitelist) to configs/ ..." "Copying desktop config (whitelist) to configs/ ...")"
    rm -rf "$CFG_DIR"
    mkdir -p "$CFG_DIR/.config"

    local d f
    for d in "${CONFIG_DIRS[@]}"; do
        if [ -d "$HOME/.config/$d" ]; then
            cp -r "$HOME/.config/$d" "$CFG_DIR/.config/$d"
            log "  $(_t "[config]" "[config]") ~/.config/$d"
        else
            warn "  $(_t "[skip]" "[skip]") ~/.config/$d does not exist"
        fi
    done
    for f in "${CONFIG_FILES[@]}"; do
        if [ -f "$HOME/$f" ]; then
            cp "$HOME/$f" "$CFG_DIR/$f"
            log "  $(_t "[config]" "[config]") ~/$f"
        fi
    done

    # Remove useless cache directories
    rm -rf "$CFG_DIR/.config/mako/__pycache__" 2>/dev/null

    # --- 3.1b privacy scrub: 本脚本面向大众分发，收集的配置绝不允许携带参考机的 ---
    # 个人信息。删除 copyQ 剪贴板历史/锁/加密 key（*.dat 可能含密码、token、聊天记录），
    # 并把所有文件里的参考机主目录绝对路径替换为 $HOME 字面量（防用户名/路径泄露）。
    rm -f "$CFG_DIR"/.config/copyq/*.dat \
          "$CFG_DIR"/.config/copyq/*.lock \
          "$CFG_DIR"/.config/copyq/.copyq_s \
          "$CFG_DIR"/.config/copyq/copyq.pub 2>/dev/null
    # 输入法只保留基础功能（profile 启用 fcitx5+rime），去掉候选框皮肤等美化配置
    # 与无意义缓存（classicui.conf / cached_layouts）。
    rm -f "$CFG_DIR"/.config/fcitx5/conf/classicui.conf \
          "$CFG_DIR"/.config/fcitx5/conf/cached_layouts \
          "$CFG_DIR"/.config/fcitx5/fcitx5/conf/classicui.conf \
          "$CFG_DIR"/.config/fcitx5/fcitx5/conf/cached_layouts 2>/dev/null
    if [ -n "$HOME" ]; then
        local _prf
        while IFS= read -r _prf; do
            [ -f "$_prf" ] || continue
            sed -i "s#$HOME#\$HOME#g" "$_prf" 2>/dev/null || true
            log "  [privacy] scrubbed path in $_prf"
        done < <(grep -rlI -- "$HOME" "$CFG_DIR" 2>/dev/null | head -50)
    fi

    # --- 3.2 fix known typos in the collected copy (never touch live config) ---
    local NIRI_KDL="$CFG_DIR/.config/niri/config.kdl"
    if [ -f "$NIRI_KDL" ]; then
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
            warn "$(_t "Fixed typos in the collected copy (live config unchanged):" "Fixed typos in the collected copy (live config unchanged):")"
            for fx in "${fixed[@]}"; do echo -e "     ${H_YELLOW}· $fx${NC}"; done
            write_log "FIX" "${fixed[*]}"
        fi
    fi

    # --- 3.3 capture & fix niri-session (systemd import-environment deprecation warning) ---
    local NIRI_SESSION="$CFG_DIR/.local/bin/niri-session"
    local NIRI_DESKTOP="$CFG_DIR/.local/share/applications/niri.desktop"
    if [ -x /usr/bin/niri-session ]; then
        mkdir -p "$(dirname "$NIRI_SESSION")" "$(dirname "$NIRI_DESKTOP")"
        cp /usr/bin/niri-session "$NIRI_SESSION"
        chmod +x "$NIRI_SESSION"
        if grep -q 'systemctl --user import-environment$' "$NIRI_SESSION"; then
            sed -i 's/systemctl --user import-environment$/systemctl --user import-environment WAYLAND_DISPLAY XDG_SESSION_TYPE DISPLAY XDG_CURRENT_DESKTOP/' "$NIRI_SESSION"
            log "  [fix] niri-session: import-environment now has an explicit variable list"
        fi
        cat > "$NIRI_DESKTOP" <<'DESKTOP_EOF'
[Desktop Entry]
Name=Niri (fixed)
Comment=Scrollable-tiling Wayland compositor
Exec=niri-session
Type=Application
DesktopNames=niri
DESKTOP_EOF
        chmod +x "$NIRI_DESKTOP"
        log "  [config] fixed niri-session + desktop entry"
    fi

    section "$(_t "Collect Done" "Collect Done")" "$(_t "Config Collected" "Config Collected")"
    info_kv "$(_t "Config Mirror" "Config Mirror")" "$CFG_DIR/"

    # --- 3.4 self-check: configs/ must be non-empty before it is pushed/cloned anywhere ---
    if [ ! -d "$CFG_DIR/.config" ] || [ -z "$(find "$CFG_DIR/.config" -type f 2>/dev/null | head -n 1)" ]; then
        error "$(_t "Self-check FAILED: configs/.config is empty — nothing was collected. Fix and rerun." "Self-check FAILED: configs/.config is empty — nothing was collected. Fix and rerun.")"
        return 1
    fi
    success "$(_t "Self-check passed." "Self-check passed.")"

    # If this repo is synced via git (cloud clone), remind to commit the config —
    # git only transfers tracked files, and a missing configs/ silently breaks restore.
    if [ -d "$BASE_DIR/.git" ] || git -C "$BASE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        echo ""
        info_kv "$(_t "Git sync" "Git sync")" "$(_t "configs must be committed" "configs must be committed")" ""
        echo -e "   ${H_CYAN}git add configs && git commit -m \"configs update\" && git push${NC}"
        echo -e "   ${DIM}$(_t "(git clone only transfers tracked files — without this, restore on the target machine deploys no config)" "(git clone only transfers tracked files — without this, restore on the target machine deploys no config)")${NC}"
    else
        log "Next: copy the eilNiri directory to the new machine and run ${BOLD}sudo ./install.sh restore${NC}"
    fi
}

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
        error "$(_t "restore requires root. Use: sudo ./install.sh restore" "restore requires root. Use: sudo ./install.sh restore")"
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
        *rhel*|*fedora*|*centos*)       DISTRO_FAMILY=rhel ;;
        *debian*|*ubuntu*|*mint*|*pop*) DISTRO_FAMILY=debian ;;
        *)
            error "Unrecognized distribution (ID=$id ID_LIKE=$id_like). Only Arch / RHEL / Debian families are supported."
            exit 1
            ;;
    esac
    # Ubuntu version (numeric, e.g. 24.04 -> 2404); used for release-aware hints
    if [ "$id" = ubuntu ]; then
        local ver maj min
        ver=$(. /etc/os-release; echo "${VERSION_ID:-}")
        maj=$(printf '%s' "$ver" | cut -d. -f1)
        min=$(printf '%s' "$ver" | cut -d. -f2)
        [[ "$maj" =~ ^[0-9]+$ ]] && UBUNTU_VER_NUM=$(( maj * 100 + 10#${min:-0} ))
    fi
    # apt/debconf must never block the script on prompts
    [ "$DISTRO_FAMILY" = debian ] && export DEBIAN_FRONTEND=noninteractive
    local uver=""
    [ "$UBUNTU_VER_NUM" -gt 0 ] && uver=" UBUNTU $UBUNTU_VER_NUM"
    info_kv "$(_t "Distro" "Distro")" "$DISTRO_FAMILY" "(ID=$id$uver)"
}

pkg_installed() { # $1 = package name
    case "$DISTRO_FAMILY" in
        arch)   pacman -Qi "$1" &>/dev/null ;;
        rhel)   rpm -q "$1" &>/dev/null ;;
        debian) dpkg -s "$1" &>/dev/null ;;
    esac
}

pm_install() { # $@ = package names
    case "$DISTRO_FAMILY" in
        arch)   exe pacman -S --noconfirm --needed "$@" ;;
        rhel)   exe dnf install -y "$@" ;;
        debian) exe apt-get install -y "$@" ;;
    esac
}

# Install as many packages of a batch as possible; return non-zero only when one or more
# names are genuinely unavailable. Used for build-deps batches that must be resilient to a
# few absent names (so a single renamed -dev package no longer aborts the whole build).
BDEPS_MISSING=()
apt_install_tolerant() {
    BDEPS_MISSING=()
    [ "$DRY_RUN" -eq 1 ] && { DRY_PKGS+=("$@"); return "$DRY_RUN_RC"; }
    # apt stderr goes to LOG_DIR/apt-errors.log (never /dev/null) so a systemic
    # apt failure (broken dpkg state, unreachable repos) stays diagnosable.
    if exe apt-get install -y "$@" 2>>"$LOG_DIR/apt-errors.log"; then
        return 0   # whole batch installed
    fi
    # batch failed (at least one name missing) — retry one-by-one so the available ones still install
    local p erc
    for p in "$@"; do
        erc=0
        exe apt-get install -y "$p" 2>>"$LOG_DIR/apt-errors.log" || erc=$?
        [ "$erc" -ne 0 ] && BDEPS_MISSING+=("$p")
    done
    [ ${#BDEPS_MISSING[@]} -eq 0 ]
}

# dnf twin of apt_install_tolerant: install as many of a batch as possible.
# `dnf install -y a b c` aborts the WHOLE transaction when one name is absent
# (e.g. hyprutils-devel not in Rocky/Alma base repos), so a failed batch is retried
# one-by-one; genuinely absent names land in BDEPS_MISSING (shared array).
dnf_install_tolerant() {
    BDEPS_MISSING=()
    [ "$DRY_RUN" -eq 1 ] && { DRY_PKGS+=("$@"); return "$DRY_RUN_RC"; }
    if exe dnf install -y "$@" 2>>"$LOG_DIR/dnf-errors.log"; then
        return 0   # whole batch installed
    fi
    local p erc
    for p in "$@"; do
        erc=0
        exe dnf install -y "$p" 2>>"$LOG_DIR/dnf-errors.log" || erc=$?
        [ "$erc" -ne 0 ] && BDEPS_MISSING+=("$p")
    done
    [ ${#BDEPS_MISSING[@]} -eq 0 ]
}

as_user() {
    runuser -u "$TARGET_USER" -- "$@"
}

# Resume support (dry-run does not read/write the progress file).
# The progress file carries a script-version marker; progress files written by older
# script versions are ignored (stages are re-run instead of being silently skipped).
PROGRESS_VERSION="v37"
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
    pm_install fzf || { error "$(_t "fzf install failed, cannot continue." "fzf install failed, cannot continue.")"; exit 1; }
    DRY_RUN="$_saved_dry"
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

# --- Debian/Ubuntu apt mirror switch (offered when apt-get update or install fails ---
# with 404 / 无法下载 / connection errors).  Rewrites the apt host in the source
# files (both deb-format .list and deb822 .sources) to a selected mirror, backs up
# the originals, then reruns apt-get update and VERIFIES the previously-missing
# .deb is actually served by the new mirror (curl probe).
# NOTE: fzf may not be installed yet at this point (ensure_fzf runs after
# preflight, and apt being broken can block its install), so this falls back to a
# plain numbered prompt when fzf is absent.
_url_http_code() { # $1 = URL; echoes HTTP status code (000 on network failure)
    curl -sI -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo "000"
}

# 检测系统时钟偏差：与官方源服务器 Last-Modified 对比，偏差 >= 3 天时警告。
# apt 报 "Release 文件已经过期 / expired / Valid-Until" 的常见原因不是镜像滞后，
# 而是本地时钟偏快（VM 常见，无 NTP）——此时换任何镜像都没用，必须先校准时间。
check_clock_drift() {
    local _cname _lastmod _mod_epoch _local_epoch _drift
    _cname=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
    [ -z "$_cname" ] && _cname="stable"
    _lastmod=$(curl -sI --max-time 8 "http://security.ubuntu.com/ubuntu/dists/$_cname-security/InRelease" 2>/dev/null \
        | awk -F': ' 'tolower($1)=="last-modified"{print $2; exit}' | tr -d '\r')
    if [ -n "$_lastmod" ] && _mod_epoch=$(date -d "$_lastmod" +%s 2>/dev/null) && [ -n "$_mod_epoch" ]; then
        _local_epoch=$(date +%s)
        _drift=$(( (_local_epoch - _mod_epoch) / 86400 ))
        [ "$_drift" -lt 0 ] && _drift=$(( -_drift ))
        if [ "$_drift" -ge 3 ]; then
            warn "$(_t "SYSTEM CLOCK seems off by about $_drift days (local: " "SYSTEM CLOCK seems off by about $_drift days (local: ") $(date '+%F %T %z')$(_t ", server Last-Modified: " ", server Last-Modified: ") $_lastmod$(_t ") — this makes ALL apt sources report 'Release file expired'. Calibrate first: sudo timedatectl set-ntp true (or: sudo ntpdate -u time.nist.gov), then rerun." ") — this makes ALL apt sources report 'Release file expired'. Calibrate first: sudo timedatectl set-ntp true (or: sudo ntpdate -u time.nist.gov), then rerun.")"
        fi
    fi
}

# 从 apt 错误日志里提取第一个 404 的 .deb 下载 URL（用于换源后验证新镜像是否已同步）
_apt_404_url() {
    grep -aoE 'https?://[^ ]+\.deb' "$LOG_DIR/apt-errors.log" 2>/dev/null | head -n 1
}

set_debian_mirror() { # $1 = 可选：直接指定镜像 (tuna|aliyun|ustc)，缺省时弹 fzf/编号菜单
    local _force="${1:-}"
    local _src_files=()
    # Debian/Ubuntu 的源文件分散在 /etc/apt/sources.list 和 /etc/apt/sources.list.d/
    while IFS= read -r -d '' _f; do
        grep -qiE 'archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|cn\.archive|deb\.debian\.org|security\.debian\.org' "$_f" 2>/dev/null \
            && _src_files+=("$_f")
    done < <(find /etc/apt -maxdepth 2 -type f \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null)
    [ ${#_src_files[@]} -eq 0 ] && { warn "$(_t "No Ubuntu/Debian apt source files found to rewrite." "No Ubuntu/Debian apt source files found to rewrite.")"; return 1; }

    local choice="${1:-}"
    if [ -z "$choice" ]; then
        # fzf 可用时用菜单；否则退化为编号选择
        if command -v fzf >/dev/null 2>&1; then
            choice=$(printf "%s\n" \
                "tuna\t清华大学镜像 (mirrors.tuna.tsinghua.edu.cn)" \
                "aliyun\t阿里云镜像 (mirrors.aliyun.com)" \
                "ustc\t中科大镜像 (mirrors.ustc.edu.cn)" \
                "skip\t不更换，继续" \
                | fzf_single " Debian/Ubuntu 软件源异常（更新失败或 404），选择是否更换镜像源 ") || choice="skip"
            choice=${choice%%$'\t'*}
        else
            section "$(_t "Mirror Switch" "Mirror Switch")" "$(_t "use plain prompt (fzf not available)" "use plain prompt (fzf not available)")"
            echo -e "   ${H_CYAN}[1]${NC} 清华大学镜像 (tuna)   ${H_CYAN}[2]${NC} 阿里云 (aliyun)   ${H_CYAN}[3]${NC} 中科大 (ustc)   ${H_CYAN}[4]${NC} 不更换继续"
            local _ans; read -r -t 30 _ans || _ans="4"
            case "$_ans" in
                1) choice="tuna" ;;
                2) choice="aliyun" ;;
                3) choice="ustc" ;;
                *) choice="skip" ;;
            esac
        fi
    fi

    [ "$choice" = "skip" ] && { log "$(_t "Keeping current apt sources." "Keeping current apt sources.")"; return 0; }

    local _ts _mirror=""
    case "$choice" in
        tuna|*tuna*) _mirror="mirrors.tuna.tsinghua.edu.cn" ;;
        aliyun|*aliyun*) _mirror="mirrors.aliyun.com" ;;
        ustc|*ustc*)     _mirror="mirrors.ustc.edu.cn" ;;
        *) log "$(_t "Unknown choice, skipping." "Unknown choice, skipping.")"; return 0 ;;
    esac

    section "$(_t "Mirror Switch" "Mirror Switch")" "$_mirror"
    _ts=$(date +%Y%m%d-%H%M%S)
    local _f _bak
    for _f in "${_src_files[@]}"; do
        _bak="$_f.mirror-bak-$_ts"
        exe cp -a "$_f" "$_bak" || true
        # Ubuntu: archive/security/ports/cn.archive -> mirror (保留路径结构 ubuntu/...)
        exe sed -i -E "s#(https?://)(archives?\.|security\.|ports\.|cn\.)?archive\.ubuntu\.com#\1$_mirror#g; s#(https?://)security\.ubuntu\.com#\1$_mirror#g; s#(https?://)ports\.ubuntu\.com#\1$_mirror#g; s#(https?://)cn\.archive\.ubuntu\.com#\1$_mirror#g; s#(https?://)deb\.debian\.org#\1$_mirror#g; s#(https?://)security\.debian\.org#\1$_mirror#g" "$_f" || true
        log "$(_t "Rewrote " "Rewrote ") $_f -> $_mirror (backup: $_bak)"
    done
    log "$(_t "Reloading package index from new mirror..." "Reloading package index from new mirror...")"
    exe apt-get update 2>>"$LOG_DIR/apt-errors.log" || true

    # 验证新镜像确实同步了之前 404 的 .deb：把 apt 错误里的第一个 .deb URL 换到新
    # 镜像域名再探测。只有显式 404 才判为"镜像也未同步"（网络不通/无法验证不阻塞）。
    local _probe _code
    _probe=$(_apt_404_url)
    if [ -n "$_probe" ]; then
        _probe=$(printf '%s' "$_probe" | sed -E "s#https?://[^/]+#http://$_mirror#")
        _code=$(_url_http_code "$_probe")
        if [ "$_code" = "404" ]; then
            warn "$(_t "New mirror " "New mirror ") $_mirror$(_t " also returns 404 for the missing .deb (同步滞后？) — trying next mirror." " also returns 404 for the missing .deb (sync lag?) — trying next mirror.")"
            return 1
        fi
        log "$(_t "New mirror verified: " "New mirror verified: ") $_probe -> HTTP $_code"
    fi
    return 0
}

# --- 4.1 Pre-flight ---
stage_preflight() {
    section "$(_t "Pre-Flight" "Pre-Flight")" "$(_t "System Update" "System Update")"
    if stage_done preflight; then
        log "$(_t "Pre-flight done, skipping (delete .replicate_progress to force rerun)." "Pre-flight done, skipping (delete .replicate_progress to force rerun).")"
        return
    fi
    case "$DISTRO_FAMILY" in
        arch)
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
            ;;
        rhel)
            if [ "$DRY_RUN" -eq 1 ]; then
                log "$(_t "[DRY-RUN] Skipping system upgrade." "[DRY-RUN] Skipping system upgrade.")"
            elif ! exe dnf -y upgrade --refresh; then
                warn "$(_t "System update partially failed, continuing." "System update partially failed, continuing.")"
            fi
            ;;
        debian)
            # Refresh package index first (a fresh system may have no cache); also ensure curl/tar are available (niri download dependency)
            if [ "$DRY_RUN" -eq 1 ]; then
                log "$(_t "[DRY-RUN] Skipping apt update/upgrade." "[DRY-RUN] Skipping apt update/upgrade.")"
                DRY_PKGS+=("curl tar")
            else
                # Ubuntu release too old: most of the niri suite is not packaged before 24.04
                if [ "$UBUNTU_VER_NUM" -gt 0 ] && [ "$UBUNTU_VER_NUM" -lt 2404 ]; then
                    warn "$(_t "Ubuntu $UBUNTU_VER_NUM detected: most niri-suite packages require Ubuntu 24.04+ (universe) or Debian 13+. Continue at your own risk." "Ubuntu $UBUNTU_VER_NUM detected: most niri-suite packages require Ubuntu 24.04+ (universe) or Debian 13+. Continue at your own risk.")"
                fi
                # Fresh log for apt errors this run (apt_install_tolerant and the
                # critical-deps retry append here instead of swallowing stderr).
                : > "$LOG_DIR/apt-errors.log" 2>/dev/null || true
                # Repair a broken dpkg state left by an interrupted previous run:
                # without this, EVERY later apt-get install fails and unrelated
                # packages all report "unavailable" (classic symptom: build deps
                # AND service provider packages failing at the same time).
                local _dpkg_audit
                _dpkg_audit=$(dpkg --audit 2>/dev/null)
                if [ -n "$_dpkg_audit" ]; then
                    log "$(_t "dpkg reports half-installed packages; running dpkg --configure -a ..." "dpkg reports half-installed packages; running dpkg --configure -a ...")"
                    exe dpkg --configure -a 2>>"$LOG_DIR/apt-errors.log" || warn "$(_t "dpkg repair failed; see " "dpkg repair failed; see ") $LOG_DIR/apt-errors.log"
                fi
                if ! exe apt-get update; then
                    warn "$(_t "apt-get update FAILED — package installs will fail too. Check network / apt sources (mirror), run 'sudo apt-get update' manually, then rerun." "apt-get update FAILED — package installs will fail too. Check network / apt sources (mirror), run 'sudo apt-get update' manually, then rerun.")"
                    # 若报 "Release 文件已经过期/expired"，先查系统时钟（常见根因，换镜像无效）
                    check_clock_drift
                    # 网络受限于当前源时，提供一键换源（fzf 选择；fzf 未装则退化编号提示）
                    if confirm "$(_t "Switch the Debian/Ubuntu apt mirror to a CN mirror? [Y/n] (default Y):" "Switch the Debian/Ubuntu apt mirror to a CN mirror? [Y/n] (default Y):")" "Y" 15 2>/dev/null; then
                        set_debian_mirror
                    fi
                fi
                # Ubuntu: the niri-suite packages (fuzzel, mako-notifier, waybar, fcitx5-rime, hyprlock, ...) live in
                # universe, which is NOT enabled by default on Ubuntu Server/minimal/cloud images. Enable it automatically
                # (硬校验：启用后必须能看到 universe 包，否则警告并给出手动命令）。
                # 注意：openkylin/deepin 等 Ubuntu 衍生版 ID 不是 ubuntu，但同样需要 universe。
                if _is_ubuntu_like; then
                    if _ensure_ubuntu_universe; then
                        log "$(_t "universe component OK." "universe component OK.")"
                    else
                        warn "$(_t "universe 仍未启用/不可见 — 部分构建依赖（universe 组件，如 libxcb-render-util0-dev）将无法安装。手动执行: sudo add-apt-repository universe && sudo apt-get update" "universe 仍未启用/不可见 — 部分构建依赖（universe 组件，如 libxcb-render-util0-dev）将无法安装。手动执行: sudo add-apt-repository universe && sudo apt-get update")"
                    fi
                fi
                if ! exe apt-get -y upgrade; then
                    warn "$(_t "System update partially failed, continuing." "System update partially failed, continuing.")"
                fi
                pm_install curl tar unzip
                # Generate the zh_CN / en_US locales: envvars.conf sets LANG=zh_CN.UTF-8 and
                # a missing locale triggers noisy "cannot set locale" warnings on every command.
                if ! command -v locale-gen >/dev/null 2>&1; then
                    exe apt-get install -y locales 2>/dev/null || true
                fi
                if command -v locale-gen >/dev/null 2>&1; then
                    local _lg
                    for _lg in "zh_CN.UTF-8 UTF-8" "en_US.UTF-8 UTF-8"; do
                        local _loc="${_lg%% *}"
                        grep -q "^#*${_lg}$" /etc/locale.gen 2>/dev/null \
                            && sed -i "s/^#*${_lg}$/${_lg}/" /etc/locale.gen \
                            || echo "$_lg" >> /etc/locale.gen
                    done
                    exe locale-gen 2>/dev/null || warn "$(_t "locale-gen failed, locale warnings may appear." "locale-gen failed, locale warnings may appear.")"
                fi
            fi
            ;;
    esac
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

install_rhel() {
    local p name erc
    local all=(${REPO_SEL[@]+"${REPO_SEL[@]}"})

    # pip fallback pre-check
    local has_pip_target=0
    for p in "${all[@]}"; do
        if [ -n "${PIP_PKGS[$p]:-}" ]; then has_pip_target=1; break; fi
    done
    if [ "$has_pip_target" -eq 1 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            DRY_PKGS+=("python3-pip")
        else
            pm_install python3-pip
        fi
        if [ "$DRY_RUN" -eq 0 ] && ! command -v pip3 &>/dev/null; then
            MANUAL_ITEMS+=("python3-pip — pip3 not installed, run: sudo dnf install python3-pip")
        fi
    fi

    for p in ${all[@]+"${all[@]}"}; do
        # awww/satty: no RPM in any RHEL-family repo (prebuilt binary / cargo build)
        if [ "$p" = "awww" ]; then
            install_awww
            continue
        fi
        if [ "$p" = "satty" ]; then
            install_satty
            continue
        fi
        # rime-ice: no RPM; deploy the dictionary from GitHub (fcitx5-rime package provides the engine)
        if [ "$p" = "rime-ice-pinyin-git" ]; then
            install_rime_ice
            continue
        fi
        if [ -n "${RHEL_MANUAL[$p]:-}" ]; then
            MANUAL_ITEMS+=("$p — ${RHEL_MANUAL[$p]}")
            continue
        fi
        if [ -n "${PIP_PKGS[$p]:-}" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                DRY_PKGS+=("$p (pip)")
                continue
            fi
            if ! command -v pip3 &>/dev/null; then
                MANUAL_ITEMS+=("$p — pip3 not installed, run: sudo dnf install python3-pip")
                continue
            fi
            erc=0
            exe as_user pip3 install --user "${PIP_PKGS[$p]}" || erc=$?
            if [ "$erc" -eq 0 ]; then
                INSTALLED_PKGS+=("$p (pip)")
            else
                MANUAL_ITEMS+=("$p — pip install failed, do it manually: pip3 install --user ${PIP_PKGS[$p]}")
            fi
            continue
        fi
        name="${RHEL_MAP[$p]:-$p}"
        if pkg_installed "$name"; then
            SKIPPED_PKGS+=("$name (already installed)")
            continue
        fi
        erc=0
        pm_install "$name" || erc=$?
        if [ "$erc" -eq 0 ]; then
            INSTALLED_PKGS+=("$name")
        elif [ "$erc" -eq "$DRY_RUN_RC" ]; then
            DRY_PKGS+=("$name")
        else
            if [ "$p" = "niri" ]; then
                # non-Fedora RHEL (Rocky/Alma/CentOS Stream): dnf has no niri package.
                # Try the author's COPR (yalter/niri, built for epel-10) first so we get
                # a packaged binary; only fall back to a 10-20 min source build when that
                # is not possible (EL9 / no copr plugin / enable fails).
                local _nrc=0
                install_niri_copr || _nrc=$?
                if [ "$_nrc" -eq 0 ]; then
                    INSTALLED_PKGS+=("niri")
                elif [ "$_nrc" -ne "$DRY_RUN_RC" ]; then
                    warn "$(_t "No niri package in dnf and COPR unavailable — falling back to source build..." "No niri package in dnf and COPR unavailable — falling back to source build...")"
                    install_niri_binary
                fi
            elif [ "$p" = "xwayland-satellite" ]; then
                warn "$(_t "No xwayland-satellite package in dnf, falling back to cargo install..." "No xwayland-satellite package in dnf, falling back to cargo install...")"
                install_xwayland_satellite
            elif [ -n "${SOURCE_PKGS[$p]:-}" ]; then
                warn "$(_t "No dnf package for " "No dnf package for ") $p, building from source..."
                install_hypr_source "$p" "${SOURCE_PKGS[$p]}"
            elif [ "$p" = "ttf-jetbrains-mono-nerd" ]; then
                # Nerd Font: jetbrains-mono-nerd-fonts is only in the Fedora repo.
                # On Rocky/Alma/CentOS dnf has no such package — install_nerd_font,
                # called right after install_rhel, covers it via the official release
                # download. Don't record a hard failure here; the download warns if it
                # also fails (font is optional).
                log "$(_t "jetbrains-mono-nerd-fonts not in dnf — will fetch the official Nerd Font release instead." "jetbrains-mono-nerd-fonts not in dnf — will fetch the official Nerd Font release instead.")"
            elif [ -n "${RHEL_FAIL_HINT[$p]:-}" ]; then
                MANUAL_ITEMS+=("$name — not available in repo. ${RHEL_FAIL_HINT[$p]}")
            else
                FAILED_PKGS+=("dnf:$name")
            fi
        fi
    done
}

# Install niri from the author's COPR on EL10 (Rocky/Alma/CentOS Stream 10).
# yalter/niri only builds the epel-10 chroot (plus Fedora), so this path is taken
# only when the running RHEL-family system is EL10 and `dnf copr` is usable.
# Returns 0 on success, 1 on failure, DRY_RUN_RC in dry-run (caller handles it).
install_niri_copr() {
    [ "$DRY_RUN" -eq 1 ] && { DRY_PKGS+=("niri (COPR)"); return "$DRY_RUN_RC"; }
    # EL10 only — the COPR has no EL9 build (avoids a doomed enable+install on EL9).
    local _maj
    _maj=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}" | cut -d. -f1)
    if [ "$_maj" != "10" ]; then
        log "$(_t "yalter/niri COPR builds only for EL10 (this is EL$_maj) — skipping COPR path." "yalter/niri COPR builds only for EL10 (this is EL$_maj) — skipping COPR path.")"
        return 1
    fi
    # `dnf copr` lives in dnf-plugins-core (dnf5 also ships it); install if missing.
    if ! dnf copr --help >/dev/null 2>&1; then
        pm_install dnf-plugins-core 2>/dev/null || true
    fi
    if ! dnf copr --help >/dev/null 2>&1; then
        log "$(_t "dnf copr not available — skipping COPR path." "dnf copr not available — skipping COPR path.")"
        return 1
    fi
    # COPR-built niri on epel-10 may depend on EPEL packages; enable it first (best effort).
    if ! rpm -q epel-release >/dev/null 2>&1 && [ ! -f /etc/yum.repos.d/epel.repo ]; then
        pm_install epel-release 2>/dev/null || true
    fi
    if ! exe dnf -y copr enable yalter/niri; then
        log "$(_t "COPR enable failed — skipping COPR path." "COPR enable failed — skipping COPR path.")"
        return 1
    fi
    local _erc=0
    exe dnf install -y niri || _erc=$?
    return "$_erc"
}

# --- GitHub download (official direct; resume + retries + timeouts) ---
CURL_DL_FLAGS=(-fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 1800 -C -)

# Reliable GitHub-release mirror proxies for CN, ordered by measured availability
# (206 range-supported). mirror.ghproxy.com and github.moeyy.xyz were found
# unreachable and are omitted. Override the whole list via EILNIRI_GH_PROXY.
GH_MIRRORS="https://ghfast.top/ https://gh-proxy.com/ https://ghproxy.net/ https://gh.llkk.cc/"

# Bounded best-effort GitHub-release download for large release assets (e.g. the
# ~50MB Nerd Font zip). Tries direct then each mirror, hard-capped at $3 seconds
# per attempt so a slow/stalled origin can never hang the whole install. Returns
# 0 only when a full, non-empty file was written (curl -o truncates, so a partial
# direct download never leaks into a later mirror attempt).
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
apply_cargo_mirror() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    local tz
    tz=$(readlink -f /etc/localtime 2>/dev/null || echo "")
    local cn=0
    [[ "$tz" =~ Shanghai|Beijing|Asia/Chongqing|Asia/Urumqi|Asia/Hong_Kong ]] && cn=1
    if [ "$cn" -eq 0 ]; then
        if curl -fsS --max-time 8 -o /dev/null https://index.crates.io/config.json 2>/dev/null; then
            CRATES_IO_OK=1   # crates.io reachable, no mirror needed
            return 0
        fi
        log "$(_t "crates.io unreachable, enabling rsproxy mirror as fallback" "crates.io unreachable, enabling rsproxy mirror as fallback")"
    fi
    mkdir -p "$HOME/.cargo"
    cat > "$HOME/.cargo/config.toml" <<'EOF'
[source.crates-io]
replace-with = "rsproxy-sparse"

[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"

[registries.rsproxy]
index = "sparse+https://rsproxy.cn/index/"

[net]
git-fetch-with-cli = true
EOF
    if curl -fsS --max-time 8 -o /dev/null https://rsproxy.cn/index/config.json 2>/dev/null; then
        CRATES_IO_OK=1   # rsproxy mirror works, network build viable
    else
        CRATES_IO_OK=0   # no registry reachable -> niri must build offline from vendored deps
        log "$(_t "rsproxy also unreachable — niri will use the vendored-dependencies archive" "rsproxy also unreachable — niri will use the vendored-dependencies archive")"
    fi
    export RUSTUP_DIST_SERVER="https://rsproxy.cn" RUSTUP_UPDATE_ROOT="https://rsproxy.cn/rustup"
    log "$(_t "CN timezone detected: cargo/rustup mirror enabled (rsproxy.cn)" "CN timezone detected: cargo/rustup mirror enabled (rsproxy.cn)")"
}

# --- niri install (common to Debian family and non-Fedora RHEL family; these repos have no niri) ---
# Strategy: 1) official prebuilt binary (if this release provides it) 2) offline cargo build from the official vendored source archive 3) manual report
# Fedora's official repo already has niri, so dnf succeeds and this is never reached
NIRI_GH="https://github.com/niri-wm/niri/releases"

# niri system build dependencies (Debian/Ubuntu names, per the official niri Packaging docs)
NIRI_BUILD_DEPS=(build-essential cmake pkg-config curl tar clang libclang-dev \
    libxkbcommon-dev libxkbcommon-x11-dev libwayland-dev wayland-protocols \
    libinput-dev libdisplay-info-dev libudev-dev libseat-dev \
    libgbm-dev libegl1-mesa-dev libgles2-mesa-dev \
    libpango1.0-dev \
    libpipewire-0.3-dev libdbus-1-dev \
    libxcb-composite0-dev libxcb-ewmh-dev libxcb-icccm4-dev libxcb-randr0-dev \
    libxcb-xfixes0-dev libxcb-present-dev libxcb-render-util0-dev libxcb-res0-dev \
    libxcb-shape0-dev libxcb-util-dev libxcb-xkb-dev libxcb-xinerama0-dev)
# Debian/Ubuntu version-specific package name mappings for niri build deps
# (different Debian/Ubuntu versions use different package names for the same library)
#
# NOTE: mappings are only a *first try* — install_niri_binary re-verifies each
# mapped name with apt-cache and falls back to the original name when the mapped
# one does not exist.  Do NOT hardcode guessed names here (the old
# libdisplay-info-dev -> libdisplay-info0-dev entry was wrong on Debian 12:
# display-info 0.1.x ships libdisplay-info-dev / libdisplay-info1, so the mapped
# package never existed and the build died with "libdisplay-info.pc not found"
# after 10-20 min of compiling).
declare -A DEB_NIRI_BDEPS_MAP=(
    [libhyprutils-dev]=""                         # optional, only in newer versions
    [libhyprlang-dev]=""                          # optional, only in newer versions
)
# niri system build dependencies (RHEL/Fedora names; some need EPEL/CRB — fall back to the manual report when missing)
NIRI_BUILD_DEPS_RHEL=(gcc gcc-c++ pkgconf-pkg-config curl tar clang libclang-devel \
    libxkbcommon-devel libxkbcommon-x11-devel libwayland-devel wayland-protocols-devel \
    libinput-devel display-info-devel systemd-devel libseat-devel \
    mesa-libgbm-devel mesa-libEGL-devel mesa-libGLES-devel \
    pipewire-devel dbus-devel \
    libxcb-devel xcb-util-devel xcb-util-wm-devel xcb-util-image-devel xcb-util-renderutil-devel xcb-util-keysyms-devel)

# Ensure a usable Rust toolchain (use rustup for the latest stable when the distro version is too old)
ensure_rust() {
    # Re-apply rsproxy mirror env for CN timezones so the rustup toolchain download is not blocked.
    # apply_cargo_mirror may already have set these, but ensure_rust can be called directly too.
    local _tz
    _tz=$(readlink -f /etc/localtime 2>/dev/null || echo "")
    if [[ "$_tz" =~ Shanghai|Beijing|Asia/Chongqing|Asia/Urumqi|Asia/Hong_Kong ]]; then
        export RUSTUP_DIST_SERVER="https://rsproxy.cn" RUSTUP_UPDATE_ROOT="https://rsproxy.cn/rustup"
    fi
    if ! command -v rustup &>/dev/null; then
        log "$(_t "Installing Rust toolchain (rustup)..." "Installing Rust toolchain (rustup)...")"
        exe bash -c 'curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable' || return 1
    fi
    export PATH="$HOME/.cargo/bin:$PATH"
    exe rustup default stable 2>/dev/null || true
    if ! command -v cargo >/dev/null 2>&1; then
        error "$(_t "cargo not available after rustup setup — check network to static.rust-lang.org" "cargo not available after rustup setup — check network to static.rust-lang.org")"
        return 1
    fi
    # Hard guard: never build niri with a distro cargo.  Debian 12 / Ubuntu 22.04
    # ship rustc 1.63/1.75 via apt; if the rustup shim or its default toolchain is
    # missing, `cargo` silently resolves to /usr/bin/cargo and the build dies with
    # obscure "edition 2024" errors.  Verify a recent version and retry the update
    # once before failing loudly.
    local _cver
    _cver=$(cargo --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [ -n "$_cver" ] && awk -v v="$_cver" 'BEGIN{exit !(v < 1.85)}'; then
        warn "$(_t "cargo $_cver too old for niri (needs >= 1.85); retrying rustup toolchain update..." "cargo $_cver too old for niri (needs >= 1.85); retrying rustup toolchain update...")"
        exe rustup update stable 2>/dev/null || true
        exe rustup default stable 2>/dev/null || true
        _cver=$(cargo --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    fi
    if [ -n "$_cver" ] && awk -v v="$_cver" 'BEGIN{exit !(v < 1.85)}'; then
        error "$(_t "Rust toolchain still too old (cargo $_cver, need >= 1.85) — install rustup manually and rerun" "Rust toolchain still too old (cargo $_cver, need >= 1.85) — install rustup manually and rerun")"
        return 1
    fi
    command -v cargo >/dev/null
}

# Lightweight repair: niri binary is already installed but the session file (niri.desktop)
# is missing. Downloads the source tarball (~1MB) and extracts only the desktop file.
# This is much faster than re-submitting a full cargo build (10-20 min).
_repair_niri_session() {
    [ "$DRY_RUN" -eq 1 ] && { DRY_PKGS+=("niri (session file repair)"); return "$DRY_RUN_RC"; }
    local ver
    ver=$(curl -fsSI --retry 2 https://github.com/niri-wm/niri/releases/latest 2>/dev/null \
        | grep -i '^location:' | sed -n 's#.*/tag/\(v[^/]*\).*#\1#p' | head -n 1 | sed 's/^v//' | tr -d '\r')
    if [ -z "$ver" ]; then
        ver=$(curl -fsSL https://api.github.com/repos/niri-wm/niri/releases/latest 2>/dev/null \
            | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/' | tr -d '\r')
    fi
    if [ -z "$ver" ]; then
        MANUAL_ITEMS+=("niri — session file repair: could not fetch latest version; create /usr/share/wayland-sessions/niri.desktop manually")
        return 1
    fi
    local tmp work url desktop_file
    tmp=$(mktemp)
    work=$(mktemp -d)
    register_temp_path "$tmp"
    register_temp_path "$work"
    url="https://github.com/niri-wm/niri/archive/refs/tags/v${ver}.tar.gz"
    if ! download_gh "$url" "$tmp"; then
        MANUAL_ITEMS+=("niri — session file repair: source tarball download failed; create /usr/share/wayland-sessions/niri.desktop manually")
        return 1
    fi
    if tar xzf "$tmp" -C "$work" 2>/dev/null; then
        desktop_file=$(find "$work" -name niri.desktop -type f 2>/dev/null | head -1)
        if [ -n "$desktop_file" ] && [ -s "$desktop_file" ]; then
            mkdir -p /usr/local/share/wayland-sessions /usr/share/wayland-sessions
            exe install -Dm644 "$desktop_file" /usr/local/share/wayland-sessions/niri.desktop
            exe install -Dm644 "$desktop_file" /usr/share/wayland-sessions/niri.desktop
            # 顺手补上 systemd user units（GDM 登录循环的根因：缺 niri.service）
            mkdir -p /usr/lib/systemd/user
            local _unit
            for _unit in "$work"/*/resources/*.service "$work"/*/resources/*.target; do
                [ -f "$_unit" ] || continue
                exe install -Dm644 "$_unit" "/usr/lib/systemd/user/$(basename "$_unit")" 2>/dev/null || true
            done
            INSTALLED_PKGS+=("niri (session file repaired from source v$ver)")
            success "$(_t "niri session file repaired" "niri session file repaired")"
            return 0
        fi
    fi
    MANUAL_ITEMS+=("niri — session file repair: extraction failed; create /usr/share/wayland-sessions/niri.desktop manually")
    return 1
}

# --- 通用 .pc 预检 + Debian 自愈（niri / awww / xwayland-satellite 共用）---
# 缺失的 .pc 在 Debian 系会自动安装对应的 -dev 包（新旧命名都试，apt-cache 探测
# 哪个存在装哪个），装完重新校验；仍缺则把清单放进 PC_STILL_MISSING。
PC_STILL_MISSING=()
PC_AUTO_INSTALLED=0
PC_NO_CANDIDATE=0   # _pc_auto_install 未找到任何 apt 候选包时置 1
PC_FAIL_HINT=""   # ensure_pc_deps 失败时的原因说明（apt 报错尾部 / 候选包不在列表等）
# 已知的 .pc 命名分歧补丁：Ubuntu 26.04 的 libxcb-render-util0-dev 装的是上游原名
# xcb-renderutil.pc，而 Debian 系传统命名（和 niri 构建探测）用 xcb-render-util.pc。
# 双向补符号链接，让两种名字都能被 pkg-config 解析。
_pc_alias_patch() {
    local _dir
    for _dir in /usr/lib/*/pkgconfig /usr/lib/pkgconfig /usr/share/pkgconfig; do
        [ -d "$_dir" ] || continue
        [ -f "$_dir/xcb-renderutil.pc" ] && [ ! -e "$_dir/xcb-render-util.pc" ] \
            && ln -sf xcb-renderutil.pc "$_dir/xcb-render-util.pc" 2>/dev/null
        [ -f "$_dir/xcb-render-util.pc" ] && [ ! -e "$_dir/xcb-renderutil.pc" ] \
            && ln -sf xcb-render-util.pc "$_dir/xcb-renderutil.pc" 2>/dev/null
    done
}
# 确保 Ubuntu 的 universe 组件已启用（很多构建 -dev 包在 universe，如 libxcb-render-util0-dev）。
# 返回 0 = universe 可见；1 = 仍不可见。
# 是否为 Ubuntu 或 Ubuntu 衍生发行版（openkylin/deepin/UOS 等 ID_LIKE 含 ubuntu）
_is_ubuntu_like() {
    case " $DISTRO_ID $DISTRO_ID_LIKE " in
        *" ubuntu "*) return 0 ;;
        *" linuxmint "*) return 0 ;;
        *" pop "*) return 0 ;;
        *) return 1 ;;
    esac
}

_ensure_ubuntu_universe() {
    _is_ubuntu_like || return 0
    # 已能看到 universe 包就算启用（两个代表性包）
    apt-cache show libxcb-render-util0-dev >/dev/null 2>&1 && return 0
    apt-cache show mako-notifier >/dev/null 2>&1 && return 0
    if ! command -v add-apt-repository >/dev/null 2>&1; then
        pm_install software-properties-common 2>>"$LOG_DIR/apt-errors.log" || true
    fi
    if command -v add-apt-repository >/dev/null 2>&1; then
        exe add-apt-repository -y universe 2>>"$LOG_DIR/apt-errors.log" || true
    else
        # 无 add-apt-repository：直接往 deb822 .sources 的 Components 行追加 universe
        local _f
        for _f in /etc/apt/sources.list.d/*.sources; do
            [ -f "$_f" ] || continue
            grep -q '^Components:' "$_f" 2>/dev/null || continue
            grep -qE '^\s*Components:.*\buniverse\b' "$_f" 2>/dev/null || {
                exe sed -i -E 's/^(Components:.*)$/\1 universe/' "$_f" || true
            }
        done
    fi
    # 捕获 update 输出：若成功但索引里没有 universe 行，说明当前源/镜像不含 universe 组件
    local _upout _univ_lines
    _upout=$(apt-get update 2>&1)
    exe apt-get update 2>>"$LOG_DIR/apt-errors.log" || true
    _univ_lines=$(printf '%s\n' "$_upout" | grep -iE 'universe' | head -n 3)
    if [ -z "$_univ_lines" ] && ! apt-cache show mako-notifier >/dev/null 2>&1; then
        warn "$(_t "apt-get update 未获取到 universe 索引（当前源/镜像可能不含 universe 组件）— 需要换源或手动确认 sources。当前源:" "apt-get update 未获取到 universe 索引（当前源/镜像可能不含 universe 组件）— 需要换源或手动确认 sources。当前源:")"
        grep -hE '^(URIs|Components):' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null | head -n 6 || true
    fi
    apt-cache show libxcb-render-util0-dev >/dev/null 2>&1 || apt-cache show mako-notifier >/dev/null 2>&1
}
_pc_pkg_map() { # $1 = .pc 名; echo 候选 -dev 包名（空格分隔）
    case "$1" in
        libdisplay-info)  echo "libdisplay-info-dev" ;;
        xkbcommon)         echo "libxkbcommon-dev" ;;
        xkbcommon-x11)     echo "libxkbcommon-x11-dev" ;;
        wayland-client)    echo "libwayland-dev" ;;
        wayland-server)    echo "libwayland-dev" ;;
        libinput)          echo "libinput-dev" ;;
        libseat)           echo "libseat-dev" ;;
        libpipewire-0.3)   echo "libpipewire-0.3-dev" ;;
        dbus-1)            echo "libdbus-1-dev" ;;
        pango)             echo "libpango1.0-dev" ;;
        gbm)               echo "libgbm-dev" ;;
        egl)               echo "libegl1-mesa-dev" ;;
        liblz4)            echo "liblz4-dev" ;;
        lz4)               echo "liblz4-dev" ;;
        dav1d)             echo "libdav1d-dev" ;;
        xcb-cursor)        echo "libxcb-cursor-dev" ;;
        xcb-composite)     echo "libxcb-composite0-dev libxcb-composite-dev" ;;
        xcb-ewmh)          echo "libxcb-ewmh-dev" ;;
        xcb-icccm)         echo "libxcb-icccm4-dev libxcb-icccm-dev" ;;
        xcb-randr)         echo "libxcb-randr0-dev libxcb-randr-dev" ;;
        xcb-xfixes)        echo "libxcb-xfixes0-dev libxcb-xfixes-dev" ;;
        xcb-present)       echo "libxcb-present-dev" ;;
        xcb-render-util)   echo "libxcb-render-util0-dev libxcb-render-util-dev" ;;
        xcb-res)           echo "libxcb-res0-dev libxcb-res-dev" ;;
        xcb-shape)         echo "libxcb-shape0-dev" ;;
        xcb-util)          echo "libxcb-util-dev" ;;
        xcb-xkb)           echo "libxcb-xkb-dev" ;;
        xcb-xinerama)      echo "libxcb-xinerama0-dev libxcb-xinerama-dev" ;;
        *)                 echo "" ;;
    esac
}
_pc_auto_install() { # $1 = .pc 名（Debian 系专用）
    local _cand _found=0 _try
    for _try in 1 2; do
        for _cand in $(_pc_pkg_map "$1"); do
            if apt-cache policy "$_cand" 2>/dev/null | grep -q 'Candidate: [0-9]'; then
                _found=1
                log "$(_t "Auto-installing missing build dep: " "Auto-installing missing build dep: ") $_cand"
                pm_install "$_cand" 2>>"$LOG_DIR/apt-errors.log" || true
                PC_AUTO_INSTALLED=$(( PC_AUTO_INSTALLED + 1 ))
                pkg-config --exists "$1" 2>/dev/null && return 0
            fi
        done
        # 候选包一个都不在 apt 列表里 → 大概率 universe 未启用（这些 -dev 包多在
        # universe，如 libxcb-render-util0-dev）或源列表缺失；启用 universe 后重试一轮
        if [ "$_found" -eq 0 ] && [ "$_try" -eq 1 ]; then
            PC_NO_CANDIDATE=1
            warn "$(_t "No apt candidate for " "No apt candidate for ") $1$(_t " — 尝试启用 universe 并刷新索引..." " — 尝试启用 universe 并刷新索引...")"
            _ensure_ubuntu_universe || true
            _found=0
        else
            break
        fi
    done
    # 兜底：包已装但 pkg-config 仍找不到（.pc 在磁盘但不在搜索路径 / Requires 依赖缺失）——
    # 在磁盘上找到 .pc 就把所在目录加入 PKG_CONFIG_PATH（cargo 构建继承该环境变量）
    if ! pkg-config --exists "$1" 2>/dev/null; then
        local _pcerr2
        _pcerr2=$(pkg-config --print-errors "$1" 2>&1 | tail -n 1)
        local _pcf _pcdir
        _pcf=$(find /usr /lib /opt -name "$1.pc" -type f 2>/dev/null | head -n 1)
        if [ -n "$_pcf" ]; then
            _pcdir=$(dirname "$_pcf")
            case ":${PKG_CONFIG_PATH:-}:" in
                *":$_pcdir:"*) ;;
                *) export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:+$PKG_CONFIG_PATH:}$_pcdir" ;;
            esac
            log "$(_t "Found " "Found ") $1.pc$(_t " at " " at ") $_pcf$(_t " — added " " — added ") $_pcdir$(_t " to PKG_CONFIG_PATH" " to PKG_CONFIG_PATH")"
            pkg-config --exists "$1" 2>/dev/null && return 0
        else
            warn "$(_t "pkg-config error for " "pkg-config error for ") $1.pc: $_pcerr2"
        fi
    fi
    return 1
}
ensure_pc_deps() { # $@ = .pc 名列表; 返回 0=全部就绪, 1=仍缺（PC_STILL_MISSING 列出）
    PC_STILL_MISSING=()
    _pc_alias_patch   # xcb-renderutil.pc ↔ xcb-render-util.pc 命名分歧兼容
    command -v pkg-config >/dev/null 2>&1 || pm_install pkg-config 2>/dev/null || true
    command -v pkg-config >/dev/null 2>&1 || return 1
    local _attempt=0 _pc
    while [ "$_attempt" -lt 2 ]; do
        PC_STILL_MISSING=()
        # pass 1: 收集缺失 + Debian 自愈
        for _pc in "$@"; do
            if ! pkg-config --exists "$_pc" 2>/dev/null; then
                warn "$(_t "build prerequisite missing: " "build prerequisite missing: ") $_pc.pc"
                if [ "$DISTRO_FAMILY" = debian ] && [ "$DRY_RUN" -eq 0 ]; then
                    _pc_auto_install "$_pc"
                fi
            fi
        done
        # pass 2: 重新校验
        for _pc in "$@"; do
            if ! pkg-config --exists "$_pc" 2>/dev/null; then
                PC_STILL_MISSING+=("$_pc.pc")
            fi
        done
        [ ${#PC_STILL_MISSING[@]} -eq 0 ] && return 0
        # 仍缺且 (a) apt 报镜像/源故障特征，或 (b) 候选包根本不在 apt 列表（universe 缺失/
        # 源列表陈旧，apt 无报错）→ 先查时钟，再换源重试一轮（最多一次）
        if [ "$_attempt" -eq 0 ] && [ "$DISTRO_FAMILY" = debian ] && [ "$DRY_RUN" -eq 0 ] \
            && { [ "$PC_NO_CANDIDATE" -eq 1 ] \
                 || grep -qiE '404|无法下载|Failed to fetch|Unable to fetch|Unable to locate package|has no installation candidate|Release 文件已经过期|expired|Valid-Until' "$LOG_DIR/apt-errors.log" 2>/dev/null; }; then
            check_clock_drift
            if confirm "$(_t "apt cannot fetch some packages (mirror/source issue) — switch mirror and retry? [Y/n] (default Y):" "apt cannot fetch some packages (mirror/source issue) — switch mirror and retry? [Y/n] (default Y):")" "Y" 10 2>/dev/null; then
                if set_debian_mirror; then
                    _attempt=1
                    PC_NO_CANDIDATE=0
                    log "$(_t "Retrying .pc pre-check after mirror switch..." "Retrying .pc pre-check after mirror switch...")"
                    continue
                fi
            fi
        fi
        break
    done
    # 失败原因说明：有 apt 报错就带尾部；无报错说明候选包不在 apt 列表（universe 未启用等）
    local _perr
    _perr=$(tail -n 3 "$LOG_DIR/apt-errors.log" 2>/dev/null | tr '\n' ' ')
    if [ -n "$_perr" ]; then
        PC_FAIL_HINT="apt error: $_perr"
    else
        PC_FAIL_HINT="apt 无报错 — 候选 -dev 包不在 apt 列表中（大概率 universe 未启用或源列表缺失）"
    fi
    [ ${#PC_STILL_MISSING[@]} -eq 0 ]
}

# niri 已装但 systemd user units 缺失时（旧版脚本装的 niri / 手动装的）补装：
# niri-session 启动需要 systemctl --user start niri.service，缺 unit 会 GDM 登录循环。
# 下载源码 tarball，从 resources/ 提取 *.service / *.target 到 /usr/lib/systemd/user/。
_ensure_niri_units() {
    [ -x /usr/local/bin/niri ] || return 0
    [ -f /usr/lib/systemd/user/niri.service ] && [ -f /usr/lib/systemd/user/niri-shutdown.target ] && return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        DRY_PKGS+=("niri (systemd user units)")
        return "$DRY_RUN_RC"
    fi
    log "$(_t "niri installed but systemd user units missing — installing..." "niri installed but systemd user units missing — installing...")"
    local ver tmp work url _unit _ok=0
    ver=$(curl -fsSI --retry 2 https://github.com/niri-wm/niri/releases/latest 2>/dev/null \
        | grep -i '^location:' | sed -n 's#.*/tag/\(v[^/]*\).*#\1#p' | head -n 1 | sed 's/^v//' | tr -d '\r')
    if [ -z "$ver" ]; then
        ver=$(curl -fsSL https://api.github.com/repos/niri-wm/niri/releases/latest 2>/dev/null \
            | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/' | tr -d '\r')
    fi
    if [ -z "$ver" ]; then
        MANUAL_ITEMS+=("niri — 无法获取版本号来自动补装 systemd user units; 手动创建 /usr/lib/systemd/user/niri.service 与 niri-shutdown.target（见 README）")
        return 1
    fi
    tmp=$(mktemp); work=$(mktemp -d)
    register_temp_path "$tmp"; register_temp_path "$work"
    url="https://github.com/niri-wm/niri/archive/refs/tags/v${ver}.tar.gz"
    if download_gh "$url" "$tmp" && tar xzf "$tmp" -C "$work" 2>/dev/null; then
        mkdir -p /usr/lib/systemd/user
        for _unit in "$work"/*/resources/*.service "$work"/*/resources/*.target; do
            [ -f "$_unit" ] || continue
            exe install -Dm644 "$_unit" "/usr/lib/systemd/user/$(basename "$_unit")" 2>/dev/null && _ok=1
        done
    fi
    if [ "$_ok" -eq 1 ]; then
        log "$(_t "niri systemd user units installed (/usr/lib/systemd/user)" "niri systemd user units installed (/usr/lib/systemd/user)")"
        return 0
    fi
    MANUAL_ITEMS+=("niri — 未能自动补装 systemd user units; 手动创建 /usr/lib/systemd/user/niri.service 与 niri-shutdown.target")
    return 1
}

install_niri_binary() {
    if command -v niri >/dev/null 2>&1; then
        if [ -f /usr/share/wayland-sessions/niri.desktop ] || [ -f /usr/local/share/wayland-sessions/niri.desktop ]; then
            SKIPPED_PKGS+=("niri (already installed)")
            _ensure_niri_units   # 旧版脚本/手动装的 niri 可能缺 systemd units → GDM 登录循环
            return 0
        fi
        log "$(_t "niri binary found but niri.desktop missing; repairing session file..." "niri binary found but niri.desktop missing; repairing session file...")"
        _repair_niri_session
        return $?
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        DRY_PKGS+=("niri (official prebuilt or source build)")
        return "$DRY_RUN_RC"
    fi

    local arch
    case "$(uname -m)" in
        x86_64)  arch=x86_64 ;;
        aarch64) arch=aarch64 ;;
        *)
            MANUAL_ITEMS+=("niri — unsupported architecture $(uname -m), install manually: $NIRI_GH")
            return 1
            ;;
    esac

    # Resolve the latest version: prefer the /releases/latest redirect (no API), fall back to the GitHub API.
    # NOTE: GitHub HTTP headers are CRLF-terminated — the extracted tag must be stripped of \r,
    # otherwise it embeds a control character in the download URL and curl fails with exit code 3.
    local ver url tmp work srcdir
    ver=$(curl -fsSI --retry 2 https://github.com/niri-wm/niri/releases/latest 2>/dev/null \
        | grep -i '^location:' | sed -n 's#.*/tag/\(v[^/]*\).*#\1#p' | head -n 1 | sed 's/^v//' | tr -d '\r')
    if [ -z "$ver" ]; then
        ver=$(curl -fsSL https://api.github.com/repos/niri-wm/niri/releases/latest 2>/dev/null \
            | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/' | tr -d '\r')
    fi
    if [ -z "$ver" ]; then
        MANUAL_ITEMS+=("niri — could not fetch latest version (network or GitHub restricted), install manually: $NIRI_GH")
        return 1
    fi
    tmp=$(mktemp)
    work=$(mktemp -d)
    register_temp_path "$tmp"
    register_temp_path "$work"

    # --- source build ---
    # The source tarball (~1MB) is the primary download; the 40MB vendored-dependencies archive
    # contains ONLY dependency crates (no niri source!), so it is used just as an offline depot
    # when no cargo registry (crates.io / rsproxy) is reachable.
    log "$(_t "Building niri from source (10-20 min)..." "Building niri from source (10-20 min)...")"
    url="https://github.com/niri-wm/niri/archive/refs/tags/v${ver}.tar.gz"
    
    local _dl_attempts=3 _dl_delay=15 _dlrc=0
    for (( _attempt=1; _attempt<=$_dl_attempts; _attempt++ )); do
        if download_gh "$url" "$tmp"; then
            _dlrc=0
            break
        fi
        _dlrc=$?
        if [ "$_attempt" -lt "$_dl_attempts" ]; then
            log "$(_t "Download attempt $_attempt/$_dl_attempts failed (code $?), retrying in ${_dl_delay}s..." "Download attempt $_attempt/$_dl_attempts failed (code $?), retrying in ${_dl_delay}s...")"
            sleep "$_dl_delay"
        fi
    done
    
    if [ "$_dlrc" -ne 0 ]; then
        MANUAL_ITEMS+=("niri — source tarball download failed after $_dl_attempts attempts (curl exit code $_dlrc); check network and try: $NIRI_GH")
        return 1
    fi
    if ! tar xzf "$tmp" -C "$work" 2>/dev/null; then
        # 解压失败 = 下载损坏（代理/断点续传可能产生坏文件）：删掉重下一次（强制全新），再解压一次
        log "$(_t "Extraction failed (corrupt download?), re-downloading once..." "Extraction failed (corrupt download?), re-downloading once...")"
        rm -f "$tmp"
        if download_gh "$url" "$tmp" && tar xzf "$tmp" -C "$work" 2>/dev/null; then
            :   # 重试成功
        else
            local _ft2 _fs2
            _ft2=$(file -b "$tmp" 2>/dev/null || echo unknown)
            _fs2=$(stat -c%s "$tmp" 2>/dev/null || echo "?")
            MANUAL_ITEMS+=("niri — source archive extraction failed (file type: $_ft2, size: $_fs2 bytes, url: $url); 下载可能被代理损坏，手动下载后安装: $NIRI_GH")
            return 1
        fi
    fi

    # Locate the source root (top level may be the source directly or wrapped in a version dir)
    srcdir="$work"
    for d in "$work"/*/; do
        [ -f "$d/Cargo.toml" ] && { srcdir="$d"; break; }
    done
    # Hard validation: never start a cargo build without the manifest. A corrupted/mismatched
    # download (HTML error page, resumed-across-URLs garbage) extracts fine but lacks Cargo.toml.
    if [ ! -f "$srcdir/Cargo.toml" ]; then
        local ftype fsize
        ftype=$(file -b "$tmp" 2>/dev/null || echo unknown)
        fsize=$(stat -c%s "$tmp" 2>/dev/null || echo "?")
        MANUAL_ITEMS+=("niri — downloaded archive is unusable (no Cargo.toml after extraction; file type: $ftype, size: $fsize bytes, downloaded from: $url); install manually: $NIRI_GH")
        return 1
    fi

    # Probe cargo registry reachability NOW, right before deciding the build strategy.
    # Doing it after the source download ensures the network is still alive and avoids
    # a stale probe from minutes earlier.
    if [ "${CRATES_IO_OK:-0}" -eq 0 ]; then
        # apply_cargo_mirror may not have run (e.g. direct invocation); probe crates.io now
        if curl -fsS --max-time 8 -o /dev/null https://index.crates.io/config.json 2>/dev/null; then
            CRATES_IO_OK=1
        fi
    fi
    local offline=0
    [ "$CRATES_IO_OK" -eq 0 ] && offline=1

    # Offline depot: when no cargo registry is reachable, fetch the vendored-dependencies archive
    # (dependency crates only) and wire it up as the cargo source so the build needs no network.
    if [ "$offline" -eq 1 ]; then
        log "$(_t "No cargo registry reachable, downloading vendored dependencies for an offline build..." "No cargo registry reachable, downloading vendored dependencies for an offline build...")"
        local vtmp _vdl_attempts=3 _vdl_delay=15 _vdlrc=0
        vtmp=$(mktemp)
        register_temp_path "$vtmp"
        url="$NIRI_GH/download/v${ver}/niri-${ver}-vendored-dependencies.tar.xz"
        
        for (( _vattempt=1; _vattempt<=$_vdl_attempts; _vattempt++ )); do
            if download_gh "$url" "$vtmp"; then
                _vdlrc=0
                break
            fi
            _vdlrc=$?
            if [ "$_vattempt" -lt "$_vdl_attempts" ]; then
                log "$(_t "Vendored deps download attempt $_vattempt/$_vdl_attempts failed (code $_vdlrc), retrying in ${_vdl_delay}s..." "Vendored deps download attempt $_vattempt/$_vdl_attempts failed (code $_vdlrc), retrying in ${_vdl_delay}s...")"
                sleep "$_vdl_delay"
            fi
        done
        
        if [ "$_vdlrc" -ne 0 ]; then
            MANUAL_ITEMS+=("niri — vendored dependencies download failed after $_vdl_attempts attempts (curl exit code $_vdlrc); try online build or install manually: $NIRI_GH")
            return 1
        fi
        mkdir -p "$srcdir/vendor"
        if ! tar xJf "$vtmp" -C "$srcdir/vendor" 2>/dev/null || [ ! -d "$srcdir/vendor/vendor" ]; then
            MANUAL_ITEMS+=("niri — vendored dependencies extraction failed; install manually: $NIRI_GH")
            return 1
        fi
        # point cargo at the vendored crates so the build is fully offline
        mkdir -p "$srcdir/.cargo"
        # IMPORTANT: cargo resolves relative paths in config.toml against the
        # *config file's* directory, not the cwd — `directory = "vendor/vendor"`
        # here would look in $srcdir/.cargo/vendor/vendor and fail with
        # "failed to load source".  Always emit an absolute path.
        cat > "$srcdir/.cargo/config.toml" <<EOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$srcdir/vendor/vendor"
EOF
        log "$(_t "Vendored dependencies ready — building fully offline." "Vendored dependencies ready — building fully offline.")"
    fi

    # Install build dependencies + Rust toolchain (foreground, fast)
    if ! ensure_rust; then
        MANUAL_ITEMS+=("niri — Rust toolchain install failed, build manually: $NIRI_GH")
        return 1
    fi
    
    local bdeps_rc=0
    if [ "$DISTRO_FAMILY" = debian ]; then
        # --- Debian: apply version-specific package name mapping ---
        # Each mapped name is verified at runtime with apt-cache: if the mapped
        # package does not exist in this release, the ORIGINAL name is used instead.
        # (A wrong hardcoded mapping used to silently drop libdisplay-info-dev and
        # make the build die with "libdisplay-info.pc not found" after 10-20 min.)
        local _debian_deps=() _pkg_name _mapped
        for _pkg_name in "${NIRI_BUILD_DEPS[@]}"; do
            _mapped="${DEB_NIRI_BDEPS_MAP[$_pkg_name]:-}"
            if [ -n "$_mapped" ] && apt-cache policy "$_mapped" 2>/dev/null | grep -q 'Candidate: [0-9]'; then
                _debian_deps+=("$_mapped")
            else
                _debian_deps+=("$_pkg_name")
            fi
        done
        
        log "$(_t "Installing niri build dependencies (Debian/Ubuntu)..." "Installing niri build dependencies (Debian/Ubuntu)...")"
        apt_install_tolerant "${_debian_deps[@]}" || bdeps_rc=$?
        
        if [ ${#BDEPS_MISSING[@]} -gt 0 ]; then
            warn "$(_t "Some niri build deps unavailable:" "Some niri build deps unavailable:") ${BDEPS_MISSING[*]}"
        fi
        
        # --- Debian: hard verification of critical build deps ---
        # These are absolutely required; cargo will fail with obscure errors if missing.
        # libdisplay-info-dev is included because a missing display-info produces the
        # confusing "libdisplay-info.pc not found" build-script error after a long build.
        local _crit_deps=(build-essential cmake pkg-config clang libclang-dev \
            libwayland-dev wayland-protocols libpango1.0-dev libdisplay-info-dev \
            libxkbcommon-dev libinput-dev)
        local _crit _missing_crit=0 _tried_mirror=0 _last_crit=""
        # 关键依赖校验（带"换源后自动重试"）：当 apt 报 404 / 无法下载 / Failed to fetch
        # （典型：cn.archive.ubuntu.com 镜像同步滞后，索引有新版本但 pool 里 .deb 404）
        # 时，按 tuna → aliyun → ustc 顺序自动尝试换源；每个候选源换完会用 curl 探测
        # 之前 404 的 .deb 是否真的被新镜像同步（显式 404 才换下一个），换源成功则重试
        # 整轮校验。MANUAL 报告只在最终失败时追加一次。
        while :; do
            _missing_crit=0
            for _crit in "${_crit_deps[@]}"; do
                if ! pkg_installed "$_crit"; then
                    warn "$(_t "Critical build dep missing, retrying: " "Critical build dep missing, retrying: ") $_crit"
                    # apt 建议的 --fix-missing 一并带上：镜像缺个别 .deb 时能跳过继续
                    if [ "$DISTRO_FAMILY" = debian ] && command -v apt-get >/dev/null 2>&1; then
                        exe apt-get install -y --fix-missing "$_crit" 2>>"$LOG_DIR/apt-errors.log" || true
                    fi
                    pm_install "$_crit" 2>>"$LOG_DIR/apt-errors.log" || true
                    if ! pkg_installed "$_crit"; then
                        # Surface the REAL apt error (broken dpkg, unreachable repos,
                        # missing package) instead of a generic "unavailable" message.
                        local _aperr
                        _aperr=$(tail -n 3 "$LOG_DIR/apt-errors.log" 2>/dev/null | tr '\n' ' ')
                        error "$(_t "Critical build dependency NOT installed: " "Critical build dependency NOT installed: ") $_crit (apt error: $_aperr)"
                        _missing_crit=1
                        _last_crit="$_crit"
                    fi
                fi
            done
            # 命中镜像源故障特征（404 / 无法下载 / Failed to fetch / Hash Sum mismatch /
            # Release 过期）且尚未换过源 → 先查时钟，再依次尝试 tuna / aliyun / ustc，成功后重试一轮
            if [ "$_missing_crit" -eq 1 ] && [ "$_tried_mirror" -eq 0 ] \
                && grep -qiE '404|无法下载|Failed to fetch|Unable to fetch|Hash Sum mismatch|Release 文件已经过期|expired|Valid-Until' "$LOG_DIR/apt-errors.log" 2>/dev/null; then
                check_clock_drift   # 时钟偏快会让所有源报过期，换镜像无效——先提示
                warn "$(_t "apt 错误疑似镜像源问题（404 / 无法下载 / Release 过期）——自动尝试换源..." "apt 错误疑似镜像源问题（404 / 无法下载 / Release 过期）——自动尝试换源...")"
                local _m _switched=0
                for _m in tuna aliyun ustc; do
                    if confirm "$(_t "Try mirror $_m? [Y/n] (default Y):" "Try mirror $_m? [Y/n] (default Y):")" "Y" 10 2>/dev/null; then
                        if set_debian_mirror "$_m"; then
                            _switched=1
                            break
                        fi
                    fi
                done
                if [ "$_switched" -eq 1 ]; then
                    _tried_mirror=1
                    log "$(_t "Retrying critical build deps after mirror switch..." "Retrying critical build deps after mirror switch...")"
                    continue
                fi
                _tried_mirror=1   # 用户全部拒绝 / 所有候选源都未同步，不再重试
            fi
            break
        done
        if [ "$_missing_crit" -eq 1 ]; then
            local _aperr_final
            _aperr_final=$(tail -n 3 "$LOG_DIR/apt-errors.log" 2>/dev/null | tr '\n' ' ')
            MANUAL_ITEMS+=("niri — critical build dependency '${_last_crit:-?}' failed to install (apt error: $_aperr_final); 源镜像可能滞后/未同步——已尝试换源仍失败：检查网络与代理 (如 198.18.x.x TUN)，手动换 tuna/aliyun 源或运行 'sudo apt-get update' / 'sudo dpkg --configure -a' 后重跑: $NIRI_GH")
            return 1
        fi
    else
        exe dnf install -y "${NIRI_BUILD_DEPS_RHEL[@]}" || bdeps_rc=$?
    fi
    
    if [ "$bdeps_rc" -ne 0 ] && [ "$DISTRO_FAMILY" != debian ]; then
        MANUAL_ITEMS+=("niri — build dependencies install failed, build manually: $NIRI_GH")
        return 1
    fi

    # pkg-config pre-check (Debian + RHEL families): verify every .pc file the
    # build needs actually exists BEFORE starting the 10-20 min background build.
    # A missing .pc surfaces as "The system library X required by crate Y was not
    # found" only at the end of the build — this catches it in seconds instead.
    # Debian 系缺失时自动安装对应的 -dev 包（见全局 ensure_pc_deps）。
    if ! ensure_pc_deps libdisplay-info xkbcommon wayland-client \
            libinput libseat libpipewire-0.3 dbus-1 pango gbm egl \
            xcb-composite xcb-ewmh xcb-icccm xcb-randr xcb-xfixes \
            xcb-present xcb-render-util xcb-res xcb-shape xcb-util xcb-xkb xcb-xinerama; then
        error "$(_t "niri — required system libraries still missing: " "niri — required system libraries still missing: ") ${PC_STILL_MISSING[*]}$(_t " — install the -dev/-devel packages, then rerun: $NIRI_GH" " — install the -dev/-devel packages, then rerun: $NIRI_GH")"
        MANUAL_ITEMS+=("niri — 系统库缺失: ${PC_STILL_MISSING[*]}（$PC_FAIL_HINT）; 手动安装对应 -dev 包后重跑: $NIRI_GH")
        return 1
    fi
    [ "$PC_AUTO_INSTALLED" -gt 0 ] && log "$(_t "pkg-config pre-check passed after auto-install." "pkg-config pre-check passed after auto-install.")"

    # Build in background so the rest of the install (packages/services/config) proceeds meanwhile
    log "$(_t "Building niri in background; continuing install..." "Building niri in background; continuing install...")"
    bg_build_start niri "$srcdir" "$LOG_DIR/niri-build.log" \
        bash -c "cd '$srcdir' && RUST_LOG=info cargo build --release -vv -j $(cargo_jobs) 2>&1"
    return "$BG_PENDING_RC"
}

# RAM-aware cargo parallelism: cap jobs so big builds (niri needs ~1.5-2GB/job) don't OOM small VMs
cargo_jobs() { # echoes the job count to use
    local ram_mb jobs max_by_ram
    ram_mb=$(free -m 2>/dev/null | awk '/Mem:/{print $2}')
    jobs=$(nproc 2>/dev/null || echo 2)
    [ "${ram_mb:-0}" -gt 0 ] || ram_mb=4096
    max_by_ram=$(( ram_mb / 1536 ))
    [ "$max_by_ram" -lt 1 ] && max_by_ram=1
    [ "$jobs" -gt "$max_by_ram" ] && jobs="$max_by_ram"
    echo "$jobs"
}

# Install the binaries produced by the background niri build (runs in stage_wait_builds)
install_niri_from_build() { # $1 = srcdir, $2 = logfile
    local srcdir="$1" logfile="$2"
    if [ -x "$srcdir/target/release/niri" ]; then
        exe install -Dm755 "$srcdir/target/release/niri" /usr/local/bin/niri
        exe install -Dm755 "$srcdir/resources/niri-session" /usr/local/bin/niri-session 2>/dev/null || true
        exe install -Dm644 "$srcdir/resources/niri.desktop" /usr/local/share/wayland-sessions/niri.desktop 2>/dev/null || true
        exe install -Dm644 "$srcdir/resources/niri.desktop" /usr/share/wayland-sessions/niri.desktop 2>/dev/null || true
        exe install -Dm644 "$srcdir/resources/niri-portals.conf" /usr/local/share/xdg-desktop-portal/niri-portals.conf 2>/dev/null || true
        # 关键：niri-session 用 systemd user session 启动 niri（systemctl --user start niri.service）。
        # 必须把 niri 源码 resources/ 里的 systemd user unit 装到 /usr/lib/systemd/user/，
        # 否则 GDM 登录时 "Unit niri.service not found" → niri 起不来 → 跳回登录界面（登录循环）。
        local _unit _unit_installed=0
        mkdir -p /usr/lib/systemd/user
        for _unit in "$srcdir"/resources/*.service "$srcdir"/resources/*.target "$srcdir"/resources/niri.session; do
            [ -f "$_unit" ] || continue
            exe install -Dm644 "$_unit" "/usr/lib/systemd/user/$(basename "$_unit")" 2>/dev/null && _unit_installed=1
        done
        if [ "$_unit_installed" -eq 1 ]; then
            log "$(_t "niri systemd user units installed (/usr/lib/systemd/user)" "niri systemd user units installed (/usr/lib/systemd/user)")"
        else
            warn "$(_t "niri systemd user units not found in source resources/ — GDM 登录可能循环; 手动创建 /usr/lib/systemd/user/niri.service 与 niri-shutdown.target" "niri systemd user units not found in source resources/ — GDM 登录可能循环; 手动创建 /usr/lib/systemd/user/niri.service 与 niri-shutdown.target")"
        fi
        INSTALLED_PKGS+=("niri (source build)")
        success "$(_t "niri built from source" "niri built from source")"
        return 0
    fi
    local tailmsg
    tailmsg=$(tail -n 6 "$logfile" 2>/dev/null | tr '\n' ' ')
    MANUAL_ITEMS+=("niri — build failed ($tailmsg); build manually: $NIRI_GH")
    return 1
}

# --- awww install (Debian/RHEL families; no package, no prebuilt binary) ---
# awww moved from GitHub to Codeberg and now replaces swww. No release binaries are published,
# so the only option outside Arch/Fedora repos is a cargo build from the upstream source (~5 min).
AWWW_REPO="https://codeberg.org/LGFae/awww"

install_awww() {
    if command -v awww >/dev/null 2>&1 && command -v awww-daemon >/dev/null 2>&1; then
        SKIPPED_PKGS+=("awww (already installed)")
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        DRY_PKGS+=("awww (cargo build from codeberg)")
        return "$DRY_RUN_RC"
    fi

    # build deps: wayland protocol XML via pkg-config is required by upstream;
    # the `common` crate links lz4 (needs the -dev package providing liblz4.pc);
    # dav1d/lz4 runtime libs are best effort.
    local bdeps_rc=0
    if [ "$DISTRO_FAMILY" = debian ]; then
        apt_install_tolerant git libwayland-dev wayland-protocols liblz4-dev \
            libxkbcommon-dev libdav1d-dev || bdeps_rc=$?
        if [ ${#BDEPS_MISSING[@]} -gt 0 ]; then
            warn "$(_t "Some awww build deps unavailable (continuing):" "Some awww build deps unavailable (continuing):") ${BDEPS_MISSING[*]}"
        fi
        exe apt-get install -y libdav1d6 2>/dev/null || true
        # pkg-config 预检 + 自愈：wayland-client / xkbcommon / liblz4 / dav1d 缺哪个自动装哪个
        # （注意 lz4 的 .pc 文件名是 liblz4.pc，lz4-sys 探测的也是 liblz4）
        if ! ensure_pc_deps wayland-client xkbcommon liblz4 dav1d; then
            MANUAL_ITEMS+=("awww — 系统库缺失: ${PC_STILL_MISSING[*]}（$PC_FAIL_HINT）; 手动安装对应 -dev 包后重跑: $AWWW_REPO")
            return 1
        fi
    else
        # RHEL: awww's common crate links xkbcommon + lz4 (mandatory); dav1d is an
        # optional runtime codec, so only lz4/xkbcommon are hard pre-checks. Tolerant
        # so a missing name (e.g. dav1d-devel on older EL) never aborts the batch.
        dnf_install_tolerant git wayland-devel wayland-protocols-devel lz4-devel \
            xkbcommon-devel dav1d-devel || bdeps_rc=$?
        if [ ${#BDEPS_MISSING[@]} -gt 0 ]; then
            warn "$(_t "Some awww build deps unavailable (continuing):" "Some awww build deps unavailable (continuing):") ${BDEPS_MISSING[*]}"
        fi
        exe dnf install -y dav1d lz4 2>/dev/null || true
        # pkg-config 预检（RHEL 只校验不自愈）：wayland-client / xkbcommon / liblz4
        # 必装；dav1d 可选，缺了不阻塞（awww 仍能编译/运行）。
        if ! ensure_pc_deps wayland-client xkbcommon liblz4; then
            MANUAL_ITEMS+=("awww — 系统库缺失: ${PC_STILL_MISSING[*]}（$PC_FAIL_HINT）; 手动安装对应 -devel 包后重跑: $AWWW_REPO")
            return 1
        fi
    fi
    if [ "$bdeps_rc" -ne 0 ] && [ "$DISTRO_FAMILY" != debian ]; then
        MANUAL_ITEMS+=("awww — build dependencies install failed, build manually: $AWWW_REPO")
        return 1
    fi
    if ! ensure_rust; then
        MANUAL_ITEMS+=("awww — Rust toolchain install failed, build manually: $AWWW_REPO")
        return 1
    fi

    local work
    work=$(mktemp -d)
    register_temp_path "$work"
    log "$(_t "Cloning awww source (codeberg)..." "Cloning awww source (codeberg)...")"
    
    local _clone_attempts=3 _clone_delay=10 _clonerc=0
    for (( _cattempt=1; _cattempt<=$_clone_attempts; _cattempt++ )); do
        if exe git clone --depth 1 "$AWWW_REPO" "$work/awww" 2>/dev/null; then
            _clonerc=0
            break
        fi
        _clonerc=$?
        if [ "$_cattempt" -lt "$_clone_attempts" ]; then
            log "$(_t "Clone attempt $_cattempt/$_clone_attempts failed, retrying in ${_clone_delay}s..." "Clone attempt $_cattempt/$_clone_attempts failed, retrying in ${_clone_delay}s...")"
            sleep "$_clone_delay"
            rm -rf "$work/awww"
        fi
    done
    
    if [ "$_clonerc" -ne 0 ]; then
        MANUAL_ITEMS+=("awww — git clone failed after $_clone_attempts attempts (network or Codeberg blocked), build manually: $AWWW_REPO")
        return 1
    fi

    # Build in background so the rest of the install proceeds meanwhile.
    # On low-RAM machines, wait for the niri build to finish first (avoids OOM from two parallel cargo builds).
    local awww_cmd ram_mb niri_pid
    awww_cmd="cd '$work/awww' && cargo build --release --workspace -j $(cargo_jobs)"
    ram_mb=$(free -m 2>/dev/null | awk '/Mem:/{print $2}')
    if [ "${ram_mb:-0}" -lt 8192 ] && [ ${#BG_JOBS[@]} -gt 0 ]; then
        niri_pid=$(echo "${BG_JOBS[0]}" | awk '{print $2}')
        awww_cmd="while kill -0 '$niri_pid' 2>/dev/null; do sleep 15; done; $awww_cmd"
        log "$(_t "Low RAM detected: awww build will wait for niri to finish first." "Low RAM detected: awww build will wait for niri to finish first.")"
    fi
    log "$(_t "Building awww in background (~5 min); continuing install..." "Building awww in background (~5 min); continuing install...")"
    bg_build_start awww "$work/awww" "$LOG_DIR/awww-build.log" bash -c "$awww_cmd"
    return "$BG_PENDING_RC"
}

# Install the binaries produced by the background awww build (runs in stage_wait_builds)
install_awww_from_build() { # $1 = srcdir, $2 = logfile
    local srcdir="$1" logfile="$2" b found=0
    for b in "$srcdir"/target/release/awww*; do
        [ -x "$b" ] && [ -f "$b" ] || continue
        exe install -Dm755 "$b" /usr/local/bin/"$(basename "$b")"
        found=1
    done
    if [ "$found" -eq 1 ] && [ -x /usr/local/bin/awww ]; then
        INSTALLED_PKGS+=("awww (cargo build)")
        success "$(_t "awww built from source" "awww built from source")"
        return 0
    fi
    local tailmsg
    tailmsg=$(tail -n 6 "$logfile" 2>/dev/null | tr '\n' ' ')
    MANUAL_ITEMS+=("awww — build failed ($tailmsg); build manually: $AWWW_REPO")
    return 1
}

# 壁纸缺失自愈：参考机的壁纸图片不在 configs/ 内，新机器上 awww-daemon 无图可设，
# 导致壁纸不生效（awww-daemon 必须启动时就有壁纸状态，见 mylinuxforwork/dotfiles#1574）。
# 优先使用仓库根目录的壁纸图（复制到 ~/.local/share/backgrounds/，同时作为锁屏壁纸），
# 没有则找现有图片，再没有就生成一张深蓝紫渐变 PNG（python3 标准库，无 PIL 依赖）；
# 写入 awww 状态文件 ~/.config/awww/wallpaper 供 awww-daemon 加载；
# 修正 waypaper config.ini 与 hyprlock.conf（锁屏壁纸）里指向参考机的绝对路径。
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
            # stylesheet 键：参考机绝对路径已由 collect-config 擦除为 $HOME，这里展开成绝对路径
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

install_satty() {
    if command -v satty >/dev/null 2>&1; then
        SKIPPED_PKGS+=("satty (already installed)")
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        DRY_PKGS+=("satty (official prebuilt or cargo)")
        return "$DRY_RUN_RC"
    fi

    local arch
    case "$(uname -m)" in
        x86_64)  arch=x86_64 ;;
        aarch64) arch=aarch64 ;;
        *)
            MANUAL_ITEMS+=("satty — unsupported architecture $(uname -m), install manually: $SATTY_GH")
            return 1
            ;;
    esac

    # runtime libraries the prebuilt binary links against (best effort)
    if [ "$DISTRO_FAMILY" = debian ]; then
        exe apt-get install -y libgtk-4-1 libadwaita-1-0 librsvg2-2 || warn "$(_t "satty runtime libraries failed to install; the binary may not start." "satty runtime libraries failed to install; the binary may not start.")"
    else
        exe dnf install -y gtk4 libadwaita librsvg2 || warn "$(_t "satty runtime libraries failed to install; the binary may not start." "satty runtime libraries failed to install; the binary may not start.")"
    fi

    # --- Strategy 1: official prebuilt binary ---
    # Direct "latest/download" URL (no API call), GitHub direct
    local url tmp work b satty_bin
    tmp=$(mktemp)
    work=$(mktemp -d)
    register_temp_path "$tmp"
    register_temp_path "$work"
    url="$SATTY_GH/latest/download/satty-${arch}-unknown-linux-gnu.tar.gz"
    log "$(_t "Downloading satty official prebuilt binary..." "Downloading satty official prebuilt binary...")"
    
    local _satty_attempts=3 _satty_delay=10 _sattyrc=0
    for (( _sattempt=1; _sattempt<=$_satty_attempts; _sattempt++ )); do
        if download_gh "$url" "$tmp" && tar xzf "$tmp" -C "$work" 2>/dev/null; then
            _sattyrc=0
            break
        fi
        _sattyrc=$?
        if [ "$_sattempt" -lt "$_satty_attempts" ]; then
            log "$(_t "Satty download attempt $_sattempt/$_satty_attempts failed, retrying in ${_satty_delay}s..." "Satty download attempt $_sattempt/$_satty_attempts failed, retrying in ${_satty_delay}s...")"
            sleep "$_satty_delay"
            rm -f "$tmp"
            tmp=$(mktemp)
            rm -rf "$work"
            work=$(mktemp -d)
        fi
    done
    
    if [ "$_sattyrc" -eq 0 ]; then
        satty_bin=""
        if [ -d "$work/bin" ]; then
            for b in "$work"/bin/*; do
                [ -x "$b" ] && satty_bin="$b"
            done
        elif [ -x "$work/satty" ]; then
            satty_bin="$work/satty"
        else
            # fall back to any executable named satty anywhere in the archive
            satty_bin=$(find "$work" -type f -name satty -perm -u+x 2>/dev/null | head -n 1)
        fi
        if [ -n "$satty_bin" ]; then
            exe install -Dm755 "$satty_bin" /usr/local/bin/satty
            [ -d "$work/share" ] && exe cp -r "$work"/share/. /usr/local/share/ 2>/dev/null || true
            INSTALLED_PKGS+=("satty (official prebuilt)")
            success "$(_t "satty installed" "satty installed")"
            return 0
        fi
    fi
    warn "$(_t "Prebuilt satty download failed, falling back to cargo." "Prebuilt satty download failed, falling back to cargo.")"

    # --- Strategy 2: cargo install (crates.io) ---
    local bdeps_rc=0
    if [ "$DISTRO_FAMILY" = debian ]; then
        apt_install_tolerant build-essential pkg-config libgtk-4-dev libadwaita-1-dev librsvg2-dev || bdeps_rc=$?
        if [ ${#BDEPS_MISSING[@]} -gt 0 ]; then
            warn "$(_t "Some satty build deps unavailable (continuing):" "Some satty build deps unavailable (continuing):") ${BDEPS_MISSING[*]}"
        fi
    else
        exe dnf install -y gcc pkgconf-pkg-config gtk4-devel libadwaita-devel librsvg2-devel || bdeps_rc=$?
    fi
    if [ "$bdeps_rc" -ne 0 ] && [ "$DISTRO_FAMILY" != debian ]; then
        MANUAL_ITEMS+=("satty — build dependencies install failed, install manually: $SATTY_GH")
        return 1
    fi
    if ! ensure_rust; then
        MANUAL_ITEMS+=("satty — Rust toolchain install failed, install manually: $SATTY_GH")
        return 1
    fi
    log "$(_t "Building satty via cargo (about 5 min)..." "Building satty via cargo (about 5 min)...")"
    if exe cargo install --root /usr/local satty; then
        INSTALLED_PKGS+=("satty (cargo build)")
        success "$(_t "satty built from source" "satty built from source")"
        return 0
    fi
    MANUAL_ITEMS+=("satty — build failed, install manually: $SATTY_GH")
    return 1
}

# --- rime-ice (Lùsōng) dictionary deploy (Debian/RHEL families) ---
# No package exists outside Arch; upstream ships a release zip (official install method):
# download full.zip, extract, copy into the user's fcitx5 rime dir.
RIME_ICE_REPO="https://github.com/iDvel/rime-ice"
RIME_ICE_ZIP_URL="https://github.com/iDvel/rime-ice/releases/latest/download/full.zip"

install_rime_ice() {
    local dest="$HOME_DIR/.local/share/fcitx5/rime"
    if [ -f "$dest/rime_ice.schema.yaml" ]; then
        SKIPPED_PKGS+=("rime-ice (already deployed)")
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        DRY_PKGS+=("rime-ice (dictionary deploy)")
        return "$DRY_RUN_RC"
    fi
    if [ -z "$TARGET_USER" ] || [ -z "$HOME_DIR" ]; then
        MANUAL_ITEMS+=("rime-ice — target user not detected yet, deploy manually: git clone $RIME_ICE_REPO -> $dest")
        return 1
    fi

    # fcitx5-rime must exist for this to be useful — try to install it first, since
    # it can be absent if the ime group selection skipped it or its dnf/apt install
    # was deferred (rime-ice-pinyin-git is only usable with the rime engine present).
    if ! pkg_installed fcitx5-rime; then
        log "$(_t "fcitx5-rime not installed — installing it before deploying rime-ice..." "fcitx5-rime not installed — installing it before deploying rime-ice...")"
        pm_install fcitx5-rime 2>>"$LOG_DIR/pkg-errors.log"
    fi
    if ! pkg_installed fcitx5-rime; then
        MANUAL_ITEMS+=("rime-ice — fcitx5-rime not installed (and could not be installed), skip deploy")
        return 1
    fi
    if ! command -v unzip &>/dev/null; then
        pm_install unzip || { MANUAL_ITEMS+=("rime-ice — unzip missing, deploy manually: $RIME_ICE_REPO"); return 1; }
    fi

    # Official release zip (much faster than git clone), GitHub direct
    local zipfile unzipdir item b
    zipfile=$(mktemp)
    unzipdir=$(mktemp -d)
    register_temp_path "$zipfile"
    register_temp_path "$unzipdir"
    log "$(_t "Downloading rime-ice release zip..." "Downloading rime-ice release zip...")"
    
    local _rime_attempts=3 _rime_delay=10 _rimerc=0
    for (( _rattempt=1; _rattempt<=$_rime_attempts; _rattempt++ )); do
        if download_gh "$RIME_ICE_ZIP_URL" "$zipfile"; then
            _rimerc=0
            break
        fi
        _rimerc=$?
        if [ "$_rattempt" -lt "$_rime_attempts" ]; then
            log "$(_t "Rime-ice download attempt $_rattempt/$_rime_attempts failed, retrying in ${_rime_delay}s..." "Rime-ice download attempt $_rattempt/$_rime_attempts failed, retrying in ${_rime_delay}s...")"
            sleep "$_rime_delay"
            rm -f "$zipfile"
            zipfile=$(mktemp)
        fi
    done
    
    if [ "$_rimerc" -ne 0 ]; then
        MANUAL_ITEMS+=("rime-ice — download failed after $_rime_attempts attempts, deploy manually: $RIME_ICE_REPO")
        return 1
    fi
    if ! exe unzip -q "$zipfile" -d "$unzipdir"; then
        MANUAL_ITEMS+=("rime-ice — zip extraction failed, deploy manually: $RIME_ICE_REPO")
        return 1
    fi

    exe mkdir -p "$dest"
    for item in "$unzipdir"/*; do
        [ -e "$item" ] || continue
        b=$(basename "$item")
        case "$b" in
            .git|.github|build|README.md|LICENSE|AGENTS.md|recipe.yaml) continue ;;
        esac
        exe cp -r "$item" "$dest/"
    done
    exe chown -R "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$dest" 2>/dev/null || true

    if [ -f "$dest/rime_ice.schema.yaml" ]; then
        INSTALLED_PKGS+=("rime-ice (deployed to $dest)")
        success "$(_t "rime-ice deployed" "rime-ice deployed")"
        return 0
    fi
    MANUAL_ITEMS+=("rime-ice — deploy failed, do it manually: $RIME_ICE_REPO $dest")
    return 1
}

# --- xwayland-satellite (Debian family & Rocky/Alma; Fedora's official repo already has it) ---
# NOT published on crates.io (verified 404) — install from the upstream GitHub repo via cargo --git.
XWS_REPO="https://github.com/Supreeeme/xwayland-satellite"
install_xwayland_satellite() {
    if command -v xwayland-satellite >/dev/null 2>&1; then
        SKIPPED_PKGS+=("xwayland-satellite (already installed)")
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        DRY_PKGS+=("xwayland-satellite (cargo --git)")
        return "$DRY_RUN_RC"
    fi
    # the Xwayland server it wraps (best effort; binary still installs without it)
    if ! command -v Xwayland >/dev/null 2>&1; then
        pm_install xwayland 2>/dev/null || warn "$(_t "xwayland package not available; xwayland-satellite needs Xwayland at runtime." "xwayland package not available; xwayland-satellite needs Xwayland at runtime.")"
    fi
    # build deps: upstream needs clang (bindgen) + xcb-cursor dev headers + git (cargo --git);
    # wayland-client / xkbcommon / xcb-util .pc 也由下面的 ensure_pc_deps 兜底
    local bdeps_rc=0
    if [ "$DISTRO_FAMILY" = debian ]; then
        apt_install_tolerant git clang libclang-dev libxcb-cursor-dev \
            libwayland-dev wayland-protocols libxkbcommon-dev libxcb-util-dev || bdeps_rc=$?
        if [ ${#BDEPS_MISSING[@]} -gt 0 ]; then
            warn "$(_t "Some xwayland-satellite build deps unavailable (continuing):" "Some xwayland-satellite build deps unavailable (continuing):") ${BDEPS_MISSING[*]}"
        fi
        # pkg-config 预检 + 自愈：wayland-client / xkbcommon / xcb-cursor 缺哪个自动装哪个
        if ! ensure_pc_deps wayland-client xkbcommon xcb-cursor; then
            MANUAL_ITEMS+=("xwayland-satellite — 系统库缺失: ${PC_STILL_MISSING[*]}（$PC_FAIL_HINT）; 手动安装对应 -dev 包后重跑: $XWS_REPO")
            return 1
        fi
    else
        # RHEL: also need the wayland/xkbcommon/xcb-util dev headers for the .pc the
        # build links against; tolerant so a missing name never aborts the batch.
        dnf_install_tolerant git clang libxcb-cursor-devel \
            wayland-devel wayland-protocols-devel libxkbcommon-devel xcb-util-devel || bdeps_rc=$?
        if [ ${#BDEPS_MISSING[@]} -gt 0 ]; then
            warn "$(_t "Some xwayland-satellite build deps unavailable (continuing):" "Some xwayland-satellite build deps unavailable (continuing):") ${BDEPS_MISSING[*]}"
        fi
        # pkg-config 预检（RHEL 只校验不自愈）
        if ! ensure_pc_deps wayland-client xkbcommon xcb-cursor; then
            MANUAL_ITEMS+=("xwayland-satellite — 系统库缺失: ${PC_STILL_MISSING[*]}（$PC_FAIL_HINT）; 手动安装对应 -devel 包后重跑: $XWS_REPO")
            return 1
        fi
    fi
    if [ "$bdeps_rc" -ne 0 ] && [ "$DISTRO_FAMILY" != debian ]; then
        MANUAL_ITEMS+=("xwayland-satellite — build dependencies install failed (git/clang/libxcb-cursor-devel); install manually: $XWS_REPO")
        return 1
    fi
    if ! ensure_rust; then
        MANUAL_ITEMS+=("xwayland-satellite — Rust toolchain install failed; install manually: $XWS_REPO")
        return 1
    fi
    # NOT on crates.io (verified 404) — clone via CN mirrors (direct GitHub git fetch is
    # often blocked) and install from the local checkout instead of `cargo install --git`.
    local work logf
    work=$(mktemp -d)
    register_temp_path "$work"
    log "$(_t "Cloning xwayland-satellite (GitHub, via CN mirror if needed)..." "Cloning xwayland-satellite (GitHub, via CN mirror if needed)...")"
    if ! git_clone_gh "$XWS_REPO" "$work/xws"; then
        MANUAL_ITEMS+=("xwayland-satellite — git clone failed (direct + CN mirrors); install manually: $XWS_REPO (or Fedora repo)")
        return 1
    fi
    logf="$LOG_DIR/xwayland-satellite-build.log"
    log "$(_t "Building xwayland-satellite via cargo (about 3 min)..." "Building xwayland-satellite via cargo (about 3 min)...")"
    ( cd "$work/xws" && cargo install --path . --locked --root /usr/local xwayland-satellite ) 2>&1 | tee "$logf"
    local crc=${PIPESTATUS[0]}
    if [ "$crc" -eq 0 ]; then
        INSTALLED_PKGS+=("xwayland-satellite (cargo build)")
        success "$(_t "xwayland-satellite installed" "xwayland-satellite installed")"
        return 0
    fi
    local tailmsg
    tailmsg=$(tail -n 6 "$logf" 2>/dev/null | tr '\n' ' ')
    MANUAL_ITEMS+=("xwayland-satellite — build failed ($tailmsg); install manually: $XWS_REPO (or Fedora repo)")
    return 1
}

# Build the hypr C++ build-tool stack that hyprlock/hypridle require, from source,
# in dependency order. On distros where the stack is packaged (Fedora base, Ubuntu
# 25.10+/Debian 13+ universe) these -devel packages were already installed above and
# this whole function is a no-op. On Rocky/Alma/CentOS Stream none of it is packaged,
# so we compile hyprwayland-scanner -> hyprutils -> hyprlang -> hyprgraphics and
# install each to /usr (cmake configs land in /usr/lib64/cmake/), letting each later
# component's find_package/hyprutils-config.cmake resolve in the default search path.
# Each component is skipped if it is already resolvable (installed as a package).
build_hypr_stack() {
    [ "$DRY_RUN" -eq 1 ] && return "$DRY_RUN_RC"
    local _log="$LOG_DIR/hypr-stack.log"
    local _work
    _work=$(mktemp -d)
    register_temp_path "$_work"

    # Build+install one component into /usr. Returns 0 on success.
    _build_hypr_one() { # $1 = name
        local n="$1"
        if git_clone_gh "https://github.com/hyprwm/$n" "$_work/$n" >/dev/null 2>&1 \
           && ( cd "$_work/$n" \
                && cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr . \
                && cmake --build build -j"$(nproc)" \
                && cmake --install build ) >> "$_log" 2>&1; then
            INSTALLED_PKGS+=("hypr-$n (source build)")
            log "$(_t "Built " "Built ") hypr-$n$(_t " from source" " from source")"
            return 0
        fi
        return 1
    }

    # Skip a component when the packaged -devel is already available:
    #   hyprwayland-scanner  -> `hyprwayland-scanner` binary on PATH
    #   hyprutils/hyprlang/...-> its cmake config under /usr/lib{,64}/cmake/<name>/
    _hypr_ok() { # $1 = name (also the cmake config dir basename)
        local n="$1" d
        case "$n" in
            hyprwayland-scanner) command -v hyprwayland-scanner >/dev/null 2>&1 && return 0 ;;
            *)
                for d in /usr/lib/cmake/"$n" /usr/lib64/cmake/"$n" /usr/local/lib/cmake/"$n" /usr/local/lib64/cmake/"$n"; do
                    [ -d "$d" ] && find "$d" -maxdepth 1 -iname '*.cmake' 2>/dev/null | grep -qi . && return 0
                done
                ;;
        esac
        return 1
    }

    # Strict dependency order. hyprcursor is not required by hyprlock/hypridle builds,
    # so don't force it (keeps the chain shorter and less likely to fail).
    _hypr_ok hyprwayland-scanner "hyprwayland" || _build_hypr_one hyprwayland-scanner || return 1
    _hypr_ok hyprutils "hyprutils" || _build_hypr_one hyprutils || return 1
    _hypr_ok hyprlang "hyprlang" || _build_hypr_one hyprlang || return 1
    _hypr_ok hyprgraphics "hyprgraphics" || _build_hypr_one hyprgraphics || return 1
    return 0
}

# --- hyprlock / hypridle source build (fallback when no apt/dnf package) ---
# Used for any package listed in SOURCE_PKGS. Clones the upstream repo (CN-mirror
# aware), installs the hyprwm build deps tolerantly, then builds — auto-detecting
# the build system: older versions are Rust (cargo build), current ones are
# C++/CMake (cmake -B build; the repos no longer ship a Cargo.toml). Installs the
# binary to /usr/local/bin. For hyprlock it also writes /etc/pam.d/hyprlock (the
# apt package ships one, but a source build does not — without it hyprlock cannot
# authenticate).
install_hypr_source() { # $1 = pkg name, $2 = repo URL
    local pkg="$1" repo="$2"
    if command -v "$pkg" >/dev/null 2>&1; then
        SKIPPED_PKGS+=("$pkg (already installed)")
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        DRY_PKGS+=("$pkg (source build)")
        return "$DRY_RUN_RC"
    fi

    # build deps (tolerant: many hypr deps are absent on older releases / Rocky/Alma)
    local _brc=0
    if [ "$DISTRO_FAMILY" = debian ]; then
        apt_install_tolerant "${HYPR_BUILD_DEPS_DEB[@]}" || _brc=$?
        if [ ${#BDEPS_MISSING[@]} -gt 0 ]; then
            warn "$(_t "Some $pkg build deps unavailable (continuing):" "Some $pkg build deps unavailable (continuing):") ${BDEPS_MISSING[*]}"
        fi
    else
        dnf_install_tolerant "${HYPR_BUILD_DEPS_RHEL[@]}" || _brc=$?
        if [ ${#BDEPS_MISSING[@]} -gt 0 ]; then
            warn "$(_t "Some $pkg build deps unavailable (continuing):" "Some $pkg build deps unavailable (continuing):") ${BDEPS_MISSING[*]}"
        fi
    fi
    if ! ensure_rust; then
        MANUAL_ITEMS+=("$pkg — Rust toolchain install failed, build manually: $repo")
        return 1
    fi

    local work
    work=$(mktemp -d)
    register_temp_path "$work"
    log "$(_t "Cloning " "Cloning ") $pkg ($repo)..."
    if ! git_clone_gh "$repo" "$work/$pkg"; then
        MANUAL_ITEMS+=("$pkg — git clone failed (direct + CN mirrors), build manually: $repo")
        return 1
    fi

    # hyprlock/hypridle migrated from Rust to C++/CMake: the repos no longer contain
    # a Cargo.toml (only CMakeLists.txt). Detect the build system instead of blindly
    # running `cargo build` (which used to die with "could not find Cargo.toml").
    local logf="$LOG_DIR/$pkg-build.log" _bin=""
    if [ -f "$work/$pkg/Cargo.toml" ]; then
        log "$(_t "Building " "Building ") $pkg (cargo) from source (~3 min, log: $logf)..."
        ( cd "$work/$pkg" && cargo build --release ) > "$logf" 2>&1
        _bin="$work/$pkg/target/release/$pkg"
    elif [ -f "$work/$pkg/CMakeLists.txt" ]; then
        # CMake build needs hyprwayland-scanner + hyprlang/hyprgraphics/hyprutils;
        # build the hypr C++ stack from source iff those aren't already packaged.
        if ! build_hypr_stack; then
            MANUAL_ITEMS+=("$pkg — hypr C++ build stack (hyprwayland-scanner/hyprutils/hyprlang/hyprgraphics) could not be built; see $LOG_DIR/hypr-stack.log. Build manually: $repo")
            return 1
        fi
        log "$(_t "Building " "Building ") $pkg (CMake) from source (~3 min, log: $logf)..."
        ( cd "$work/$pkg" && cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr . \
            && cmake --build build -j"$(nproc)" ) > "$logf" 2>&1
        _bin="$work/$pkg/build/$pkg"
    else
        MANUAL_ITEMS+=("$pkg — cloned source has neither Cargo.toml nor CMakeLists.txt; build manually: $repo")
        return 1
    fi
    if [ ! -x "$_bin" ]; then
        local tailmsg
        tailmsg=$(tail -n 6 "$logf" 2>/dev/null | tr '\n' ' ')
        MANUAL_ITEMS+=("$pkg — build failed ($tailmsg); build manually: $repo")
        warn "$(_t "Build failed: " "Build failed: ") $pkg (see $logf)"
        return 1
    fi

    exe install -Dm755 "$_bin" "/usr/local/bin/$pkg"
    INSTALLED_PKGS+=("$pkg (source build)")
    success "$(_t "$pkg built from source" "$pkg built from source")"

    # hyprlock needs a PAM config to authenticate; the apt package ships one, a source build does not.
    if [ "$pkg" = hyprlock ] && [ ! -f /etc/pam.d/hyprlock ]; then
        local _pam_src="$work/$pkg/pam/hyprlock"
        mkdir -p /etc/pam.d
        if [ -f "$_pam_src" ]; then
            exe install -Dm644 "$_pam_src" /etc/pam.d/hyprlock
        else
            cat > /etc/pam.d/hyprlock <<'PAMEOF'
# Minimal PAM config for hyprlock (generated by eilNiri source build)
auth       include      login
-account   include      login
password   include      login
session    include      login
PAMEOF
        fi
        log "$(_t "Wrote /etc/pam.d/hyprlock for source-built hyprlock" "Wrote /etc/pam.d/hyprlock for source-built hyprlock")"
    fi
    return 0
}

install_debian() {
    local p name erc
    local all=(${REPO_SEL[@]+"${REPO_SEL[@]}"})

    # pip fallback pre-check
    local has_pip_target=0
    for p in "${all[@]}"; do
        if [ -n "${PIP_PKGS[$p]:-}" ]; then has_pip_target=1; break; fi
    done
    if [ "$has_pip_target" -eq 1 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            DRY_PKGS+=("python3-pip")
        else
            pm_install python3-pip
        fi
        if [ "$DRY_RUN" -eq 0 ] && ! command -v pip3 &>/dev/null; then
            MANUAL_ITEMS+=("python3-pip — pip3 not installed, run: sudo apt-get install python3-pip")
        fi
    fi

    for p in ${all[@]+"${all[@]}"}; do
        # niri: not in official repos, use prebuilt/source install
        if [ "$p" = "niri" ]; then
            install_niri_binary
            continue
        fi
        # awww/satty: no .deb in any Debian-family repo (prebuilt binary / cargo build)
        if [ "$p" = "awww" ]; then
            install_awww
            continue
        fi
        if [ "$p" = "satty" ]; then
            install_satty
            continue
        fi
        # rime-ice: no .deb; deploy the dictionary from GitHub (fcitx5-rime package provides the engine)
        if [ "$p" = "rime-ice-pinyin-git" ]; then
            install_rime_ice
            continue
        fi
        # xwayland-satellite: not in Debian/Ubuntu stable repos; cargo install fallback
        if [ "$p" = "xwayland-satellite" ]; then
            install_xwayland_satellite
            continue
        fi
        if [ -n "${DEB_MANUAL[$p]:-}" ]; then
            MANUAL_ITEMS+=("$p — ${DEB_MANUAL[$p]}")
            continue
        fi
        if [ -n "${PIP_PKGS[$p]:-}" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                DRY_PKGS+=("$p (pip)")
                continue
            fi
            if ! command -v pip3 &>/dev/null; then
                MANUAL_ITEMS+=("$p — pip3 not installed, run: sudo apt-get install python3-pip")
                continue
            fi
            erc=0
            # PEP 668 (externally-managed-environment) requires --break-system-packages
            exe as_user pip3 install --user --break-system-packages "${PIP_PKGS[$p]}" || erc=$?
            if [ "$erc" -eq 0 ]; then
                INSTALLED_PKGS+=("$p (pip)")
            else
                MANUAL_ITEMS+=("$p — pip install failed, do it manually: pip3 install --user --break-system-packages ${PIP_PKGS[$p]}")
            fi
            continue
        fi
        name="${DEB_MAP[$p]:-$p}"
        if pkg_installed "$name"; then
            SKIPPED_PKGS+=("$name (already installed)")
            continue
        fi
        erc=0
        pm_install "$name" || erc=$?
        if [ "$erc" -eq 0 ]; then
            INSTALLED_PKGS+=("$name")
        elif [ "$erc" -eq "$DRY_RUN_RC" ]; then
            DRY_PKGS+=("$name")
        else
            if [ -n "${SOURCE_PKGS[$p]:-}" ]; then
                warn "$(_t "No apt package for " "No apt package for ") $p, building from source..."
                install_hypr_source "$p" "${SOURCE_PKGS[$p]}"
            elif [ -n "${DEB_FAIL_HINT[$p]:-}" ]; then
                MANUAL_ITEMS+=("$name — not available in repo. ${DEB_FAIL_HINT[$p]}")
            else
                FAILED_PKGS+=("apt:$name")
            fi
        fi
    done
}

# [fonts] 分组的 ttf-jetbrains-mono-nerd 在 Debian/RHEL 上 apt/dnf 装的只是普通
# JetBrains Mono（无 Nerd Font 图标）。waybar 等用 Nerd Font 字形渲染图标，缺了
# 图标就显示成方框。从 nerd-fonts 官方 release 下载带图标的版本装到用户字体目录
# （download_gh 自动带 GitHub 代理回退，CN 可用）。
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
    apply_cargo_mirror
    case "$DISTRO_FAMILY" in
        arch)   install_arch ;;
        rhel)   install_rhel ;;
        debian) install_debian ;;
    esac
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
    log "$(_t "Run './install.sh status' in another terminal to watch progress live." "Run './install.sh status' in another terminal to watch progress live.")"
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

# --- 4.3c build status (./install.sh status, run from another terminal while restore is building) ---

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
    echo -e "   ${DIM}$(_t "or: watch -n 5 ./install.sh status" "or: watch -n 5 ./install.sh status")${NC}"
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
        # provider names are Arch names; remap per family for Debian
        if [ "$DISTRO_FAMILY" = debian ] && [ -n "${DEB_SVC_PROVIDER[$unit]:-}" ]; then
            provider="${DEB_SVC_PROVIDER[$unit]}"
        fi

        # install the provider package if it is missing
        if [ -n "$provider" ] && ! pkg_installed "$provider"; then
            log "$(_t "Installing service provider: " "Installing service provider: ")$provider"
            erc=0
            pm_install "$provider" || erc=$?
            # RHEL family: some providers (power-profiles-daemon, ...) are only in EPEL,
            # not the base repos — enable EPEL once and retry before declaring failure.
            if [ "$erc" -ne 0 ] && [ "$erc" -ne "$DRY_RUN_RC" ] && [ "$DISTRO_FAMILY" = rhel ] \
                && ! rpm -q epel-release >/dev/null 2>&1 && [ ! -f /etc/yum.repos.d/epel.repo ]; then
                log "$(_t "Provider not in base RHEL repos — enabling EPEL and retrying..." "Provider not in base RHEL repos — enabling EPEL and retrying...")"
                pm_install epel-release 2>/dev/null || true
                erc=0
                pm_install "$provider" || erc=$?
            fi
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
    case "$DISTRO_FAMILY" in
        arch)   dm_pkgs="ly";           dm_unit="ly@tty1" ;;
        # deb/rhel: prefer gdm (Ubuntu 26.04+, Fedora, Rocky), fall back to gdm3 (Ubuntu 24.04-, Debian)
        *)      dm_pkgs="gdm";          dm_unit="gdm" ;;
    esac

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
        warn "$(_t "configs/ mirror not found, skipping backup." "configs/ mirror not found, skipping backup.")"
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
                if ensure_rust && exe cargo install --locked --root /usr/local eza 2>/dev/null; then
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

deploy_one() { # $1 = source path, $2 = destination path
    local src="$1" dst="$2" ts="$3"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        log "$(_t "Backup existing: " "Backup existing: ")$dst -> $dst.bak-$ts"
        exe mv "$dst" "$dst.bak-$ts"
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
        warn "$(_t "configs/ mirror not found, skipping deploy." "configs/ mirror not found, skipping deploy.")"
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

        # waybar 去重：niri config 用 spawn-at-startup "waybar" 时，只保留 niri 这一个启动
        # 来源，彻底清除 systemd 侧的 waybar.service（无论文件在用户/系统 user 目录、有无
        # enable 链接），并杀掉运行中残留的 waybar 进程——否则开机 niri spawn 一个 +
        # 残留 systemd/手动实例 = 两个 waybar。
        if [ -f "$HOME_DIR/.config/niri/config.kdl" ] \
            && grep -q 'spawn-at-startup.*"waybar"' "$HOME_DIR/.config/niri/config.kdl" 2>/dev/null; then
            log "$(_t "niri spawns waybar at startup — removing duplicate waybar (systemd + running)" "niri spawns waybar at startup — removing duplicate waybar (systemd + running)")"
            as_user systemctl --user disable --now waybar.service 2>/dev/null || true
            rm -f "$HOME_DIR/.config/systemd/user/default.target.wants/waybar.service" \
                  "$HOME_DIR/.config/systemd/user/graphical-session.target.wants/waybar.service" \
                  "$HOME_DIR/.config/systemd/user/waybar.service" \
                  /etc/systemd/user/default.target.wants/waybar.service \
                  /etc/systemd/user/waybar.service 2>/dev/null || true
            as_user systemctl --user daemon-reload 2>/dev/null || true
            # 杀掉运行中的 waybar（无论来源）；重启后 niri 会重新 spawn 唯一的一个。
            # root 下直接对目标用户进程 pkill，避免残留实例与新实例并存。
            pkill -u "$TARGET_USER" -x waybar 2>/dev/null || true
            sleep 1
            log "$(_t "Killed running waybar instances (niri will spawn one on next login)" "Killed running waybar instances (niri will spawn one on next login)")"
        fi

        # 光标拖影：QEMU/KVM 虚拟机在合成器下常见（无硬件 cursor plane / 软件渲染）。
        # guest 侧无法根本解决——提示用户调整 VM 显示配置（virtio-gpu + 3D 加速）。
        # 注意：绝不在此处向 config.kdl 追加内容（曾因追加破坏 KDL 语法导致快捷键/壁纸全失效）。
        if command -v systemd-detect-virt >/dev/null 2>&1; then
            case "$(systemd-detect-virt 2>/dev/null)" in
                qemu|kvm)
                    warn "$(_t "检测到 QEMU/KVM 虚拟机：若鼠标光标仍有拖影，请在 VM 配置把显卡设为 virtio-gpu 并开启 3D 加速（gl=on），或改用 spice 显示协议（spice-vdagent 已安装）。" "QEMU/KVM VM detected: if the mouse cursor still has ghosting/trailing, set the VM display to virtio-gpu with 3D acceleration (gl=on), or use the SPICE display protocol (spice-vdagent is installed).")"
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
    # set zsh as the default shell (if zsh is installed and is not already the shell)
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

    # --- 4) polkit agent path per family (Arch: /usr/lib; Debian/RHEL: /usr/libexec) ---
    if [ "$DISTRO_FAMILY" != arch ] && [ -f "$niri_cfg" ] && grep -q 'polkit-gnome-authentication-agent-1' "$niri_cfg" 2>/dev/null; then
        if grep -q '/usr/lib/polkit-gnome-authentication-agent-1' "$niri_cfg"; then
            sed -i 's#/usr/lib/polkit-gnome-authentication-agent-1#/usr/libexec/polkit-gnome-authentication-agent-1#g' "$niri_cfg"
            log "$(_t "polkit agent path adapted to /usr/libexec (Debian/RHEL layout)" "polkit agent path adapted to /usr/libexec (Debian/RHEL layout)")"
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
        if [ "$DISTRO_FAMILY" = arch ]; then
            local m
            m=$(pacman -T "${all_sel[@]}" 2>/dev/null) && true
            [ -n "$m" ] && mapfile -t missing <<< "$m"
        else
            local p name
            for p in "${all_sel[@]}"; do
                [ -n "${PIP_PKGS[$p]:-}" ] && continue
                # niri/awww/satty/xwayland-satellite may be installed via dnf/prebuilt/source/cargo; check by PATH (common to Debian/RHEL)
                case "$p" in
                    niri|awww|satty|xwayland-satellite)
                        command -v "$p" >/dev/null 2>&1 || missing+=("$p")
                        continue
                        ;;
                    rime-ice-pinyin-git)
                        [ -f "$HOME_DIR/.local/share/fcitx5/rime/rime_ice.schema.yaml" ] || missing+=("rime-ice")
                        continue
                        ;;
                esac
                if [ "$DISTRO_FAMILY" = rhel ]; then
                    [ -n "${RHEL_MANUAL[$p]:-}" ] && continue
                    name="${RHEL_MAP[$p]:-$p}"
                else
                    [ -n "${DEB_MANUAL[$p]:-}" ] && continue
                    name="${DEB_MAP[$p]:-$p}"
                fi
                pkg_installed "$name" || missing+=("$name")
            done
        fi
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

    # Config mirror check: configs/ must exist in the repo (collect with ./install.sh collect-config)
    local _snap_missing=0
    [ -d "$BASE_DIR/configs" ] || _snap_missing=1
    if [ "$_snap_missing" -eq 1 ]; then
        warn "$(_t "configs/ not found in " "configs/ not found in ") $BASE_DIR$(_t " — no desktop config will be deployed (niri will run with default/empty config). Collect it on your reference machine with './install.sh collect-config' and push the repo." " — no desktop config will be deployed (niri will run with default/empty config). Collect it on your reference machine with './install.sh collect-config' and push the repo.")"
        if [ "$DRY_RUN" -eq 0 ] && ! confirm "$(_t "configs/ missing — continue without deploying config? [Y/n] (default Y):" "configs/ missing — continue without deploying config? [Y/n] (default Y):")" "Y" 30; then
            error "$(_t "Aborted: run ./install.sh collect-config on the reference machine, commit configs/, push, then rerun." "Aborted: run ./install.sh collect-config on the reference machine, commit configs/, push, then rerun.")"
            exit 1
        fi
    fi

    # update the system first (a fresh machine has a stale package db, so installing fzf directly may fail)
    stage_preflight
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
        case "$DISTRO_FAMILY" in
            debian) dpkg -l 2>/dev/null | grep -iE 'gdm|niri|rust|accountsservice|hypr' ;;
            rhel)   rpm -qa 2>/dev/null | grep -iE 'gdm|niri|rust|accountsservice|hypr' ;;
            arch)   pacman -Q 2>/dev/null | grep -iE 'gdm|niri|rust|accountsservice|hypr' ;;
        esac
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
eilNiri install.sh v$SCRIPT_VERSION — niri desktop environment replication tool

Usage:
  ./install.sh collect-config          collect this machine's config into configs/ (normal user)
  ./install.sh restore [--dry-run]      restore desktop on new system (root)
  ./install.sh status                   show background build progress (run from another terminal)
  ./install.sh rollback                 rollback config from backup (root)
  ./install.sh restore-system           re-enable system components disabled by restore (root)
  ./install.sh --help                   show this help

Options:
  --dry-run      print plan only, no actual install/enable/deploy

Environment:
  EILNIRI_KEEP_DM=1    keep existing display manager unchanged
  EILNIRI_KEEP_SYS=1   skip disabling other-DE components during restore
  EILNIRI_GH_PROXY     space-separated GitHub proxy URLs (default: ghfast.top gh-proxy.com ghproxy.net gh.llkk.cc)

Workflow:
  1. On your reference machine:  ./install.sh collect-config
  2. Sync the repo (git push / USB): git add configs && git commit && git push
  3. On new machine (Arch/RHEL/Debian): sudo ./install.sh restore
     - niri/awww compile in background:  ./install.sh status   (live progress)
     - watch logs:                       tail -f ~/.local/state/eilNiri/{niri,awww}-build.log
  4. Rollback config:            sudo ./install.sh rollback
  5. Re-enable other-DE comps:   sudo ./install.sh restore-system
EOF
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            collect-config|restore|rollback|status|restore-system) MODE="$arg" ;;
            --dry-run)      DRY_RUN=1 ;;
            -h|--help)      usage; exit 0 ;;
            *) error "$(_t "Unknown argument: " "Unknown argument: ") $arg"; usage; exit 1 ;;
        esac
    done

    case "$MODE" in
        collect-config)  collect_config ;;
        restore)         do_restore ;;
        status)          do_status ;;
        rollback)        do_rollback ;;
        restore-system)  do_restore_system ;;
        *)               usage; exit 1 ;;
    esac
}

main "$@"
