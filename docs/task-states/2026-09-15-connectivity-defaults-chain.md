# Connectivity Defaults Chain

## Task

Make `ufi003` keep a usable management path after first boot by combining USB
device detection, USB-RJ45 WAN fallback, SSH key-only access, temporary hidden
hotspot setup, and Tailscale exit-node forwarding.

## Type

Troubleshooting / Feature

## Phase

Handoff

## Goal

Produce firmware defaults where `ufi003` first tries to expose a USB device
connection to a computer, falls back to USB host mode for Ethernet WAN when no
computer is detected, and remains reachable through SSH during normal use.

## Files Read

- `.github/workflows/build-immortalwrt-msm8916.yml`
- `config/ufi003.config`
- `diy-part2.sh`
- `files/etc/rc.local`
- `files/etc/init.d/wifi-autooff`
- `files/etc/rc.d/S00board-led-defaults`
- `files/etc/uci-defaults/97-wireless-hotspot-defaults`
- `files/etc/uci-defaults/98-ssh-key-only`
- `files/etc/uci-defaults/99-default-wan-eth0`
- `files/etc/uci-defaults/99-tailscale-exit-node-firewall`
- `files/usr/sbin/usb-role-autodetect`
- `files/usr/sbin/wifi-hotspot-off`

## Files Changed

- `.github/workflows/build-immortalwrt-msm8916.yml`
- `config/ufi003.config`
- `diy-part2.sh`
- `files/etc/dropbear/authorized_keys`
- `files/etc/init.d/wifi-autooff`
- `files/etc/rc.d/S00board-led-defaults`
- `files/etc/rc.local`
- `files/etc/uci-defaults/97-wireless-hotspot-defaults`
- `files/etc/uci-defaults/98-ssh-key-only`
- `files/etc/uci-defaults/99-default-wan-eth0`
- `files/etc/uci-defaults/99-tailscale-exit-node-firewall`
- `files/usr/sbin/usb-role-autodetect`
- `files/usr/sbin/wifi-hotspot-off`

## Decisions

- Treat behavior commits after `e21d545d` as the reviewed chain, excluding
  documentation-only changes.
- Patch UFI/OpenStick USB role support at build time in `diy-part2.sh`, because
  the OpenWrt source tree is cloned during Actions instead of stored here.
- Patch the upstream `00-passwordless-root.sh` login warning to a no-op at build
  time, because SSH uses bundled key-only access and the warning is misleading.
- Patch UFI/OpenStick board LED DTS defaults at build time so `red:power`,
  `green:wlan`, and `blue:wan` default off when Linux registers the LEDs.
- Add `/etc/rc.d/S00board-led-defaults` as a runtime fallback to force board
  LED triggers to `none` and brightness to `0` as early as init scripts run.
- Start `/usr/sbin/usb-role-autodetect` from `rc.local`: try USB device mode,
  wait briefly for a computer, then switch to host mode for USB-RJ45 WAN if no
  computer is detected.
- Configure `eth0` as WAN on first boot after removing it from the actual
  `br-lan` device section.
- Use SSH public-key-only access and remove Dropbear interface restrictions so
  recovery is possible from any reachable interface.
- Configure a hidden default hotspot, then disable AP interfaces after a
  3-hour timer.
- Add `tailscale0` firewall zone forwarding to `wan` for exit-node traffic.
- Enable common `ufi003` USB Ethernet drivers, including ASIX, Realtek RTL8152,
  DM9601, SR9700, MCS7830, Pegasus, and SMSC95xx.

## Verification

Run:

- `git log --reverse --oneline e21d545d00a5ba49ed4f0113e0ec21a704005d18..HEAD`
- `git diff --name-status e21d545d00a5ba49ed4f0113e0ec21a704005d18..HEAD -- . ':!docs' ':!AGENTS.md' ':!README.md' ':!README_EN.md'`
- `bash -n diy-part2.sh files/usr/sbin/usb-role-autodetect files/usr/sbin/wifi-hotspot-off files/etc/uci-defaults/97-wireless-hotspot-defaults files/etc/uci-defaults/98-ssh-key-only files/etc/uci-defaults/99-default-wan-eth0 files/etc/uci-defaults/99-tailscale-exit-node-firewall`
- `sh -n files/etc/rc.d/S00board-led-defaults`
- `shellcheck diy-part2.sh files/etc/uci-defaults/97-wireless-hotspot-defaults files/etc/rc.d/S00board-led-defaults`
- Dry-ran `diy-part2.sh` against the pinned upstream DTS and
  `00-passwordless-root.sh`; confirmed the SSH warning script becomes a no-op
  and `led_r` changes from `default-state = "on"` to `default-state = "off"`.
- Installed `/etc/rc.d/S00board-led-defaults` on `root@192.168.2.79`, ran it,
  and confirmed `red:power`, `green:wlan`, and `blue:wan` were set to
  `brightness=0` with trigger `none`.
- Rebooted `root@192.168.2.79`; the user still observed red light during early
  boot, while post-boot sysfs showed `red:power brightness=0`, confirming the
  rc.d fallback is too late to prevent the kernel DTS default from lighting red.
- Patched `/etc/profile.d/00-passwordless-root.sh` on `root@192.168.2.79` to
  the same no-op used by the build-time fix.
- `git diff --check`

Not run:

- No full OpenWrt firmware build was run locally.
- No firmware was flashed.
- No live USB role, WAN, Wi-Fi, or Tailscale runtime validation was run after
  these LED and SSH-warning changes.
- No rebuilt `boot.img` with the LED DTS default-off patch has been flashed yet.

Result:

- Static shell checks and whitespace checks passed.
- Live rc.d LED fallback works after userspace starts, but does not prevent the
  early red LED before init scripts run.
- The repository state is ready for a GitHub Actions build and hardware
  validation.

## Risks

- USB role switching still depends on the msm8916 ChipIdea/extcon driver
  accepting the patched DTS at runtime.
- Board LED default-off now depends on the DTS patch being present in the newly
  built and flashed `boot.img`; the live rc.d fallback alone cannot suppress the
  early red light.
- If red still lights before Linux registers LEDs after flashing the patched
  `boot.img`, the remaining source is likely lk2nd/bootloader behavior.
- USB-RJ45 fallback assumes the adapter appears as `eth0`; the added drivers
  improve coverage but do not prove the live adapter name.
- SSH password login is disabled, so the bundled public key must be usable by
  the intended administrator.
- Hidden Wi-Fi plus AP auto-off can reduce recovery options if USB, Ethernet,
  or SSH key access fails.
- Tailscale forwarding assumes `tailscale0` exists after Tailscale is
  configured.

## Next Step

Build and flash a new `ufi003` image, then check:

```sh
ls -l /sys/class/usb_role/*/role
logread -e usb-role-autodetect
ip link show eth0
uci show network.wan network.wan6
uci show dropbear
uci show firewall.tailscale firewall.tailscale_wan
uci show wireless
for led in red:power green:wlan blue:wan; do
    cat "/sys/class/leds/$led/trigger"
    cat "/sys/class/leds/$led/brightness"
done
cat /etc/profile.d/00-passwordless-root.sh
```
