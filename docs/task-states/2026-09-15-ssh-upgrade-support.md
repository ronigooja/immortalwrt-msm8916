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
- `.github/workflows/Build_高通410 imm.yml`
- `config/ufi003.config`

## Files Changed

- `flashtool/rom/gpt_both0.bin`
- `flashtool/rom/gpt_both0.bin.backup-before-upgrade-partition-20260915`
- `flashtool/rom/gpt_both0.bin.backup-upgrade-1280m-20260915`
- `工具与脚本/make_upgrade_gpt.py`
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
- Ran `python3 工具与脚本/make_upgrade_gpt.py --dry-run`.
- Ran `python3 工具与脚本/make_upgrade_gpt.py --output /tmp/gpt_both0-script-test.bin --no-backup`
  and confirmed the output matched the current GPT with `cmp`.

Not run:

- Full flash with the new GPT on the UFI003 device.
- First boot verification that `/dev/disk/by-partlabel/upgrade` appears.
- Formatting and mounting the `upgrade` partition on-device.
- End-to-end SSH upgrade from staged `boot.img` and `rootfs.raw.img.gz`.
- Workflow changes for SSH upgrade package output.

Result:

- Repository now contains a GPT payload with `rootfs` plus `upgrade`.
- The helper script can reproduce the current GPT layout and accepts partition
  size parameters.
- Hardware flashing and SSH upgrade remain unverified.

## Risks

- GPT and partition layout changes are high risk and can brick or soft-brick the
  device if the bootloader interprets the packed GPT differently than expected.
- The target device previously dropped SSH when entering an OpenWrt stage2-style
  RAM upgrade test, so the final SSH updater must include watchdogs, timeouts,
  and a forced reboot fallback.
- The RJ45 path is USB-host-attached CDC Ethernet; network behavior during a RAM
  upgrade must be tested on the real device.
- `upgrade` must be formatted after the first full flash before it can be used
  for staging.
- Workflow output must wait until the manual flash and SSH upgrade path is
  proven.

## Next Step

Flash the full package using the updated `flashtool/rom/gpt_both0.bin`, then on
the device verify `upgrade` exists, format it, mount it, stage
`boot.img`/`rootfs.raw.img.gz`, and test the SSH upgrade procedure. If that
passes, update `.github/workflows/Build_高通410 imm.yml` to emit an SSH upgrade
package.
