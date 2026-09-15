# Project Map

This project is a GitHub Actions based ImmortalWrt firmware builder for Qualcomm
MSM8916 / Snapdragon 410 portable Wi-Fi devices. It also includes firmware
overlay files, device build configs, AI-facing maintenance documents, and a Go
based flashing tool.

## Main Areas

| Path | Role |
| --- | --- |
| `.github/workflows/Build_高通410 imm.yml` | Main cloud firmware build workflow. |
| `.github/workflows/Build_刷机工具.yml` | Builds and releases the Go flashing tool. |
| `config/` | Device profile `.config` files. File names match workflow profile options. |
| `files/` | OpenWrt overlay copied into the firmware image. |
| `diy-part1.sh` | Runs before feeds update. Used for feed source changes. |
| `diy-part2.sh` | Runs after feeds install. Used for config, kernel, DTS, and patch tweaks. |
| `scripts/setup-self-hosted-runner.sh` | Bootstraps a Ubuntu self-hosted GitHub Actions runner on a VPS. |
| `flashtool/` | Go flashing tool and bundled low-level ROM assets. |
| `docs/` | AI-facing project documents and task state records. |
| `README.md`, `README_EN.md` | User-facing build and flashing guide. |
| `upstream_lock.txt` | Manually maintained upstream commit used by builds unless overridden. |
| `upstream_history.txt` | Historical upstream commits kept for fallback reference. |

## Firmware Build Flow

The main firmware workflow:

1. User starts the workflow and selects `profile`, `upstream`, optional
   `custom_hash`, and optional `extra_packages`.
2. Workflow checks out this repository.
3. Runner dependencies, `mkbootimg`, Python tools, ccache, and download cache are
   prepared.
4. The upstream ImmortalWrt source is cloned under `/mnt/openwrt`.
5. If `custom_hash` is set, it is checked out. Otherwise `upstream_lock.txt` is
   used when available.
6. `files/` is copied into `openwrt/files`.
7. `diy-part1.sh` runs before `./scripts/feeds update -a`.
8. Conflicting packages are removed from the `smpackage` feed.
9. Feeds are installed.
10. `config/{profile}.config` becomes `openwrt/.config`.
11. `diy-part2.sh` runs after feeds install.
12. Extra packages and system parameters from workflow input are applied.
13. OpenWrt build commands produce firmware artifacts and releases.

## Self-Hosted Runner Setup

Use `scripts/setup-self-hosted-runner.sh` after reinstalling a Ubuntu 22.04 VPS
that will run the main firmware workflow. Run it from this repository with the
current runner IP or hostname:

```bash
./scripts/setup-self-hosted-runner.sh <runner-ip-or-hostname>
```

The script mints a fresh GitHub runner registration token from
`RUNNER_ADMIN_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`, or the local Git credential
store. It SSHes to `root@IP`, creates the `github` user, installs the runner
under `/home/github/actions-runner`, adds the configured SSH public key for the
`github` user, enables passwordless sudo for build dependencies, and starts the
runner as a systemd service.

Defaults can be overridden with environment variables such as `REPO`,
`RUNNER_NAME`, `RUNNER_LABELS`, `RUNNER_USER`, `SSH_PUBLIC_KEY`, and
`RUNNER_VERSION`. The workflow selector still starts on GitHub-hosted
`ubuntu-latest`; the `build` job should move to `self-hosted` when the runner is
online and visible to the GitHub Actions API.

## Device Profiles

Supported device profiles are defined in two places:

- Workflow choices in `.github/workflows/Build_高通410 imm.yml`
- Matching config files in `config/*.config`

When adding a profile, update both places and the user-facing README tables.

## Firmware Overlay

`files/` is copied into the OpenWrt source tree as `openwrt/files`, so its
contents become part of the firmware image.

Important overlay areas:

- `files/etc/uci-defaults/`: first-boot UCI setup scripts.
- `files/etc/init.d/`: init scripts installed into the image.
- `files/usr/sbin/`: runtime helper commands.
- `files/etc/cardswitch/`: SIM/card switching helper logic.
- `files/etc/dropbear/`: SSH related defaults.

## DIY Scripts

`diy-part1.sh` is for source/feed preparation before feed update. It currently
adds third-party feeds such as `kenzok8/small-package` and LinkEase iStore.

`diy-part2.sh` is for post-feed customization. It currently changes the default
LuCI theme to Argon, enables policy routing options used by Tailscale exit-node
style setups, and ensures USB role-switch/extcon support for msm89xx targets.

## Flashing Tool

`flashtool/` contains the Go command-line flashing tool. The main flow is in
`flashtool/main.go`; Fastboot operations live under `flashtool/fastboot/`;
Windows environment checks and helper installers live under `flashtool/winenv/`.

The tool checks for required ROM files, waits for a Fastboot device, flashes
`lk2nd`, backs up baseband partitions, flashes low-level firmware files, restores
baseband partitions, then flashes `boot.img` and `system.img`.
