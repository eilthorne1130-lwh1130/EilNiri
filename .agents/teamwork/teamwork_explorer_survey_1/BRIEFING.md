# BRIEFING — 2026-10-31T03:37:50Z

## Mission
Survey repository structure and investigate R1 (Snapshot cleanup in RHEL & Arch) & R2 (RHEL input method migration from IBus to COPR FCITX5).

## 🔒 My Identity
- Archetype: explorer
- Roles: survey, investigation, synthesis
- Working directory: /home/eilthorne/EilNiri/.agents/teamwork/teamwork_explorer_survey_1/
- Original parent: c36dc361-2cd1-4da8-9b42-c12b40a6b023
- Milestone: Investigation & Survey

## 🔒 Key Constraints
- Read-only investigation — do NOT implement
- Host protection: Do NOT run scripts on host, do NOT change host system
- Privacy protection: Do NOT leak personal info into git or configs
- Only write within /home/eilthorne/EilNiri/.agents/teamwork/teamwork_explorer_survey_1/

## Current Parent
- Conversation ID: c36dc361-2cd1-4da8-9b42-c12b40a6b023
- Updated: 2026-10-31T03:37:50Z

## Investigation State
- **Explored paths**:
  - `arch-install.sh`: identified all snapshot and backup lines (1250, 1826-1836, 1849-1853, 2396-2398, 2636, 2657-2708).
  - `RHEL-install.sh`: identified all snapshot and backup lines (2843, 4124, 4174, 4241-4251, 4255-4258, 4522, 4843-4845, 5071, 5089-5154) and IBus implementation logic.
  - `configs/.config/niri/config.kdl` & `configs/.config/fcitx5/*`: confirmed native fcitx5 configuration already exists.
  - Fedora 44 & RHEL COPR analysis: verified official Fedora RPM coverage, absence of general EPEL Copr for core fcitx5, and required migration strategy.
  - Virtualization & snapshots: verified `archlinux` (`snap-20260913-130800`), `debian13` (`snap-disk-20261024-1809`), and `fedora44` (`snapshot1`).
- **Key findings**:
  - R1: All `.bak-*` file moves, `prune_config_backups`, and `save_diag_bundle` tarballs can be removed without breaking installation.
  - R2: `config.kdl` is natively configured for Fcitx5. Removing `_repoint_ime_*` avoids touching `config.kdl` entirely. IBus installation and launcher must be purged. Official RPMs on Fedora 44 provide stable Fcitx5 support with zero compilation.
- **Unexplored areas**:
  - None within Survey Agent 1's assigned scope.

## Key Decisions Made
- Documented exact file paths, line numbers, and code replacements in `handoff.md`.
- Formulated static and VM-based verification methods for the implementation phase.

## Artifact Index
- /home/eilthorne/EilNiri/.agents/teamwork/teamwork_explorer_survey_1/BRIEFING.md — Working memory
- /home/eilthorne/EilNiri/.agents/teamwork/teamwork_explorer_survey_1/progress.md — Liveness heartbeat
- /home/eilthorne/EilNiri/.agents/teamwork/teamwork_explorer_survey_1/handoff.md — Investigation and synthesis report
