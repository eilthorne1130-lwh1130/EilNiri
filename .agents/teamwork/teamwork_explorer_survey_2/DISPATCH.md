# Dispatch - Explorer Survey 2

## Mission
Investigate R3 (Debian screenshot editing issue) & R4 (Laptop battery module injection into Waybar across distros).

## Instructions & Scope
Read `/home/eilthorne/EilNiri/.agents/teamwork/ORIGINAL_REQUEST.md`.
Investigate the repository `/home/eilthorne/EilNiri`:
1. Investigate `deb-install.sh` and related configs/scripts:
   - Identify screenshot and screenshot editing components (e.g. grim, slurp, swappy, satty, flameshot, wl-clipboard, etc.).
   - Trace how screenshots and editing are invoked in Niri config (`~/.config/niri/config.kdl` or scripts).
   - Identify why screenshot editing fails or produces runtime errors in Debian desktop environments (e.g., missing dependencies, broken wrapper script, parameter errors, Wayland vs X11 incompatibilities, missing output directories).
   - Propose the cleanest, most reliable fix strategy for Debian.
2. Investigate `laptop-need-install.sh`:
   - Trace how the battery module is injected into Waybar (`config` / `config.jsonc`, `style.css`).
   - Analyze how Waybar configs are structured in the repo for Debian, Fedora, Arch.
   - Identify why laptop-need-install.sh fails or doesn't properly display battery across all target distributions.
   - Detail the required modifications to ensure Waybar properly loads and displays battery module without errors.
3. Output detailed report to `/home/eilthorne/EilNiri/.agents/teamwork/teamwork_explorer_survey_2/handoff.md`.

## 2026-10-31T03:40:52Z
Received check-in from parent c36dc361-2cd1-4da8-9b42-c12b40a6b023:
Context: Survey Agent 2 (Debian screenshot editing & laptop battery module)
Content: Checking in on your survey progress. Explorer 1 has already completed its analysis.
Action: Please update your progress.md with your latest findings and let us know your current status or expected completion time.
