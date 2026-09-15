# Risk Boundaries

This project can produce firmware and flashing tools for real devices. Treat
build, flashing, partition, and baseband changes as high-risk even when the code
change looks small.

## High-Risk Areas

| Area | Why It Is Risky |
| --- | --- |
| `flashtool/rom/` | Contains low-level bootloader and firmware assets. Wrong files can brick devices. |
| `flashtool/main.go` | Controls flashing order, partition erase/flash, and baseband backup/restore. |
| `flashtool/fastboot/` | Implements device communication and Fastboot operations. |
| `config/*.config` | Controls firmware image contents and kernel/userland selections. |
| `diy-part2.sh` | Modifies target kernel config and DTS behavior after feeds install. |
| `files/etc/uci-defaults/` | Changes first-boot network, SSH, wireless, and system defaults. |
| `.github/workflows/Build_高通410 imm.yml` | Controls the firmware build and release pipeline. |

## Flashing And Partition Rules

- Do not rename, reorder, add, or remove partition operations casually.
- Treat `boot`, `rootfs`, `lk2nd`, `fsc`, `fsg`, `modemst1`, and `modemst2` as
  sensitive partition names.
- Do not remove baseband backup steps unless explicitly requested and clearly
  documented.
- Do not skip `boot.img` or `system.img` validation.
- Do not silently ignore errors in flashing steps that determine whether the
  device can boot.

## Kernel And DTS Rules

- Changes to `target/linux/msm89xx/config-*` affect all matched msm89xx target
  configs during the build.
- DTS edits in `diy-part2.sh` should be guarded by file-existence checks.
- Kernel options added by script should remove old conflicting values before
  appending new values.
- Any USB role-switch, extcon, routing, modem, or gadget change should be
  described in the final report.

## Firmware Overlay Rules

- `files/etc/uci-defaults/` scripts should be safe for first boot and avoid
  destructive assumptions.
- SSH and network defaults can lock users out; report these changes clearly.
- Runtime helper scripts under `files/usr/sbin/` should remain executable.
- Avoid changing bundled keys or access behavior without an explicit request.

## GitHub Actions Rules

- Do not remove cache restore keys without considering build time impact.
- Do not update `upstream_lock.txt` manually unless the task is explicitly about
  upstream pinning.
- Workflow input names are part of the user-facing build interface; changing
  them requires README updates.

## Documentation Rules

- User-facing docs live in `README.md`, `README_EN.md`, and tutorial images.
- AI-facing docs live in `AGENTS.md`, `docs/project-map.md`,
  `docs/task-playbooks.md`, and `docs/risk-boundaries.md`.
- Keep AI-facing docs short, operational, and synchronized with real behavior.
