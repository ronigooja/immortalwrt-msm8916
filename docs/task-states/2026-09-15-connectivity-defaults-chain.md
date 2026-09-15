# Connectivity Defaults Chain Task State

## Task

Record the final landed behavior from commits after
`e21d545d00a5ba49ed4f0113e0ec21a704005d18`, excluding documentation-only
changes.

## Type

Troubleshooting / Feature / Optimization

## Phase

Handoff

## Goal

Preserve the final "small combo" that makes the msm8916 firmware easier to
build, flash, reach over SSH, use through USB-RJ45 fallback WAN, and run as a
Tailscale exit node.

## Commit Range Reviewed

Start point:

- `e21d545d00a5ba49ed4f0113e0ec21a704005d18` (`Remove 'tailscale' from smpackage to prevent conflicts`)

Behavior/build commits included:

- `3faf8e7` / `48c0ba7`: adjust the Qualcomm 410 build workflow.
- `fb99f0a`: move Tailscale exit-node routing kernel options into
  `diy-part2.sh`.
- `2de0d33`: add boot-time USB role autodetection.
- `0908e13`: add OpenWrt download and ccache handling to the build workflow.
- `5ee88bb`: add default `eth0` WAN configuration.
- `1769d00`: make USB device mode light the default board LED state.
- `cd5a238`: add SSH public-key-only defaults.
- `1e13ca0`: add hidden hotspot defaults and timed AP shutdown.
- `7b4c61c`: remove `eth0` from `br-lan` by device name before assigning WAN.
- `dea23fa`: fix OpenWrt config mutation in the workflow.
- `159c4de`: patch UFI/OpenStick DTS for the standard USB role-switch node.
- `b5708e3`: simplify firmware build workflows by removing unused workflows.
- `1ceb388`: add the current Windows flash package scripts.
- `6a90cfc`: remove bundled homepage files and legacy flash scripts.
- `2f6f9ea`: bring up WAN after USB host fallback.
- `f2a9d29`: tune runtime USB role handling and keep startup in `rc.local`.
- `b9e8733`: ensure SSH access defaults apply even when Dropbear config is
  missing or constrained.
- `30070e8`: correct the hotspot SSID and suppress the no-password banner
  warning.
- `2459aa5`: add the final Tailscale firewall zone and forwarding default.

Final commit treated as truth:

- `2459aa5eea6cfaf1df2db5a73b5ee13f3cd14a7f`

## Files Read

- `.github/workflows/Build_高通410 imm.yml`
- `diy-part2.sh`
- `files/etc/rc.local`
- `files/etc/init.d/wifi-autooff`
- `files/etc/uci-defaults/97-wireless-hotspot-defaults`
- `files/etc/uci-defaults/98-ssh-key-only`
- `files/etc/uci-defaults/99-default-wan-eth0`
- `files/etc/uci-defaults/99-tailscale-exit-node-firewall`
- `files/usr/sbin/usb-role-autodetect`
- `files/usr/sbin/wifi-hotspot-off`

## Files Changed In Reviewed Behavior Chain

- `.github/workflows/Build_高通410 imm.yml`
- `.github/workflows/pages.yml`
- `.github/workflows/定时更新hash.yml`
- `diy-part2.sh`
- `files/etc/dropbear/authorized_keys`
- `files/etc/init.d/wifi-autooff`
- `files/etc/rc.local`
- `files/etc/uci-defaults/97-wireless-hotspot-defaults`
- `files/etc/uci-defaults/98-ssh-key-only`
- `files/etc/uci-defaults/99-default-wan-eth0`
- `files/etc/uci-defaults/99-tailscale-exit-node-firewall`
- `files/usr/sbin/usb-role-autodetect`
- `files/usr/sbin/wifi-hotspot-off`
- `files/www/content.json`
- `files/www/index.html`
- `files/www/index_原版备份.html`
- `刷机脚本/firstflash.bat`
- `刷机脚本/upgrade.bat`
- `刷机脚本/一键升级补丁.bat`
- `刷机脚本/把编译好的文件改名成boot.img和system.img.txt`

## Final Landed Behavior

- Build defaults now include `tailscale`, `ethtool`, useful shell/debug tools,
  OpenSSH SFTP support, IPv6 DHCP packages, default management IP
  `192.168.77.1`, and default hostname `Unknown`.
- The workflow restores OpenWrt download cache and ccache, enables `CONFIG_DEVEL`,
  `CONFIG_CCACHE`, `CONFIG_CCACHE_DIR`, and `CONFIG_PACKAGE_ethtool`, then runs
  `make defconfig`.
- `diy-part2.sh` keeps Tailscale exit-node routing support enabled by forcing
  `CONFIG_IP_ADVANCED_ROUTER`, `CONFIG_IP_MULTIPLE_TABLES`, and
  `CONFIG_IP_ROUTE_FWMARK` in `target/linux/msm89xx/config-*`.
- `diy-part2.sh` patches `target/linux/msm89xx/dts/msm8916-ufi.dtsi` so the
  UFI/OpenStick USB controller has `dr_mode = "otg";` and `usb-role-switch;`,
  then forces `CONFIG_USB_ROLE_SWITCH`, `CONFIG_EXTCON`, and
  `CONFIG_EXTCON_USB_GPIO`.
- `rc.local` starts `/usr/sbin/usb-role-autodetect` in the background at boot.
- `usb-role-autodetect` first tries USB device mode, waits up to 12 seconds for
  a computer connection, lights `green:wlan` when device mode remains active,
  then falls back to host mode for USB-RJ45 if no computer is detected.
- After USB host fallback, `usb-role-autodetect` waits for `eth0`, applies
  `ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off` when available,
  and runs `ifup wan` plus `ifup wan6`.
- First boot removes `eth0` from `br-lan` by finding the actual `br-lan` device
  section, then creates DHCP `wan` and DHCPv6 `wan6` on `eth0`.
- First boot writes the configured SSH public key, disables password and root
  password auth in Dropbear, removes interface restrictions, opens TCP/22 in
  firewall, reloads firewall, and restarts Dropbear.
- First boot configures the AP as hidden SSID `Unknown` with WPA2 key
  `88888888`, reloads Wi-Fi, enables `wifi-autooff`, and starts a 3-hour timer
  that disables AP interfaces.
- First boot removes the stock no-root-password warning from `/etc/banner`
  because SSH password login is intentionally disabled.
- First boot adds firewall zone `tailscale` on `tailscale0` and forwarding
  `tailscale -> wan`, allowing exit-node traffic to leave through WAN.
- The bundled web homepage files and legacy flash-script placeholders are gone;
  the current release package uses `刷机脚本/firstflash.bat` and
  `刷机脚本/upgrade.bat`.

## Verification

Run:

- `git log --reverse --oneline e21d545d00a5ba49ed4f0113e0ec21a704005d18..HEAD`
- `git diff --stat e21d545d00a5ba49ed4f0113e0ec21a704005d18..HEAD -- . ':!docs' ':!AGENTS.md' ':!README.md' ':!README_EN.md'`
- `git diff --name-status e21d545d00a5ba49ed4f0113e0ec21a704005d18..HEAD -- . ':!docs' ':!AGENTS.md' ':!README.md' ':!README_EN.md'`
- Read the final `HEAD` contents of each runtime/build file listed above.

Not run:

- No full OpenWrt build was run locally.
- No firmware was flashed.
- No live USB role, WAN, SSH, Wi-Fi, or Tailscale exit-node runtime test was
  performed.

Result:

- The recorded behavior matches final `HEAD` at
  `2459aa5eea6cfaf1df2db5a73b5ee13f3cd14a7f`.
- Documentation-only changes were intentionally excluded from this record.

## Risks

- USB role switching still depends on the msm8916 ChipIdea/extcon runtime
  behavior after a real build and flash.
- Automatic USB-RJ45 fallback assumes the adapter appears as `eth0`.
- SSH password login is disabled by default, so the bundled public key must be
  valid for intended administrators.
- Hidden Wi-Fi plus 3-hour AP auto-off can reduce recovery options if Ethernet,
  USB device mode, or SSH key access fails.
- Tailscale exit-node forwarding assumes `tailscale0` exists after Tailscale is
  configured.

## Next Step

Build and flash a new image from `2459aa5`, then validate:

```sh
ls -l /sys/class/usb_role/*/role
logread -e usb-role-autodetect
ip link show eth0
uci show network.wan network.wan6
uci show dropbear
uci show firewall.tailscale firewall.tailscale_wan
uci show wireless
```
