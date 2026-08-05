#!/usr/bin/env bash
# ==============================================================================
# eilNiri - install.sh
#
#   Collects this machine's niri desktop suite (packages + desktop config +
#   system services) into a snapshot, then reproduces it one-click on a fresh
#   Arch / RHEL / Debian family system.
#
#   Usage:
#     ./install.sh export  [--keep-typos]   create snapshot (normal user, read-only)
#     ./install.sh restore [--dry-run]      restore on new system (root)
#     ./install.sh rollback                 rollback config from snapshot (root)
#     ./install.sh --help
#
#   Snapshot outputs (export generates them next to this script):
#     pkglist/official.txt   official repo packages
#     pkglist/aur.txt        AUR packages
#     pkglist/services.txt   enabled system services (format: "unit provider")
#     config/                desktop config mirror
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
    [core]="niri waybar mako fuzzel kitty polkit-gnome xwayland-satellite xdg-desktop-portal-gnome wl-clipboard libnotify zsh"
    [lock]="hyprlock hypridle"
    [wallpaper]="awww waypaper"
    [clip]="copyq satty"
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
CONFIG_DIRS=(niri waybar mako kitty hypr copyq satty waypaper fcitx5 fcitx environment.d xdg-desktop-portal gtk-3.0 gtk-4.0 fontconfig)
CONFIG_FILES=(.pam_environment)

# service -> provider package mapping (filtered by is-enabled during export and written to services.txt)
SVC_ORDER=(bluetooth.service libvirtd.service power-profiles-daemon.service)
declare -A SVC_PROVIDER=(
    [bluetooth.service]=bluez
    [libvirtd.service]=libvirt
    [power-profiles-daemon.service]=power-profiles-daemon
)
# Debian-family service provider names (export snapshot records Arch names; remapped per family on restore)
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
    [ly]="Only available on Arch; the script auto-installs lightdm on RHEL instead"
)
# RHEL family: extra hint when dnf install fails (available in Fedora official repo, but not on Rocky/Alma/CentOS Stream)
declare -A RHEL_FAIL_HINT=(
    [hyprlock]="Available in the Fedora official repo (dnf install hyprlock); on Rocky/Alma/CentOS try EPEL / Copr, or install the RPM from the Fedora repo manually"
    [hypridle]="Available in the Fedora official repo (dnf install hypridle); on Rocky/Alma/CentOS try EPEL / Copr, or install the RPM from the Fedora repo manually"
    [xwayland-satellite]="Available in the Fedora official repo (dnf install xwayland-satellite); on Rocky/Alma/CentOS try EPEL / Copr or build manually"
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
    [polkit-gnome]=polkit-gnome
)
# Packages with no official .deb -> go to the "manual install" report (value = reason/advice)
# (awww/satty handled by install_awww / install_satty, rime-ice by install_rime_ice)
declare -A DEB_MANUAL=(
    [ly]="No ly package on Debian/Ubuntu; the script auto-installs lightdm instead"
)
# Debian family: extra hint when apt install fails (not in repo but may have an alternative)
declare -A DEB_FAIL_HINT=(
    [hyprlock]="Installable on Debian 13 via trixie-backports (apt-get install -t trixie-backports hyprlock); already in Ubuntu 26.04+ repos; otherwise build manually"
    [hypridle]="Installable on Debian 13 via trixie-backports (apt-get install -t trixie-backports hypridle); already in Ubuntu 26.04+ repos; otherwise build manually"
    [xwayland-satellite]="Not in Debian/Ubuntu stable repos; needs sid/testing or manual build"
)
# Packages installable via pip as a fallback (common to Arch/RHEL/Debian)
declare -A PIP_PKGS=(
    [waypaper]=waypaper
)

# Summary report collectors
INSTALLED_PKGS=() SKIPPED_PKGS=() FAILED_PKGS=() MANUAL_ITEMS=() ENABLED_SVCS=()
DRY_PKGS=() DRY_SVCS=()  # items "that would be executed" in dry-run mode; kept separate to avoid inflated counts

# ==============================================================================
# 3. export mode — collect snapshot (run as normal user; only scan+copy, no system changes)
# ==============================================================================

do_export() {
    init_logger
    if [ "$EUID" -eq 0 ]; then
        error "$(_t "export must run as normal user (needs ~/.config), do not use sudo." "export must run as normal user (needs ~/.config), do not use sudo.")"
        exit 1
    fi
    # The snapshot pkglist is built from pacman; export only makes sense on the Arch reference system.
    # On Ubuntu/RHEL the same script still works, but you must get the snapshot from an Arch machine.
    detect_distro
    if [ "$DISTRO_FAMILY" != arch ]; then
        error "$(_t "export must run on an Arch-based system (snapshot pkglist uses pacman). Restore works on Arch/RHEL/Debian (Ubuntu), export does not." "export must run on an Arch-based system (snapshot pkglist uses pacman). Restore works on Arch/RHEL/Debian (Ubuntu), export does not.")"
        exit 1
    fi

    local SNAP_PKGLIST="$BASE_DIR/pkglist"
    local SNAP_CONFIG="$BASE_DIR/config"

    section "Export" "$(_t "Collect Niri Suite Snapshot" "Collect Niri Suite Snapshot")"
    info_kv "$(_t "Snapshot Dir" "Snapshot Dir")" "$BASE_DIR"

    # --- 3.1 package list ---
    log "$(_t "Scanning installed niri suite packages..." "Scanning installed niri suite packages...")"
    mkdir -p "$SNAP_PKGLIST"
    : > "$SNAP_PKGLIST/official.txt"

    local missing=()
    for g in "${GROUP_ORDER[@]}"; do
        for raw in ${GROUP_PKGS[$g]:-}; do
            if ! pacman -Qq "$raw" &>/dev/null; then
                missing+=("$raw")
                continue
            fi
            echo "$raw" >> "$SNAP_PKGLIST/official.txt"
        done
    done
    sort -u -o "$SNAP_PKGLIST/official.txt" "$SNAP_PKGLIST/official.txt"
    info_kv "$(_t "Pkglist" "Pkglist")" "$(wc -l < "$SNAP_PKGLIST/official.txt") packages"
    if [ ${#missing[@]} -gt 0 ]; then
        warn "$(_t "The following packages are not installed, not written to snapshot:" "The following packages are not installed, not written to snapshot:")${missing[*]}"
    fi

    # --- 3.2 service list ---
    log "$(_t "Scanning enabled system services..." "Scanning enabled system services...")"
    : > "$SNAP_PKGLIST/services.txt"
    for unit in "${SVC_ORDER[@]}"; do
        if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            echo "$unit ${SVC_PROVIDER[$unit]}" >> "$SNAP_PKGLIST/services.txt"
            log "  $(_t "[enabled]" "[enabled]") $unit"
        fi
    done
    info_kv "$(_t "Services" "Services")" "$(wc -l < "$SNAP_PKGLIST/services.txt") services"

    # --- 3.3 config mirror ---
    log "$(_t "Copying desktop config (whitelist)..." "Copying desktop config (whitelist)...")"
    rm -rf "$SNAP_CONFIG"
    mkdir -p "$SNAP_CONFIG/.config"

    for d in "${CONFIG_DIRS[@]}"; do
        if [ -d "$HOME/.config/$d" ]; then
            cp -r "$HOME/.config/$d" "$SNAP_CONFIG/.config/$d"
            log "  $(_t "[config]" "[config]") ~/.config/$d"
        else
            warn "  $(_t "[skip]" "[skip]") ~/.config/$d does not exist"
        fi
    done
    for f in "${CONFIG_FILES[@]}"; do
        if [ -f "$HOME/$f" ]; then
            cp "$HOME/$f" "$SNAP_CONFIG/$f"
            log "  $(_t "[config]" "[config]") ~/$f"
        fi
    done

    # Remove useless cache directories (not part of snapshot)
    rm -rf "$SNAP_CONFIG/.config/mako/__pycache__" 2>/dev/null

    # --- 3.4 fix known typos in the snapshot copy (never touch live config) ---
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
            warn "$(_t "Fixed typos in snapshot copy (live config unchanged; --keep-typos to disable):" "Fixed typos in snapshot copy (live config unchanged; --keep-typos to disable):")"
            for fx in "${fixed[@]}"; do echo -e "     ${H_YELLOW}· $fx${NC}"; done
            write_log "FIX" "${fixed[*]}"
        fi
    fi

    # --- 3.5 capture & fix niri-session (systemd import-environment deprecation warning) ---
    local NIRI_SESSION="$SNAP_CONFIG/.local/bin/niri-session"
    local NIRI_DESKTOP="$SNAP_CONFIG/.local/share/applications/niri.desktop"
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

    section "$(_t "Export Done" "Export Done")" "$(_t "Snapshot Created" "Snapshot Created")"
    info_kv "$(_t "Pkglist" "Pkglist")" "$SNAP_PKGLIST/"
    info_kv "$(_t "Config Mirror" "Config Mirror")" "$SNAP_CONFIG/"
    log "Next: copy the eilNiri directory to the new machine and run ${BOLD}sudo ./install.sh restore${NC}"
}

# ==============================================================================
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

as_user() {
    runuser -u "$TARGET_USER" -- "$@"
}

# Resume support (dry-run does not read/write the progress file)
stage_done() { [ "$DRY_RUN" -eq 1 ] && return 1; grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
stage_mark() { [ "$DRY_RUN" -eq 1 ] && return 0; echo "$1" >> "$STATE_FILE"; }

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
                pm_install curl tar
            fi
            ;;
    esac
    success "$(_t "System ready." "System ready.")"
    stage_mark preflight
}

# --- 4.2 app selection ---

REPO_UNIVERSE=()

load_app_universe() {
    # Prefer the export snapshot list (user-editable), otherwise fall back to the built-in authoritative list
    local off="$BASE_DIR/pkglist/official.txt"
    if [ -s "$off" ]; then
        log "$(_t "Using snapshot pkglist: pkglist/" "Using snapshot pkglist: pkglist/")"
        mapfile -t REPO_UNIVERSE < <(sed '/^\s*$/d' "$off")
    else
        log "$(_t "No snapshot pkglist, using built-in list." "No snapshot pkglist, using built-in list.")"
        local g raw
        for g in "${GROUP_ORDER[@]}"; do
            for raw in ${GROUP_PKGS[$g]:-}; do
                REPO_UNIVERSE+=("$raw")
            done
        done
    fi
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
            elif [ -n "${RHEL_FAIL_HINT[$p]:-}" ]; then
                MANUAL_ITEMS+=("$name — not available in repo. ${RHEL_FAIL_HINT[$p]}")
            else
                FAILED_PKGS+=("dnf:$name")
            fi
        fi
    done
}

# --- niri install (common to Debian family and non-Fedora RHEL family; these repos have no niri) ---
# Strategy: 1) official prebuilt binary (if this release provides it) 2) offline cargo build from the official vendored source archive 3) manual report
# Fedora's official repo already has niri, so dnf succeeds and this is never reached
NIRI_GH="https://github.com/niri-wm/niri/releases"

# niri system build dependencies (Debian/Ubuntu names, per the official niri Packaging docs)
NIRI_BUILD_DEPS=(build-essential pkg-config curl tar \
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
    if command -v cargo &>/dev/null && cargo --version 2>/dev/null | awk -F'[ .]' '{ if ($2 < 1 || ($2 == 1 && $3 < 85)) exit 1 }'; then
        return 0
    fi
    log "$(_t "System Rust too old or missing, installing rustup toolchain..." "System Rust too old or missing, installing rustup toolchain...")"
    if ! command -v rustup &>/dev/null; then
        exe bash -c 'curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable' || return 1
    fi
    export PATH="$HOME/.cargo/bin:$PATH"
    command -v cargo >/dev/null
}

install_niri_binary() {
    if command -v niri >/dev/null 2>&1; then
        SKIPPED_PKGS+=("niri (already installed)")
        return 0
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

    # Resolve the latest version (GitHub API)
    local ver url tmp work srcdir d
    ver=$(curl -fsSL https://api.github.com/repos/niri-wm/niri/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/')
    if [ -z "$ver" ]; then
        MANUAL_ITEMS+=("niri — could not fetch latest version (network or GitHub API restricted), install manually: $NIRI_GH")
        return 1
    fi
    tmp=$(mktemp)
    work=$(mktemp -d)
    register_temp_path "$tmp"
    register_temp_path "$work"

    # --- Strategy 1: official prebuilt binary (only some releases provide it; instant install if publishing resumes) ---
    url="$NIRI_GH/download/v${ver}/niri-${ver}-${arch}-linux-gnu.tar.xz"
    if curl -fsL --retry 2 -o "$tmp" "$url" 2>/dev/null; then
        log "$(_t "Downloading niri $ver ($arch) official prebuilt binary..." "Downloading niri $ver ($arch) official prebuilt binary...")"
        if tar xJf "$tmp" -C "$work" 2>/dev/null && [ -d "$work/bin" ]; then
            exe install -Dm755 -t /usr/local/bin "$work"/bin/*
            [ -d "$work/share" ] && exe cp -r "$work"/share/. /usr/local/share/
            if [ -x /usr/local/bin/niri ]; then
                INSTALLED_PKGS+=("niri (official prebuilt $ver)")
                success "$(_t "niri $ver installed" "niri $ver installed")"
                return 0
            fi
        fi
        warn "$(_t "Prebuilt package unusable, falling back to source build." "Prebuilt package unusable, falling back to source build.")"
    fi

    # --- Strategy 2: offline build from the official vendored source archive (published by upstream for offline builds) ---
    log "$(_t "No prebuilt binary for this version, building from official vendored source (10-20 min)..." "No prebuilt binary for this version, building from official vendored source (10-20 min)...")"
    url="$NIRI_GH/download/v${ver}/niri-${ver}-vendored-dependencies.tar.xz"
    if ! curl -fL --retry 3 -o "$tmp" "$url" 2>/dev/null; then
        MANUAL_ITEMS+=("niri — source archive download failed, install manually: $NIRI_GH")
        return 1
    fi
    if ! tar xJf "$tmp" -C "$work" 2>/dev/null; then
        MANUAL_ITEMS+=("niri — source archive extraction failed, install manually: $url")
        return 1
    fi

    # Locate the source root (top level may be the source directly or wrapped in a version dir)
    srcdir="$work"
    for d in "$work"/*/; do
        [ -f "$d/Cargo.toml" ] && { srcdir="$d"; break; }
    done

    # Install build dependencies + Rust toolchain
    if ! ensure_rust; then
        MANUAL_ITEMS+=("niri — Rust toolchain install failed, build manually: $NIRI_GH")
        return 1
    fi
    local bdeps_rc=0
    if [ "$DISTRO_FAMILY" = debian ]; then
        exe apt-get install -y "${NIRI_BUILD_DEPS[@]}" || bdeps_rc=$?
    else
        exe dnf install -y "${NIRI_BUILD_DEPS_RHEL[@]}" || bdeps_rc=$?
    fi
    if [ "$bdeps_rc" -ne 0 ]; then
        MANUAL_ITEMS+=("niri — build dependencies install failed, build manually: $NIRI_GH")
        return 1
    fi

    log "$(_t "Building niri offline (vendored deps), please wait..." "Building niri offline (vendored deps), please wait...")"
    if ! (cd "$srcdir" && cargo build --release); then
        MANUAL_ITEMS+=("niri — build failed, build manually or wait for an official prebuilt: $NIRI_GH")
        return 1
    fi

    # Install (following the file layout from the official Packaging docs)
    if [ -f "$srcdir/target/release/niri" ]; then
        exe install -Dm755 "$srcdir/target/release/niri" /usr/local/bin/niri
        exe install -Dm755 "$srcdir/resources/niri-session" /usr/local/bin/niri-session 2>/dev/null || true
        exe install -Dm644 "$srcdir/resources/niri.desktop" /usr/local/share/wayland-sessions/niri.desktop 2>/dev/null || true
        exe install -Dm644 "$srcdir/resources/niri-portals.conf" /usr/local/share/xdg-desktop-portal/niri-portals.conf 2>/dev/null || true
        INSTALLED_PKGS+=("niri (source build $ver)")
        success "$(_t "niri $ver built from source" "niri $ver built from source")"
        return 0
    fi

    MANUAL_ITEMS+=("niri — build output missing, install manually: $NIRI_GH")
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

    # build deps (wayland protocol XML via pkg-config is required by upstream); runtime libs best effort
    local bdeps_rc=0
    if [ "$DISTRO_FAMILY" = debian ]; then
        exe apt-get install -y git libwayland-dev wayland-protocols || bdeps_rc=$?
        exe apt-get install -y libdav1d6 liblz4-1 2>/dev/null || true
    else
        exe dnf install -y git wayland-devel wayland-protocols-devel || bdeps_rc=$?
        exe dnf install -y dav1d lz4 2>/dev/null || true
    fi
    if [ "$bdeps_rc" -ne 0 ]; then
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

    log "$(_t "Building awww via cargo (about 5 min)..." "Building awww via cargo (about 5 min)...")"
    if ! (cd "$work/awww" && cargo build --release --workspace); then
        MANUAL_ITEMS+=("awww — build failed, build manually: $AWWW_REPO")
        return 1
    fi

    # install every produced binary (awww client, awww-daemon, possibly more)
    local b found=0
    for b in "$work"/awww/target/release/awww*; do
        [ -x "$b" ] && [ -f "$b" ] || continue
        exe install -Dm755 "$b" /usr/local/bin/"$(basename "$b")"
        found=1
    done
    if [ "$found" -eq 1 ] && [ -x /usr/local/bin/awww ]; then
        INSTALLED_PKGS+=("awww (cargo build)")
        success "$(_t "awww built from source" "awww built from source")"
        return 0
    fi
    MANUAL_ITEMS+=("awww — build output missing, build manually: $AWWW_REPO")
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
    local ver url tmp work b satty_bin
    ver=$(curl -fsSL https://api.github.com/repos/Satty-org/Satty/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/')
    if [ -n "$ver" ]; then
        tmp=$(mktemp)
        work=$(mktemp -d)
        register_temp_path "$tmp"
        register_temp_path "$work"
        url="$SATTY_GH/download/v${ver}/satty-${arch}-unknown-linux-gnu.tar.gz"
        if curl -fsL --retry 3 -o "$tmp" "$url" 2>/dev/null && tar xzf "$tmp" -C "$work" 2>/dev/null; then
            log "$(_t "Downloading satty $ver official prebuilt binary..." "Downloading satty $ver official prebuilt binary...")"
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
                INSTALLED_PKGS+=("satty (official prebuilt $ver)")
                success "$(_t "satty $ver installed" "satty $ver installed")"
                return 0
            fi
        fi
        warn "$(_t "Prebuilt satty download failed, falling back to cargo." "Prebuilt satty download failed, falling back to cargo.")"
    fi

    # --- Strategy 2: cargo install (crates.io) ---
    local bdeps_rc=0
    if [ "$DISTRO_FAMILY" = debian ]; then
        exe apt-get install -y build-essential pkg-config libgtk-4-dev libadwaita-1-dev librsvg2-dev || bdeps_rc=$?
    else
        exe dnf install -y gcc pkgconf-pkg-config gtk4-devel libadwaita-devel librsvg2-devel || bdeps_rc=$?
    fi
    if [ "$bdeps_rc" -ne 0 ]; then
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
# No package exists outside Arch; upstream ships plain config files, so deploying is just
# cloning https://github.com/iDvel/rime-ice and copying it into the user's fcitx5 rime dir.
RIME_ICE_REPO="https://github.com/iDvel/rime-ice"

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
    if ! command -v git &>/dev/null; then
        pm_install git || { MANUAL_ITEMS+=("rime-ice — git missing, deploy manually: $RIME_ICE_REPO"); return 1; }
    fi

    local work item b
    work=$(mktemp -d)
    register_temp_path "$work"
    log "$(_t "Cloning rime-ice dictionary..." "Cloning rime-ice dictionary...")"
    if ! exe git clone --depth 1 "$RIME_ICE_REPO" "$work/rime-ice" 2>/dev/null; then
        MANUAL_ITEMS+=("rime-ice — git clone failed (network or GitHub blocked), deploy manually: $RIME_ICE_REPO")
        return 1
    fi

    exe mkdir -p "$dest"
    for item in "$work/rime-ice"/*; do
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
    MANUAL_ITEMS+=("rime-ice — deploy failed, do it manually: git clone $RIME_ICE_REPO $dest")
    return 1
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
            if [ -n "${DEB_FAIL_HINT[$p]:-}" ]; then
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
    case "$DISTRO_FAMILY" in
        arch)   install_arch ;;
        rhel)   install_rhel ;;
        debian) install_debian ;;
    esac
    stage_mark apps
}

# --- 4.4 system services ---

stage_services() {
    if stage_done services; then
        log "$(_t "Service stage done, skipping." "Service stage done, skipping.")"
        return
    fi
    local svc_file="$BASE_DIR/pkglist/services.txt"
    if [ ! -s "$svc_file" ]; then
        warn "$(_t "services.txt not found, skipping." "services.txt not found, skipping.")"
        return
    fi

    section "$(_t "Services" "Services")" "$(_t "Select services to enable" "Select services to enable")"
    local selected
    selected=$(awk '{print $1 "\tprovider: " $2}' "$svc_file" | \
        fzf_multi " Select services to enable ") || {
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
        provider=$(grep -m1 "^$unit " "$svc_file" | awk '{print $2}')
        # provider names in the export snapshot are Arch names; remap per family for Debian
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
#   Debian/RHEL: lightdm + lightdm-gtk-greeter (available in Ubuntu/Debian/Fedora repos)
# If any known DM is already installed it is kept (and enabled if it wasn't).

stage_dm() {
    if stage_done dm; then return; fi

    section "$(_t "Display Manager" "Display Manager")" "$(_t "auto (ly / lightdm)" "auto (ly / lightdm)")"
    local known_dms=(gdm sddm lightdm lxdm ly greetd plasma-login-manager lemurs)
    local dm found=""
    for dm in "${known_dms[@]}"; do
        if pkg_installed "$dm"; then found="$dm"; break; fi
    done

    if [ -n "$found" ]; then
        info_kv "$(_t "DM Conflict" "DM Conflict")" "$found" "already installed, keep"
        if [ "$DRY_RUN" -eq 1 ]; then
            log "$(_t "[DRY-RUN] would enable " "[DRY-RUN] would enable ") $found"
            DRY_SVCS+=("$found")
        elif ! systemctl is-enabled --quiet "$found" 2>/dev/null; then
            if exe systemctl enable "$found"; then
                ENABLED_SVCS+=("$found")
            fi
        fi
        stage_mark dm
        return
    fi

    local dm_pkgs dm_unit
    case "$DISTRO_FAMILY" in
        arch)   dm_pkgs="ly";           dm_unit="ly@tty1" ;;
        *)      dm_pkgs="lightdm lightdm-gtk-greeter"; dm_unit="lightdm" ;;
    esac

    if [ "$DRY_RUN" -eq 1 ]; then
        log "$(_t "[DRY-RUN] would install & enable: " "[DRY-RUN] would install & enable: ") $dm_pkgs"
        DRY_PKGS+=("$dm_pkgs")
        DRY_SVCS+=("$dm_unit")
        stage_mark dm
        return
    fi

    if pm_install $dm_pkgs && exe systemctl enable "$dm_unit"; then
        ENABLED_SVCS+=("$dm_unit")
        success "$(_t "Display manager installed & enabled: " "Display manager installed & enabled: ") $dm_pkgs"
    else
        FAILED_PKGS+=("dm:$dm_unit")
        warn "$(_t "Display manager install failed; run niri-session from tty after reboot." "Display manager install failed; run niri-session from tty after reboot.")"
    fi
    stage_mark dm
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
    local snap_cfg="$BASE_DIR/config"
    if [ ! -d "$snap_cfg/.config" ]; then
        warn "$(_t "config/ mirror not found, skipping backup." "config/ mirror not found, skipping backup.")"
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
    local snap="$BASE_DIR/config"
    if [ ! -d "$snap" ]; then
        warn "$(_t "config/ mirror not found, skipping deploy." "config/ mirror not found, skipping deploy.")"
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
        refresh=$(head -1 "$dir/edid" 2>/dev/null | od -An -j12 -N1 -i 2>/dev/null | tr -d ' ')
        [ -z "$refresh" ] && refresh=60
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
                # niri/awww/satty may be installed via dnf/prebuilt/source/cargo; check by PATH (common to Debian/RHEL)
                case "$p" in
                    niri|awww|satty)
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

    section "$(_t "Restore" "Restore")" "$(_t "Restore Niri Desktop" "Restore Niri Desktop")"
    [ "$DRY_RUN" -eq 1 ] && warn "$(_t "DRY-RUN mode: printing plan only, no changes." "DRY-RUN mode: printing plan only, no changes.")"
    show_logo

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
    stage_hardware_adapt
    stage_verify
    # clean the pacman cache to free disk space
    [ "$DISTRO_FAMILY" = arch ] && exe pacman -Sc --noconfirm 2>/dev/null || true
    print_summary
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

# ==============================================================================
# 5. main
# ==============================================================================

usage() {
    cat <<'EOF'
eilNiri install.sh — niri desktop environment replication tool

Usage:
  ./install.sh export  [--keep-typos]   create snapshot (normal user, read-only)
  ./install.sh restore [--dry-run]      restore desktop on new system (root)
  ./install.sh rollback                 rollback from existing snapshot (root)
  ./install.sh --help                   show this help

Options:
  --dry-run      print plan only, no actual install/enable/deploy
  --keep-typos   keep config as-is during export, skip typo fixes

Workflow:
  1. On current Arch machine:   ./install.sh export
  2. Bring the eilNiri dir to new machine (git / USB / rsync)
  3. On new machine (Arch/RHEL/Debian): sudo ./install.sh restore
  4. Rollback config:            sudo ./install.sh rollback
EOF
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            export|restore|rollback) MODE="$arg" ;;
            --dry-run)      DRY_RUN=1 ;;
            --keep-typos)   KEEP_TYPOS=1 ;;
            -h|--help)      usage; exit 0 ;;
            *) error "$(_t "Unknown argument: " "Unknown argument: ") $arg"; usage; exit 1 ;;
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
