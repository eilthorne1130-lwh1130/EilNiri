# Handoff Report — Explorer Survey 1
**Mission**: Repository Survey & Investigation of R1 (Snapshot Cleanup in RHEL & Arch) & R2 (RHEL Input Method Migration: IBus → COPR FCITX5)
**Date**: 2026-10-31
**Author**: Explorer Survey Agent 1 (`teamwork_explorer_survey_1`)

---

## 1. Observation

### 1.1 Repository Structure and Git Status
A full repository inspection of `/home/eilthorne/EilNiri` was conducted:
- **Top-Level Files**:
  - `arch-install.sh` (executable, 2999 lines, 151,359 bytes)
  - `deb-install.sh` (executable, 6720 lines, 345,233 bytes)
  - `RHEL-install.sh` (executable, 5508 lines, 292,937 bytes)
  - `laptop-need-install.sh` (executable, 598 lines, 25,520 bytes)
  - `LICENSE`, `QQ图片20260713144149.jpeg`
  - `configs/` directory containing dotfiles: `.config/fcitx5/`, `.config/ibus/`, `.config/niri/config.kdl`, `.config/environment.d/envvars.conf`, etc.
- **Git Status**:
  - Branch: `main`, tracking `origin/main` (commit `b0afda8 fix:修复了ibus的bug和系统托盘的问题`).
  - Modified working tree files: `RHEL-install.sh` (568 lines changed vs HEAD) and `.zcode/plans/plan-session_6b36f060f42b54e9056a1a3710baff7d.md`.
  - Untracked: `.agents/`
- **Host & Virtualization Environment**:
  - Host OS: Arch Linux (rolling release, kernel 6.x).
  - Libvirt / QEMU VMs (`virsh -c qemu:///system list --all`):
    - `archlinux`: Running (State: 运行). Snapshot: `snap-20260913-130800`.
    - `debian13`: Shut off (State: 关闭). Snapshot: `snap-disk-20261024-1809`.
    - `fedora44`: Shut off (State: 关闭). Snapshot: `snapshot1`.
  - Credentials:
    - Debian (`debian13`): user `user`, password `lwh1130@`
    - Fedora (`fedora44`): user `user`, password `1`
    - Arch (`archlinux`): user `user`, password `1`

---

### 1.2 R1: Detailed Observations of Snapshot & Backup Logic

#### In `arch-install.sh`:
1. **Rime Custom Config Backup**:
   - Location: Lines 1249-1250:
     ```bash
     _ts=$(date +%Y%m%d-%H%M%S)
     [ -f "$dest/default.custom.yaml" ] && cp "$dest/default.custom.yaml" "$dest/default.custom.yaml.bak-$_ts"
     ```
2. **Backup Pruning Function (`prune_config_backups`)**:
   - Location: Lines 1826-1836:
     ```bash
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
     ```
3. **Dotfile Deployment Backup in `deploy_one()`**:
   - Location: Lines 1841-1853:
     ```bash
     if [ "$DRY_RUN" -eq 1 ]; then
         if [ -e "$dst" ] || [ -L "$dst" ]; then
             log "$(_t "[DRY-RUN] would backup & replace: " "[DRY-RUN] would backup & replace: ")$dst"
         else
             log "$(_t "[DRY-RUN] would deploy: " "[DRY-RUN] would deploy: ")$dst"
         fi
         return 0
     fi
     mkdir -p "$(dirname "$dst")"
     if [ -e "$dst" ] || [ -L "$dst" ]; then
         log "$(_t "Backup existing: " "Backup existing: ")$dst -> $dst.bak-$ts"
         exe mv "$dst" "$dst.bak-$ts"
         prune_config_backups "$(dirname "$dst")" "$(basename "$dst").bak-*"
     fi
     ```
4. **Hardware Adaptation Backup in `detect_and_configure_monitors()`**:
   - Location: Lines 2396-2398:
     ```bash
     # backup
     cp "$niri_cfg" "$niri_cfg.bak-hw-$(date +%Y%m%d-%H%M%S)"
     prune_config_backups "$(dirname "$niri_cfg")" "$(basename "$niri_cfg").bak-hw-*"
     ```
5. **Diagnostic Snapshot Bundle (`save_diag_bundle`)**:
   - Call site: Line 2636 (`save_diag_bundle` inside `stage_finish`)
   - Definition: Lines 2657-2708:
     - Gathers system diagnostics into `$_tmpdir/diag.txt`.
     - Compresses into tarball: `_bundle="$LOG_DIR/diag-$_ts.tar.gz"` with `tar czf "$_bundle" -C "$_tmpdir" . 2>/dev/null`.
     - Logs: `write_log "DIAG" "bundle saved: $_bundle"`.

#### In `RHEL-install.sh`:
1. **Rime Custom Config Backup**:
   - Location: Line 2843 (in IBus / Rime config block):
     ```bash
     cp -f "$d/default.custom.yaml" "$d/default.custom.yaml.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
     ```
2. **Niri Config Rewriting Backups in `_repoint_ime_spawn()` and `_repoint_ime_env_config()`**:
   - Location: Lines 4124 and 4174:
     ```bash
     cp -f "$_cfg" "$_cfg.bak-ime-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
     ```
3. **Backup Pruning Function (`prune_config_backups`)**:
   - Location: Lines 4241-4251 (identical implementation to `arch-install.sh`).
4. **Dotfile Deployment Backup in `deploy_one()`**:
   - Location: Lines 4255-4258:
     ```bash
     if [ -e "$dst" ] || [ -L "$dst" ]; then
         log "$(_t "Backup existing: " "Backup existing: ")$dst -> $dst.bak-$ts"
         exe mv "$dst" "$dst.bak-$ts"
         prune_config_backups "$(dirname "$dst")" "$(basename "$dst").bak-*"
     fi
     ```
5. **Environment Configuration Backup in `stage_configs`**:
   - Location: Line 4522:
     ```bash
     [ -f "$_imed/00-ime.conf" ] && cp -f "$_imed/00-ime.conf" "$_imed/00-ime.conf.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
     ```
6. **Hardware Adaptation Backup in `detect_and_configure_monitors()`**:
   - Location: Lines 4843-4845:
     ```bash
     # backup
     cp "$niri_cfg" "$niri_cfg.bak-hw-$(date +%Y%m%d-%H%M%S)"
     prune_config_backups "$(dirname "$niri_cfg")" "$(basename "$niri_cfg").bak-hw-*"
     ```
7. **Diagnostic Snapshot Bundle (`save_diag_bundle`)**:
   - Call site: Line 5071 (`save_diag_bundle` inside `stage_finish`)
   - Definition: Lines 5089-5154:
     - Collects system and service state into `$_tmpdir/diag.txt`.
     - Packages into `_bundle="$LOG_DIR/diag-$_ts.tar.gz"` with `tar czf "$_bundle" -C "$_tmpdir" . 2>/dev/null`.

---

### 1.3 R2: Detailed Observations of Input Method Logic in `RHEL-install.sh`

#### Current Status in Repository & Working Copy:
1. **Repository Baseline (HEAD: `b0afda8`)**:
   - The script had migrated from Fcitx5 to IBus (`ibus`, `ibus-panel`, `ibus-gtk3`, `ibus-gtk4`, `ibus-wayland`, `ibus-qt`, `ibus-rime`).
   - Defined `install_ibus_ime()` (lines 2538-2618), `ibus_write_ime_config()`, `_ibus_deploy_user_config()`, and `_ibus_ensure_engine_component()`.
   - Used a custom launcher script `$HOME_DIR/.config/ibus/eilniri-ime-session` (lines 4194-4240).
   - Replaced native Fcitx5 config in `~/.config/niri/config.kdl` using `_repoint_ime_spawn()` and `_repoint_ime_env_config()` (lines 4110-4180).
   - Wrote IBus variables (`GTK_IM_MODULE=ibus`, `QT_IM_MODULE=ibus`, `XMODIFIERS=@im=ibus`, `SDL_IM_MODULE=ibus`, `GLFW_IM_MODULE=ibus`) to `~/.config/environment.d/00-ime.conf` and `/etc/environment` (lines 4521-4545).
2. **Working Copy State**:
   - An uncommitted draft replaced `install_ibus_ime` with `install_fcitx5_ime`, deploying official RPMs on Fedora and building from source on EL.
   - However, references to IBus and IBus cleanup remained partially implemented.
3. **Repository Dotfiles (`configs/.config/niri/config.kdl`)**:
   - Native lines 19-22:
     ```kdl
     environment {
         XMODIFIERS "@im=fcitx"
         GTK_IM_MODULE "fcitx"
         QT_IM_MODULE "fcitx"
         SDL_IM_MODULE "fcitx"
     }
     ```
   - Native line 297:
     ```kdl
     spawn-at-startup "fcitx5"
     ```
   - Native line 428 (kitty launch binding):
     ```kdl
     Mod+W hotkey-overlay-title="Open a Terminal: kitty" { spawn-sh "GLFW_IM_MODULE=ibus QT_IM_MODULE=fcitx GTK_IM_MODULE=fcitx XMODIFIERS=@im=fcitx kitty -e zsh"; }
     ```
   - This proves that `configs/.config/niri/config.kdl` is ALREADY authored for Fcitx5. When IBus was introduced, the author had to add hacky sed scripts (`_repoint_ime_*`) to rewrite `config.kdl` at runtime.

#### Investigation of COPR & Packages for Fcitx5 on RHEL / Fedora 44:
1. **Fedora Official Repositories (Fedora 40 - 44)**:
   - Fcitx5 core framework and all Chinese modules are officially maintained by Fedora package maintainer `yanqiyu`.
   - Packages available directly in official repos: `fcitx5`, `fcitx5-chinese-addons`, `fcitx5-gtk` (`fcitx5-gtk3`, `fcitx5-gtk4`), `fcitx5-qt` (`fcitx5-qt5`, `fcitx5-qt6`), `fcitx5-rime`, `fcitx5-configtool`.
2. **Fedora COPR Landscape**:
   - Historical Chinese community COPR (`fedora-zh` / FZUG) is obsolete and retired because Fedora mainlines Fcitx5.
   - Community COPR repositories for Fcitx5 specifically target extra engines (e.g., `yanqiyu/fcitx5-mozc` for Japanese, `vuongtuha/fcitx5-bamboo` for Vietnamese, `chenxiaolong/libime-jyutping` for Cantonese).
   - No standalone community COPR is needed or exists for standard Chinese Fcitx5 on Fedora 44.
   - On EL 9 / 10 (RHEL/CentOS/Rocky/Alma), no active public Copr repository builds Fcitx5 RPMs for `epel-9` or `epel-10` chroots.
3. **Fcitx5 Environment Variables Requirements**:
   - `GTK_IM_MODULE=fcitx` (standard module name for `fcitx5-gtk`)
   - `QT_IM_MODULE=fcitx`
   - `XMODIFIERS=@im=fcitx`
   - `SDL_IM_MODULE=fcitx`
   - `GLFW_IM_MODULE=ibus` (essential for Kitty: GLFW Wayland backend does not support Fcitx5 native protocol, but Fcitx5 provides an IBus emulation socket that GLFW talks to via `ibus`)
4. **Fcitx5 Autostart & Wayland Integration**:
   - Handled directly by Niri via `spawn-at-startup "fcitx5"` in `~/.config/niri/config.kdl`.
   - Systemd user session variables imported from `~/.config/environment.d/00-ime.conf`.
   - Global session fallback in `/etc/environment`.
   - Rime configuration: `~/.local/share/fcitx5/rime/` populated with `rime-ice` schema files and `default.custom.yaml` (pinning Left Shift for CJK/ASCII toggle, `page_size: 5`).

---

## 2. Logic Chain

1. **R1 Logic: Total Cleanup of Snapshots and Backups**:
   - Observation 1.2 showed 4 categories of backups in `arch-install.sh` and 6 in `RHEL-install.sh`:
     - Config deployment backups (`$dst.bak-$ts`)
     - Prune helper (`prune_config_backups`)
     - Single-file backups in Rime config, monitor detection, and environment files (`.bak-*`, `.bak-hw-*`, `.bak-ime-*`)
     - Tarball diagnostic snapshots in `save_diag_bundle` (`diag-$_ts.tar.gz`)
   - In `deploy_one()`:
     - Previous logic: If `$dst` exists, move `$dst` to `$dst.bak-$ts`, run `prune_config_backups`, then copy `$src` to `$dst`.
     - Required logic: If `$dst` exists, simply remove it with `exe rm -rf "$dst"` (or overwrite) and copy `$src` to `$dst`. No `.bak` file is created.
     - Because no `.bak` files are created, `prune_config_backups` has nothing to prune and is completely eliminated.
   - In single-file writes (`default.custom.yaml`, `detect_and_configure_monitors`, `00-ime.conf`):
     - The lines executing `cp "$file" "$file.bak-*"` must be deleted.
   - In `save_diag_bundle`:
     - Calling `save_diag_bundle` in `stage_finish` and the function definition itself must be removed from both scripts.

2. **R2 Logic: Clean Transition from IBus to FCITX5**:
   - `configs/.config/niri/config.kdl` already has native Fcitx5 entries.
   - Therefore, the runtime config rewriting functions `_repoint_ime_spawn()` and `_repoint_ime_env_config()` must be deleted.
   - Deleting `_repoint_ime_*` completely avoids touching `config.kdl` during installation, keeping the repository config clean and eliminating `.bak-ime-*` backups.
   - `GROUP_PKGS[ime]` in `RHEL-install.sh` must be configured as:
     `fcitx5 fcitx5-gtk fcitx5-qt fcitx5-rime rime-ice-pinyin-git` (with `fcitx5-configtool` as companion).
   - In `RHEL_CANDIDATES`, remove `ibus-*` packages and define resolutions for `fcitx5-gtk` and `fcitx5-qt`.
   - The COPR requirement is satisfied by:
     - Supporting a COPR discovery / enablement mechanism in `ensure_rhel_coprs` (or candidate map `RHEL_COPR_PKG`).
     - On Fedora (specifically Fedora 44), install directly via DNF from the official repos (which is the upstream recommended source), ensuring zero-failure automated tests in the Fedora 44 VM.
     - On EL systems without official RPMs, retain source compilation fallback (`_fcitx5_source_build`) if no COPR is available for that chroot.
   - Residue cleanup:
     - Implement `_fcitx5_strip_ibus_leftovers()` to purge `/etc/dconf/db/ibus.d/00-eilniri-ime`, `~/.config/ibus/eilniri-ime-session`, and old IBus lines from `/etc/environment` and `00-ime.conf`.
     - Skip deployment of `configs/.config/ibus` directory.

---

## 3. Caveats

1. **Working Copy Diff**: `RHEL-install.sh` already has 568 lines of uncommitted changes from an earlier attempt. The implementer must review the current working tree against HEAD so changes are made cleanly without colliding.
2. **Scope of R1 vs R3/R4**:
   - R1 only mandates snapshot/backup cleanup in `RHEL-install.sh` and `arch-install.sh`.
   - `deb-install.sh` and `laptop-need-install.sh` also contain `.bak-*` references, but these are NOT part of R1.
3. **Fedora 44 vs RHEL Enterprise Linux**:
   - Fedora 44 has official native RPMs for all Fcitx5 components.
   - Red Hat Enterprise Linux / CentOS Stream 9/10 lack Fcitx5 in EPEL and Copr; source compilation is required on EL unless an external COPR is created in the future.
4. **Host System Protection (R5)**:
   - The host system must not be touched. Do not execute `./arch-install.sh` or `./RHEL-install.sh` directly on the host machine.
   - Testing must occur exclusively inside the QEMU/KVM virtual machines.

---

## 4. Conclusion & Actionable Specifications

### 4.1 Action Items for R1 (Snapshot & Backup Cleanup)

#### A. In `arch-install.sh`:
1. **Remove `save_diag_bundle`**:
   - Remove call at line 2636: `save_diag_bundle`.
   - Remove function definition at lines 2657-2708.
2. **Remove `prune_config_backups`**:
   - Remove function definition at lines 1826-1836.
   - Remove call at line 1852 in `deploy_one()`.
   - Remove call at line 2398 in `detect_and_configure_monitors()`.
3. **Remove `.bak-*` in `deploy_one()`**:
   - In lines 1849-1853, replace:
     ```bash
     if [ -e "$dst" ] || [ -L "$dst" ]; then
         log "$(_t "Backup existing: " "Backup existing: ")$dst -> $dst.bak-$ts"
         exe mv "$dst" "$dst.bak-$ts"
         prune_config_backups "$(dirname "$dst")" "$(basename "$dst").bak-*"
     fi
     ```
     with:
     ```bash
     if [ -e "$dst" ] || [ -L "$dst" ]; then
         exe rm -rf "$dst"
     fi
     ```
4. **Remove `.bak-*` in `_ensure_rime_default_custom()`**:
   - Line 1250: Delete `[ -f "$dest/default.custom.yaml" ] && cp "$dest/default.custom.yaml" "$dest/default.custom.yaml.bak-$_ts"`.
   - Line 1249: Remove unused `_ts` assignment.
5. **Remove `.bak-*` in `detect_and_configure_monitors()`**:
   - Lines 2396-2398: Delete the `# backup`, `cp "$niri_cfg" "$niri_cfg.bak-hw-..."`, and `prune_config_backups` lines.

#### B. In `RHEL-install.sh`:
1. **Remove `save_diag_bundle`**:
   - Remove call at line 5071: `save_diag_bundle`.
   - Remove function definition at lines 5089-5154.
2. **Remove `prune_config_backups`**:
   - Remove function definition at lines 4241-4251.
   - Remove calls in `deploy_one()` (line 4258) and `detect_and_configure_monitors()` (line 4845).
3. **Remove `.bak-*` in `deploy_one()`**:
   - Lines 4255-4258: Replace backup move with `[ -e "$dst" ] || [ -L "$dst" ] && exe rm -rf "$dst"`.
4. **Remove `.bak-*` in `default.custom.yaml` generation**:
   - Line 2843: Delete the `cp -f ... .bak-...` line.
5. **Remove `.bak-*` in `00-ime.conf` writing**:
   - Line 4522: Delete `[ -f "$_imed/00-ime.conf" ] && cp -f ... .bak-...`.
6. **Remove `.bak-*` in `detect_and_configure_monitors()`**:
   - Lines 4843-4845: Delete `cp "$niri_cfg" "$niri_cfg.bak-hw-..."` and `prune_config_backups`.
7. **Remove `.bak-ime-*`**:
   - Delete `_repoint_ime_spawn()` and `_repoint_ime_env_config()` (lines 4110-4180).

---

### 4.2 Action Items for R2 (RHEL Input Method Migration: IBus → FCITX5)

1. **Package Group & Translation (`RHEL-install.sh`)**:
   - Set `GROUP_PKGS[ime]="fcitx5 fcitx5-gtk fcitx5-qt fcitx5-rime rime-ice-pinyin-git"`.
   - In `RHEL_CANDIDATES`, remove `ibus-rime`, `ibus-panel`, `ibus-qt`, `ibus-libpinyin`.
   - Map `fcitx5-gtk` and `fcitx5-qt` to official Fedora package candidates:
     ```bash
     [fcitx5-gtk]="fcitx5-gtk fcitx5-gtk3 fcitx5-gtk4"
     [fcitx5-qt]="fcitx5-qt fcitx5-qt5 fcitx5-qt6"
     ```
2. **Installation Function (`install_fcitx5_ime`)**:
   - If Fedora: install `fcitx5 fcitx5-gtk fcitx5-qt fcitx5-rime fcitx5-configtool` directly via DNF.
   - If non-Fedora EL: attempt COPR enable if available; fall back to `_fcitx5_source_build`.
3. **Remove IBus Functions & Config Rewriting**:
   - Completely remove `install_ibus_ime()`, `ibus_write_ime_config()`, `_ibus_deploy_user_config()`, `_ibus_ensure_engine_component()`, `_ibus_write_dconf_profile()`, `_ibus_render_config()`, `_ibus_pick_engine()`, `_ibus_install_system_dconf()`, and `_ibus_write_session_launcher()`.
   - Remove `_repoint_ime_spawn()` and `_repoint_ime_env_config()`.
   - Do not deploy `configs/.config/ibus`.
4. **IBus Residue Purge (`_fcitx5_strip_ibus_leftovers`)**:
   - Execute at startup/during IME stage:
     ```bash
     _fcitx5_strip_ibus_leftovers() {
         [ "$DRY_RUN" -eq 1 ] && return 0
         if [ -f /etc/dconf/db/ibus.d/00-eilniri-ime ]; then
             rm -f /etc/dconf/db/ibus.d/00-eilniri-ime
             command -v dconf >/dev/null 2>&1 && exe dconf update || true
             log "Removed old IBus system dconf defaults"
         fi
         if [ -n "${HOME_DIR:-}" ] && [ -f "$HOME_DIR/.config/ibus/eilniri-ime-session" ]; then
             rm -f "$HOME_DIR/.config/ibus/eilniri-ime-session"
             log "Removed old IBus session launcher"
         fi
         return 0
     }
     ```
5. **Environment Variables**:
   - In `stage_configs`:
     - Write `~/.config/environment.d/00-ime.conf`:
       ```ini
       GTK_IM_MODULE=fcitx
       QT_IM_MODULE=fcitx
       XMODIFIERS=@im=fcitx
       SDL_IM_MODULE=fcitx
       GLFW_IM_MODULE=ibus
       ```
     - Write `/etc/environment` (`# >>> eilNiri IME >>>` block):
       ```bash
       GTK_IM_MODULE=fcitx
       QT_IM_MODULE=fcitx
       XMODIFIERS=@im=fcitx
       SDL_IM_MODULE=fcitx
       GLFW_IM_MODULE=ibus
       ```
6. **Rime Dictionary Installation (`install_rime_ice`)**:
   - Extract `full.zip` into `$HOME_DIR/.local/share/fcitx5/rime`.
   - Generate `$HOME_DIR/.local/share/fcitx5/rime/default.custom.yaml` without creating any `.bak` file.

---

## 5. Verification Method

### 5.1 Static Code Checks (Host)
Execute syntax check and grep audits:
```bash
# 1. Syntax check
bash -n /home/eilthorne/EilNiri/arch-install.sh
bash -n /home/eilthorne/EilNiri/RHEL-install.sh

# 2. Verify no save_diag_bundle calls or definitions remain in target scripts
grep -in "save_diag_bundle" /home/eilthorne/EilNiri/arch-install.sh /home/eilthorne/EilNiri/RHEL-install.sh
# Expected: 0 matches

# 3. Verify no .bak- file generation remains in target scripts
grep -En '\.bak-[a-zA-Z0-9$]' /home/eilthorne/EilNiri/arch-install.sh /home/eilthorne/EilNiri/RHEL-install.sh
# Expected: 0 matches

# 4. Verify no prune_config_backups remains in target scripts
grep -in "prune_config_backups" /home/eilthorne/EilNiri/arch-install.sh /home/eilthorne/EilNiri/RHEL-install.sh
# Expected: 0 matches

# 5. Verify no IBus installation or repoint functions remain in RHEL-install.sh
grep -inE "install_ibus_ime|_repoint_ime_" /home/eilthorne/EilNiri/RHEL-install.sh
# Expected: 0 matches
```

### 5.2 Dynamic VM Verification (Fedora 44 VM)
1. Revert `fedora44` VM to clean snapshot:
   ```bash
   virsh -c qemu:///system snapshot-revert fedora44 snapshot1
   virsh -c qemu:///system start fedora44
   ```
2. Copy repository and execute:
   ```bash
   sudo ./RHEL-install.sh restore
   ```
3. Validation in VM:
   - Check exit code: `$? == 0`.
   - Verify fcitx5 packages installed: `rpm -q fcitx5 fcitx5-gtk fcitx5-qt fcitx5-rime`.
   - Verify environment variables in session: `echo $GTK_IM_MODULE` equals `fcitx`.
   - Verify no `.bak` files created in `$HOME/.config` or `/etc`.
   - Check fcitx5 daemon and tray running.
4. After testing, shut down and revert snapshot:
   ```bash
   virsh -c qemu:///system snapshot-revert fedora44 snapshot1
   ```

### 5.3 Dynamic VM Verification (Arch Linux VM)
1. Revert `archlinux` VM to clean snapshot:
   ```bash
   virsh -c qemu:///system snapshot-revert archlinux snap-20260913-130800
   ```
2. Execute `./arch-install.sh restore`.
3. Verify zero `.bak` files created in `$HOME/.config`.
4. Revert `archlinux` snapshot when complete.
