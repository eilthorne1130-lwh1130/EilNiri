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
SCRIPT_VERSION="1.8.0"

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
    [core]="niri waybar mako fuzzel kitty polkit-gnome xwayland-satellite xdg-desktop-portal-gnome xdg-desktop-portal-gtk wl-clipboard libnotify zsh zsh-autosuggestions zsh-syntax-highlighting"
    [lock]="hyprlock hypridle"
    [wallpaper]="awww waypaper"
    [clip]="copyq satty grim slurp"
    [media]="playerctl brightnessctl"
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
# libhyprutils-dev & libhyprlang-dev exist on Ubuntu 25.10+ / Debian 13+ universe only;
# apt_install_tolerant handles their absence on older releases (cargo then reports the real error).
HYPR_BUILD_DEPS_DEB=(build-essential cmake pkg-config git libwayland-dev wayland-protocols
    libpango1.0-dev libgbm-dev libdrm-dev libxkbcommon-dev libxcb1-dev
    libhyprutils-dev libhyprlang-dev)
# hyprlock / hypridle system build dependencies (RHEL family names)
HYPR_BUILD_DEPS_RHEL=(gcc gcc-c++ pkgconf-pkg-config git wayland-devel wayland-protocols-devel
    pango-devel mesa-libgbm-devel libdrm-devel libxkbcommon-devel libxcb-devel
    hyprutils-devel hyprlang-devel)

# System components (from other desktop environments) to disable when restoring
# on a multi-DE target machine.  Only masked / hidden, NEVER uninstalled — the user
# can switch back to the other DE at any time.  Each item is existence-checked first
# so it is safe on Arch (most entries won't exist) and RHEL/Debian alike.
# type: autostart  — write ~/.config/autostart/<name> with Hidden=true as override
#       userunit   — systemctl --user mask <name>
#       systemunit — systemctl mask <name>
DISABLE_SYS=(
    # --- notification daemons (would compete with mako) ---
    "userunit|evolution-alarm-notify.service|GNOME notifications"
    "autostart|evolution-alarm-notify.desktop|GNOME notifications"
    "userunit|xfce4-notifyd.service|XFCE notifications"
    "autostart|xfce4-notifyd.desktop|XFCE notifications"
    # --- GNOME settings daemon (media keys / power / sound / clipboard → handled by waybar / power-profiles-daemon) ---
    "autostart|org.gnome.SettingsDaemon.MediaKeys.desktop|GNOME media keys"
    "autostart|org.gnome.SettingsDaemon.Power.desktop|GNOME power"
    "autostart|org.gnome.SettingsDaemon.Sound.desktop|GNOME sound"
    "autostart|org.gnome.SettingsDaemon.Clipboard.desktop|GNOME clipboard"
    "userunit|org.gnome.SettingsDaemon.MediaKeys.service|GNOME media keys"
    # --- misc system services ---
    "systemunit|gnome-remote-desktop.service|GNOME remote desktop"
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
    if exe apt-get install -y "$@" 2>/dev/null; then
        return 0   # whole batch installed
    fi
    # batch failed (at least one name missing) — retry one-by-one so the available ones still install
    local p erc
    for p in "$@"; do
        erc=0
        exe apt-get install -y "$p" 2>/dev/null || erc=$?
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
PROGRESS_VERSION="v11"
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
                if ! exe apt-get update; then
                    warn "$(_t "apt-get update failed, continuing." "apt-get update failed, continuing.")"
                fi
                # Ubuntu: the niri-suite packages (fuzzel, mako-notifier, waybar, fcitx5-rime, hyprlock, ...) live in
                # universe, which is NOT enabled by default on Ubuntu Server/minimal/cloud images. Enable it automatically.
                if [ "$DISTRO_ID" = ubuntu ] && ! apt-cache show mako-notifier >/dev/null 2>&1; then
                    log "$(_t "universe repository not enabled, enabling it..." "universe repository not enabled, enabling it...")"
                    if ! command -v add-apt-repository &>/dev/null; then
                        exe apt-get install -y software-properties-common || warn "$(_t "software-properties-common install failed, universe may stay disabled." "software-properties-common install failed, universe may stay disabled.")"
                    fi
                    if command -v add-apt-repository &>/dev/null; then
                        exe add-apt-repository -y universe || warn "$(_t "add-apt-repository universe failed, packages from universe will not install." "add-apt-repository universe failed, packages from universe will not install.")"
                        exe apt-get update
                    else
                        warn "$(_t "Cannot enable universe automatically; install packages from universe will fail." "Cannot enable universe automatically; install packages from universe will fail.")"
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
                warn "$(_t "No niri package in dnf (common outside Fedora), falling back to official prebuilt/source install..." "No niri package in dnf (common outside Fedora), falling back to official prebuilt/source install...")"
                install_niri_binary
            elif [ "$p" = "xwayland-satellite" ]; then
                warn "$(_t "No xwayland-satellite package in dnf, falling back to cargo install..." "No xwayland-satellite package in dnf, falling back to cargo install...")"
                install_xwayland_satellite
            elif [ -n "${SOURCE_PKGS[$p]:-}" ]; then
                warn "$(_t "No dnf package for " "No dnf package for ") $p, building from source..."
                install_hypr_source "$p" "${SOURCE_PKGS[$p]}"
            elif [ -n "${RHEL_FAIL_HINT[$p]:-}" ]; then
                MANUAL_ITEMS+=("$name — not available in repo. ${RHEL_FAIL_HINT[$p]}")
            else
                FAILED_PKGS+=("dnf:$name")
            fi
        fi
    done
}

# --- GitHub download (official direct; resume + retries + timeouts) ---
CURL_DL_FLAGS=(-fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 1800 -C -)

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
    for proxy in ${EILNIRI_GH_PROXY:-https://ghfast.top/ https://mirror.ghproxy.com/}; do
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
NIRI_BUILD_DEPS=(build-essential cmake pkg-config curl tar \
    libxkbcommon-dev libxkbcommon-x11-dev libwayland-dev wayland-protocols \
    libinput-dev libdisplay-info-dev libudev-dev libseat-dev \
    libgbm-dev libegl1-mesa-dev libgles2-mesa-dev \
    libpipewire-0.3-dev libdbus-1-dev \
    libxcb-composite0-dev libxcb-ewmh-dev libxcb-icccm4-dev libxcb-randr0-dev \
    libxcb-xfixes0-dev libxcb-present-dev libxcb-render-util0-dev libxcb-res0-dev \
    libxcb-shape0-dev libxcb-util-dev libxcb-xkb-dev libxcb-xinerama0-dev)
# niri system build dependencies (RHEL/Fedora names; some need EPEL/CRB — fall back to the manual report when missing)
NIRI_BUILD_DEPS_RHEL=(gcc gcc-c++ pkgconf-pkg-config curl tar \
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
            INSTALLED_PKGS+=("niri (session file repaired from source v$ver)")
            success "$(_t "niri session file repaired" "niri session file repaired")"
            return 0
        fi
    fi
    MANUAL_ITEMS+=("niri — session file repair: extraction failed; create /usr/share/wayland-sessions/niri.desktop manually")
    return 1
}

install_niri_binary() {
    if command -v niri >/dev/null 2>&1; then
        if [ -f /usr/share/wayland-sessions/niri.desktop ] || [ -f /usr/local/share/wayland-sessions/niri.desktop ]; then
            SKIPPED_PKGS+=("niri (already installed)")
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
    if download_gh "$url" "$tmp"; then
        :
    else
        local dlrc=$?
        # flaky networks: one more full pass after a pause before giving up
        log "$(_t "Download failed, retrying once after 10s..." "Download failed, retrying once after 10s...")"
        sleep 10
        if download_gh "$url" "$tmp"; then
            :
        else
            dlrc=$?
            MANUAL_ITEMS+=("niri — source tarball download failed (curl exit code $dlrc via GitHub); install manually: $NIRI_GH")
            return 1
        fi
    fi
    if ! tar xzf "$tmp" -C "$work" 2>/dev/null; then
        MANUAL_ITEMS+=("niri — source archive extraction failed, install manually: $url")
        return 1
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
        local vtmp
        vtmp=$(mktemp)
        register_temp_path "$vtmp"
        url="$NIRI_GH/download/v${ver}/niri-${ver}-vendored-dependencies.tar.xz"
        if download_gh "$url" "$vtmp"; then
            :
        else
            dlrc=$?
            log "$(_t "Vendored deps download failed, retrying once after 10s..." "Vendored deps download failed, retrying once after 10s...")"
            sleep 10
            if download_gh "$url" "$vtmp"; then
                :
            else
                dlrc=$?
                MANUAL_ITEMS+=("niri — vendored dependencies download failed (curl exit code $dlrc); install manually: $NIRI_GH")
                return 1
            fi
        fi
        mkdir -p "$srcdir/vendor"
        if ! tar xJf "$vtmp" -C "$srcdir/vendor" 2>/dev/null || [ ! -d "$srcdir/vendor/vendor" ]; then
            MANUAL_ITEMS+=("niri — vendored dependencies extraction failed; install manually: $NIRI_GH")
            return 1
        fi
        # point cargo at the vendored crates so the build is fully offline
        mkdir -p "$srcdir/.cargo"
        cat > "$srcdir/.cargo/config.toml" <<'EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor/vendor"
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
        apt_install_tolerant "${NIRI_BUILD_DEPS[@]}" || bdeps_rc=$?
        if [ ${#BDEPS_MISSING[@]} -gt 0 ]; then
            warn "$(_t "Some niri build deps unavailable (continuing; cargo will report the real error if a header is still missing):" "Some niri build deps unavailable (continuing; cargo will report the real error if a header is still missing):") ${BDEPS_MISSING[*]}"
        fi
    else
        exe dnf install -y "${NIRI_BUILD_DEPS_RHEL[@]}" || bdeps_rc=$?
    fi
    if [ "$bdeps_rc" -ne 0 ] && [ "$DISTRO_FAMILY" != debian ]; then
        MANUAL_ITEMS+=("niri — build dependencies install failed, build manually: $NIRI_GH")
        return 1
    fi

    # Build in background so the rest of the install (packages/services/config) proceeds meanwhile
    log "$(_t "Building niri in background; continuing install..." "Building niri in background; continuing install...")"
    bg_build_start niri "$srcdir" "$LOG_DIR/niri-build.log" \
        bash -c "cd '$srcdir' && cargo build --release -j $(cargo_jobs)"
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
        apt_install_tolerant git libwayland-dev wayland-protocols liblz4-dev || bdeps_rc=$?
        if [ ${#BDEPS_MISSING[@]} -gt 0 ]; then
            warn "$(_t "Some awww build deps unavailable (continuing):" "Some awww build deps unavailable (continuing):") ${BDEPS_MISSING[*]}"
        fi
        exe apt-get install -y libdav1d6 2>/dev/null || true
    else
        exe dnf install -y git wayland-devel wayland-protocols-devel lz4-devel || bdeps_rc=$?
        exe dnf install -y dav1d lz4 2>/dev/null || true
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
    if ! exe git clone --depth 1 "$AWWW_REPO" "$work/awww" 2>/dev/null; then
        MANUAL_ITEMS+=("awww — git clone failed (network or Codeberg blocked), build manually: $AWWW_REPO")
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
    if download_gh "$url" "$tmp" && tar xzf "$tmp" -C "$work" 2>/dev/null; then
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

    # fcitx5-rime must exist for this to be useful
    if ! pkg_installed fcitx5-rime; then
        MANUAL_ITEMS+=("rime-ice — fcitx5-rime not installed, skip deploy")
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
    if ! download_gh "$RIME_ICE_ZIP_URL" "$zipfile"; then
        MANUAL_ITEMS+=("rime-ice — download failed, deploy manually: $RIME_ICE_REPO")
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
    # build deps: upstream needs clang (bindgen) + xcb-cursor dev headers + git (cargo --git)
    local bdeps_rc=0
    if [ "$DISTRO_FAMILY" = debian ]; then
        apt_install_tolerant git clang libclang-dev libxcb-cursor-dev || bdeps_rc=$?
        if [ ${#BDEPS_MISSING[@]} -gt 0 ]; then
            warn "$(_t "Some xwayland-satellite build deps unavailable (continuing):" "Some xwayland-satellite build deps unavailable (continuing):") ${BDEPS_MISSING[*]}"
        fi
    else
        exe dnf install -y git clang libxcb-cursor-devel || bdeps_rc=$?
    fi
    if [ "$bdeps_rc" -ne 0 ] && [ "$DISTRO_FAMILY" != debian ]; then
        MANUAL_ITEMS+=("xwayland-satellite — build dependencies install failed (git/clang/libxcb-cursor-dev); install manually: $XWS_REPO")
        return 1
    fi
    if ! ensure_rust; then
        MANUAL_ITEMS+=("xwayland-satellite — Rust toolchain install failed; install manually: $XWS_REPO")
        return 1
    fi
    # tee cargo output to a log so failures stay diagnosable
    local logf="$LOG_DIR/xwayland-satellite-build.log"
    log "$(_t "Building xwayland-satellite from GitHub via cargo (about 3 min)..." "Building xwayland-satellite from GitHub via cargo (about 3 min)...")"
    cargo install --git "$XWS_REPO" --locked --root /usr/local xwayland-satellite 2>&1 | tee "$logf"
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

# --- hyprlock / hypridle source build (fallback when no apt/dnf package) ---
# Used for any package listed in SOURCE_PKGS. Clones the upstream repo, installs the
# hyprwm C build deps, runs a foreground cargo build (~3 min), installs the binary to
# /usr/local/bin. For hyprlock it also writes /etc/pam.d/hyprlock (the apt package
# ships one, but a source build does not — without it hyprlock cannot authenticate).
install_hypr_source() { # $1 = pkg name, $2 = repo URL
    local pkg="$1" repo="$2"
    if command -v "$pkg" >/dev/null 2>&1; then
        SKIPPED_PKGS+=("$pkg (already installed)")
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        DRY_PKGS+=("$pkg (cargo source build)")
        return "$DRY_RUN_RC"
    fi

    # build deps (tolerant: libhyprutils-dev/libhyprlang-dev are absent on older releases)
    local _brc=0
    if [ "$DISTRO_FAMILY" = debian ]; then
        apt_install_tolerant "${HYPR_BUILD_DEPS_DEB[@]}" || _brc=$?
        if [ ${#BDEPS_MISSING[@]} -gt 0 ]; then
            warn "$(_t "Some $pkg build deps unavailable (continuing):" "Some $pkg build deps unavailable (continuing):") ${BDEPS_MISSING[*]}"
        fi
    else
        exe dnf install -y "${HYPR_BUILD_DEPS_RHEL[@]}" || _brc=$?
    fi
    if ! ensure_rust; then
        MANUAL_ITEMS+=("$pkg — Rust toolchain install failed, build manually: $repo")
        return 1
    fi

    local work
    work=$(mktemp -d)
    register_temp_path "$work"
    log "$(_t "Cloning " "Cloning ") $pkg ($repo)..."
    if ! exe git clone --depth 1 "$repo" "$work/$pkg" 2>/dev/null; then
        MANUAL_ITEMS+=("$pkg — git clone failed, build manually: $repo")
        return 1
    fi

    local logf="$LOG_DIR/$pkg-build.log"
    log "$(_t "Building " "Building ") $pkg from source (~3 min, log: $logf)..."
    ( cd "$work/$pkg" && cargo build --release ) > "$logf" 2>&1
    local crc=$?
    if [ "$crc" -ne 0 ] || [ ! -x "$work/$pkg/target/release/$pkg" ]; then
        local tailmsg
        tailmsg=$(tail -n 6 "$logf" 2>/dev/null | tr '\n' ' ')
        MANUAL_ITEMS+=("$pkg — build failed ($tailmsg); build manually: $repo")
        warn "$(_t "Build failed: " "Build failed: ") $pkg (see $logf)"
        return 1
    fi

    exe install -Dm755 "$work/$pkg/target/release/$pkg" "/usr/local/bin/$pkg"
    INSTALLED_PKGS+=("$pkg (cargo source build)")
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
        local _has_wp=0
        for _p in ${REPO_SEL[@]+"${REPO_SEL[@]}"}; do
            [ "$_p" = "waypaper" ] && _has_wp=1
        done
        if [ "$_has_wp" -eq 1 ] && [ -f "$HOME_DIR/.config/systemd/user/waypaper.service" ]; then
            log "$(_t "Enabling waypaper user services..." "Enabling waypaper user services...")"
            as_user systemctl --user daemon-reload 2>/dev/null || true
            as_user systemctl --user enable --now waypaper.service waypaper-random.timer 2>/dev/null || true
        fi
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

    section "$(_t "System Cleanup" "System Cleanup")" "$(_t "disabling other-DE components (mask / autostart Hidden)" "disabling other-DE components (mask / autostart Hidden)")"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "$(_t "[DRY-RUN] Would disable system components of other desktop environments." "[DRY-RUN] Would disable system components of other desktop environments.")"
        stage_mark sysdisable
        return
    fi

    local line type name reason _rc _adir _afile _valid any_failed=0
    for line in "${DISABLE_SYS[@]}"; do
        IFS='|' read -r type name reason <<< "$line"
        valid=0
        case "$type" in
            autostart)
                if [ -f "/etc/xdg/autostart/$name" ]; then
                    _adir="$HOME_DIR/.config/autostart"
                    mkdir -p "$_adir"
                    _afile="$_adir/$name"
                    cat > "$_afile" <<ASEOF
[Desktop Entry]
Hidden=true
ASEOF
                    chown -R "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$_afile" 2>/dev/null || true
                    log "$(_t "Disabled autostart: " "Disabled autostart: ")$name — $reason"
                    valid=1
                fi
                ;;
            userunit)
                if as_user systemctl --user list-unit-files "$name" >/dev/null 2>&1; then
                    _rc=0; as_user systemctl --user mask "$name" 2>/dev/null || _rc=$?
                    if [ "$_rc" -eq 0 ]; then
                        log "$(_t "Masked user unit: " "Masked user unit: ")$name — $reason"
                        valid=1
                    fi
                fi
                ;;
            systemunit)
                if systemctl list-unit-files "$name" >/dev/null 2>&1; then
                    _rc=0; systemctl mask "$name" 2>/dev/null || _rc=$?
                    if [ "$_rc" -eq 0 ]; then
                        log "$(_t "Masked system unit: " "Masked system unit: ")$name — $reason"
                        valid=1
                    fi
                fi
                ;;
        esac
        if [ "$valid" -eq 1 ]; then
            echo "$type|$name" >> "$DISABLE_MANIFEST"
        else
            any_failed=1
        fi
    done

    if [ "$any_failed" -eq 0 ]; then
        stage_mark sysdisable
        success "$(_t "System components from other DEs disabled (mask + autostart overrides)." "System components from other DEs disabled (mask + autostart overrides).")"
    else
        warn "$(_t "Some system components could not be disabled; stage not marked complete — rerun retries." "Some system components could not be disabled; stage not marked complete — rerun retries.")"
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
    stage_services
    stage_dm
    stage_backup
    stage_configs
    stage_disable_system
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
  EILNIRI_GH_PROXY     space-separated GitHub proxy URLs (default: ghfast.top mirror.ghproxy.com)

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
