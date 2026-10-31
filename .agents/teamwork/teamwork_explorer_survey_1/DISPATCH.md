# Dispatch - Explorer Survey 1

## Mission
Survey repository structure and investigate R1 (Snapshot cleanup in RHEL & Arch) & R2 (RHEL input method migration from IBus to COPR FCITX5).

## Instructions & Scope
Read `/home/eilthorne/EilNiri/.agents/teamwork/ORIGINAL_REQUEST.md`.
Investigate the repository `/home/eilthorne/EilNiri`:
1. Analyze repository layout, git status, scripts, and configs.
2. Investigate `RHEL-install.sh` and `arch-install.sh`:
   - Find all snapshot/backup related logic (e.g. `.bak-*` file backups, `save_diag_bundle`, tarballs, diag dumps).
   - Document exactly what lines and functions handle snapshots/backups and what needs to be removed/cleaned while keeping normal installation working.
3. Investigate `RHEL-install.sh` input method logic:
   - Identify current IBus installation, environment variables, startup configurations.
   - Investigate recommended and stable COPR repositories and packages for FCITX5 on RHEL/Fedora (specifically Fedora 44 / RHEL).
   - Detail the required packages, environment variables (`GTK_IM_MODULE`, `QT_IM_MODULE`, `XMODIFIERS`), autostart configuration for Niri/Wayland, and how fcitx5 should be configured.
4. Note any constraints regarding host protection (do not run scripts on host, do not change host system).
5. Output detailed report to `/home/eilthorne/EilNiri/.agents/teamwork/teamwork_explorer_survey_1/handoff.md`.
