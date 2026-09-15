# SSH Upgrade Support

## Task

Add a safe SSH upgrade path for UFI003 after one full flash prepares a dedicated
`upgrade` partition.

## Type

Feature / Troubleshooting

## Phase

Verification

## Goal

Support future UFI003 upgrades over SSH by staging upgrade files on an
independent `upgrade` partition, then flashing `boot` and `rootfs` from a RAM
upgrade environment. Only add workflow output for SSH upgrade packages after the
device-side upgrade path is proven.

## Files Read

- `docs/project-map.md`
- `docs/task-playbooks.md`
- `docs/risk-boundaries.md`
- `docs/task-state-template.md`
- `flashtool/main.go`
- `flashtool/rom/gpt_both0.bin`
- `.github/workflows/build-immortalwrt-msm8916.yml`
- `config/ufi003.config`
- `scripts/ssh_upgrade_ufi003.sh`

## Files Changed

- `flashtool/rom/gpt_both0.bin`
- `flashtool/rom/gpt_both0.bin.backup-before-upgrade-partition-20260915`
- `flashtool/rom/gpt_both0.bin.backup-upgrade-1280m-20260915`
- `scripts/make_upgrade_gpt.py`
- `scripts/ssh_upgrade_ufi003.sh`
- `docs/task-states/2026-09-15-ssh-upgrade-support.md`

## Decisions

- Use a dedicated `upgrade` partition instead of storing upgrade images on the
  active `rootfs`.
- Keep the full-flash flow as the way to introduce the new partition layout.
- Current GPT layout:
  - `rootfs`: 2304 MiB, sectors `659456` through `5378047`.
  - `upgrade`: 768 MiB, sectors `5378048` through `6950911`.
- Keep original low-level, boot, baseband, and modem partitions unchanged.
- Store compressed upgrade payloads on `upgrade`; do not store the expanded raw
  rootfs image there.
- Use host-side conversion from full package `system.img` to
  `rootfs.raw.img.gz`; `system.img` is Android sparse and must not be written
  directly to `rootfs` with `dd`.
- Add a host-side SSH upgrade test script before adding workflow package output.
  The script stages files on the device `upgrade` partition, verifies hashes and
  partition sizes, then launches a detached device-side writer from `/tmp`.
- The SSH upgrade script auto-mounts the `upgrade` partition and formats it as
  ext4 on first use when it cannot be mounted.
- Host-side checksum generation supports GNU `sha256sum` and macOS
  `shasum -a 256`; device-side verification still uses OpenWrt `sha256sum -c`.
- Device-side writer launch avoids `nohup` because minimal OpenWrt images may
  not include it; the writer is started with `sh` in the background and
  redirected stdio.
- Device-side writer now copies BusyBox into `/tmp` before writing `rootfs` and
  uses that copy for post-write `sync`, watchdog sleep, process cleanup, and
  forced reboot. If BusyBox reboot fails, it falls back to `/proc/sysrq-trigger`.
- During SSH upgrade, the device-side writer flashes `red:power` at 0.1 second
  intervals while writing partitions, then flashes `blue:wan` at 0.3 second
  intervals for about 10 seconds after a clean write before rebooting. LED
  control is best-effort and must not block flashing if an LED sysfs node is
  missing.
- Do not change the firmware workflow to emit SSH upgrade packages until manual
  device testing passes.

## Verification

Run:

- Parsed `flashtool/rom/gpt_both0.bin` before and after modification.
- Recalculated and verified primary and secondary GPT header CRCs and partition
  entry CRCs.
- Converted the built UFI003 release package:
  - `system.img` sparse image to `rootfs.raw.img`.
  - `rootfs.raw.img` to `rootfs.raw.img.gz`.
- Ran read-only filesystem verification on the converted raw rootfs image.
- Ran `python3 scripts/make_upgrade_gpt.py --dry-run`.
- Ran `python3 scripts/make_upgrade_gpt.py --output /tmp/gpt_both0-script-test.bin --no-backup`
  and confirmed the output matched the current GPT with `cmp`.
- Ran `bash -n scripts/ssh_upgrade_ufi003.sh`.
- Ran `shellcheck scripts/ssh_upgrade_ufi003.sh`.
- Ran `scripts/ssh_upgrade_ufi003.sh --help`.
- Ran end-to-end SSH upgrade on a UFI003 device from macOS host:
  - `scripts/ssh_upgrade_ufi003.sh --host root@192.168.77.1 --system .../system.img --boot .../boot.img`
  - The script converted sparse `system.img`, compressed the raw rootfs,
    auto-formatted the first-use `upgrade` partition as ext4, staged images,
    verified hashes, installed the remote writer, and launched it.
- Inspected `/mnt/upgrade/ssh-upgrade/upgrade.log` after manual power-cycle.
- Updated the SSH upgrade writer reboot path, then ran:
  - `bash -n scripts/ssh_upgrade_ufi003.sh`
  - `shellcheck scripts/ssh_upgrade_ufi003.sh`
  - `scripts/ssh_upgrade_ufi003.sh --help`
- Retested the BusyBox-backed reboot fix on UFI003:
  - Device automatically rebooted within a few minutes after rootfs writing.
  - Device came back online and SSH was reachable.
  - A first post-reboot attempt to mount `upgrade` failed with a wrong
    filesystem/bad superblock style error.
  - A later post-reboot mount succeeded and `upgrade.log` showed
    `upgrade completed; rebooting`.
- Added SSH upgrade LED indicators, then ran:
  - `bash -n scripts/ssh_upgrade_ufi003.sh`
  - `shellcheck scripts/ssh_upgrade_ufi003.sh`
  - `scripts/ssh_upgrade_ufi003.sh --help`

Not run:

- Workflow changes for SSH upgrade package output.
- On-device verification of the new LED indicator behavior.

Result:

- Repository now contains a GPT payload with `rootfs` plus `upgrade`.
- The helper script can reproduce the current GPT layout and accepts partition
  size parameters.
- Repository now contains a host-side SSH upgrade test script for UFI003.
- Hardware SSH upgrade succeeded after manual power-cycle: the device did not
  automatically reboot after the writer was launched, but after roughly 20
  minutes the user power-cycled it and the upgraded system booted.
- The first-use `upgrade` partition formatting path is verified on-device.
- The automatic forced reboot path is defective after rootfs replacement:
  `upgrade.log` shows boot and rootfs writes completed, then `sync` became
  unavailable and both completion and watchdog `reboot -f` calls failed with
  `No error information`.
- Repository now has a candidate fix for the reboot issue, but it still needs an
  on-device SSH upgrade retest.
- The BusyBox-backed reboot fix is verified on-device: the device automatically
  rebooted, came back online, and the persistent log confirms the clean
  completion path reached `upgrade completed; rebooting`.
- Repository now has a candidate LED indicator update for SSH upgrade, but it
  still needs on-device visual verification.

## Risks

- GPT and partition layout changes are high risk and can brick or soft-brick the
  device if the bootloader interprets the packed GPT differently than expected.
- The target device previously dropped SSH when entering an OpenWrt stage2-style
  RAM upgrade test, so the final SSH updater must include watchdogs, timeouts,
  and a forced reboot fallback.
- The SSH writer did not automatically reboot the device after a successful
  upgrade test, even though the script has completion and watchdog `reboot -f`
  calls. This should be diagnosed before making SSH upgrade packages a normal
  workflow output.
- After `rootfs` is overwritten, commands resolved from the active rootfs may
  disappear or fail. The writer should avoid depending on rootfs-backed
  `sync`/`reboot` after `dd` starts.
- The RJ45 path is USB-host-attached CDC Ethernet; network behavior during a RAM
  upgrade must be tested on the real device.
- Workflow output can now be added, but it still touches the firmware build and
  release path, so verify generated artifacts before relying on them.
- LED names are based on existing overlay usage (`red:power` and `blue:wan`);
  if a hardware variant exposes different names, indicators will be skipped.

## Next Step

Retest `scripts/ssh_upgrade_ufi003.sh` on UFI003 and visually confirm red
flashing during partition writes plus blue flashing for 10 seconds before reboot. Then
update `.github/workflows/build-immortalwrt-msm8916.yml` to emit an SSH upgrade
package and verify the generated package contains `boot.img` plus the compressed
raw rootfs image expected by the SSH upgrade script.
