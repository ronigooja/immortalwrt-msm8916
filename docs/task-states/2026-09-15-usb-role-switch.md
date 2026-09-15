# USB Role Switch Task State

## Task

Enable a standard USB role-switch sysfs node for UFI/OpenStick msm8916 builds so `usb-role-autodetect` can switch between device and host mode.

## Type

Troubleshooting / Feature

## Phase

Implementation

## Goal

Produce a rebuilt firmware where `/sys/class/usb_role/*/role` exists on `openstick-ufi003`, allowing the existing boot script to select USB device mode first and fall back to host mode when no computer is detected.

## Files Read

- `docs/task-state-template.md`
- `diy-part2.sh`
- `.github/workflows/Build_高通410 imm.yml`
- `config/ufi003.config`
- `files/usr/sbin/usb-role-autodetect`
- `files/etc/rc.local`
- `/tmp/imm-openwrt-src.8prmIq/target/linux/msm89xx/dts/msm8916-ufi.dtsi`
- `/tmp/imm-openwrt-src.8prmIq/target/linux/msm89xx/dts/msm8916-thwc-ufi001c.dts`
- `/tmp/imm-openwrt-src.8prmIq/target/linux/msm89xx/dts/msm8916-sp970.dtsi`
- `/tmp/imm-openwrt-src.8prmIq/target/linux/msm89xx/image/msm8916.mk`
- `/tmp/imm-openwrt-src.8prmIq/target/linux/msm89xx/config-6.12`

## Files Changed

- `diy-part2.sh`
- `docs/task-states/2026-09-15-usb-role-switch.md`

## Decisions

- Do not test by directly switching USB mode on the live device at `root@192.168.2.79`.
- Implement the fix at build time because the OpenWrt source tree is cloned during GitHub Actions and is not stored directly in this repository.
- Patch the shared UFI/OpenStick device tree include `target/linux/msm89xx/dts/msm8916-ufi.dtsi`, because `openstick-ufi003` inherits from `openstick-ufi001c`, which uses `DEVICE_DTS := msm8916-thwc-ufi001c`, and that DTS includes `msm8916-ufi.dtsi`.
- Add `dr_mode = "otg";` and `usb-role-switch;` to the `&usb` node, matching the role-switch pattern already present in `msm8916-sp970.dtsi`.
- Keep `CONFIG_USB_ROLE_SWITCH=y`, `CONFIG_EXTCON=y`, and `CONFIG_EXTCON_USB_GPIO=y` forced in `target/linux/msm89xx/config-*` to avoid upstream config drift.

## Verification

Run:

- `ssh root@192.168.2.79` read-only checks of UCI config, service status, interface state, logs, kernel config, and USB sysfs/debugfs paths.
- `bash -n diy-part2.sh`
- `git diff --check`
- Build-script simulation against a clean copy of upstream `msm8916-ufi.dtsi` and `config-6.12` from locked upstream commit `7fe583d96eabe34efdc2f764a6f413a56e687eca`.
- Repeated simulation to confirm the DTS properties are not inserted more than once.

Not run:

- No direct USB role switch was attempted on `root@192.168.2.79`, per user instruction.
- No full OpenWrt firmware build was run locally; the repository is set up to build through GitHub Actions.
- No post-flash validation was possible because the patched firmware has not been rebuilt and installed yet.

Result:

- Live firmware currently lacks `/sys/class/usb_role/*/role`.
- Live boot log showed `usb-role-autodetect: no writable USB role node found`.
- Live kernel has `CONFIG_USB_ROLE_SWITCH=y`, but `msm8916-ufi.dtsi` did not provide `usb-role-switch;` for the UFI USB controller.
- The simulated build-time patch changes `&usb` to:

```dts
&usb {
	dr_mode = "otg";
	usb-role-switch;
	status = "okay";
	extcon = <&usb_id>, <&usb_id>;
};
```

- Static checks passed.

## Risks

- `usb-role-switch;` is expected to register the standard sysfs role node, but this still depends on the msm8916 ChipIdea driver and extcon wiring accepting this DTS configuration at runtime.
- `usb_id` currently uses GPIO 110 through `linux,extcon-usb-gpio`; if the board wiring or polarity differs for a specific UFI003 variant, automatic role detection may still behave incorrectly.
- If `/sys/class/usb_role/*/role` still does not appear after rebuilding, the next investigation should inspect boot-time `dmesg` for `ci_hdrc`, `usb_role`, `extcon`, and device-tree binding errors.

## Next Step

Trigger a new GitHub Actions build for `openstick-ufi003`, flash the generated firmware, then check:

```sh
ls -l /sys/class/usb_role/*/role
cat /sys/class/usb_role/*/role
logread -e usb-role-autodetect
```
