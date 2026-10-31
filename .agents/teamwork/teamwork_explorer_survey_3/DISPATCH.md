# Dispatch - Explorer Survey 3

## Mission
Investigate QEMU/KVM virtual machine environment, snapshots, network, and test execution protocols (R6) as well as host protection and privacy boundaries (R5).

## Instructions & Scope
Read `/home/eilthorne/EilNiri/.agents/teamwork/ORIGINAL_REQUEST.md`.
Investigate the VM environment and testing infrastructure:
1. Check available QEMU/KVM VMs (`virsh list --all`, `virsh dominfo`, `virsh snapshot-list` for `debian13`, `fedora44`, `archlinux`).
2. Identify existing snapshots for each VM, their state, how to safely revert them, and how to verify clean state.
3. Investigate VM networking and connectivity:
   - Check virsh net-list, DHCP leases, IP addresses of each VM when started.
   - Test or check credentials (user password `lwh1130@` for debian13, `1` for fedora44 and archlinux).
   - Check if SSH is enabled or how commands/scripts can be executed inside the VMs without manual intervention.
4. Investigate how tests should be structured:
   - How to copy the repository into the VM.
   - How to execute the scripts non-interactively with sudo.
   - How to verify exit codes, service statuses (e.g. niri, waybar, fcitx5).
   - How to ensure the VM is reverted to its baseline snapshot after testing.
5. Check host protection and privacy guardrails: verify what files are outside `/home/eilthorne/EilNiri` and ensure no modifications happen on host.
6. Output detailed report to `/home/eilthorne/EilNiri/.agents/teamwork/teamwork_explorer_survey_3/handoff.md`.

## 2026-10-31T03:26:33Z
Received dispatch from parent c36dc361-2cd1-4da8-9b42-c12b40a6b023:
Investigate QEMU/KVM virtual machine environment, snapshots, network, and test execution protocols (R6) as well as host protection and privacy boundaries (R5).

## 2026-10-31T03:41:02Z
From parent c36dc361-2cd1-4da8-9b42-c12b40a6b023:
Checking in on survey progress. Explorer 1 completed analysis.
Requested update on progress.md and latest findings.
