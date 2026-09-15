# Repository Agent Guide

This repository builds customized ImmortalWrt firmware for Qualcomm MSM8916
portable Wi-Fi devices and provides helper assets for flashing and device setup.

Agents should use this file as the starting point, then read only the project
documents needed for the current task.

During execution, use English for working updates and tool-facing process
descriptions. Use Chinese for final reports to the user. Keep repository
documentation in English.

## Read Order

1. Read `docs/project-map.md` to understand the repository layout and build flow.
2. Read `docs/task-playbooks.md` before changing build scripts, device configs,
   firmware overlay files, workflows, documentation, or the flashing tool.
3. Read `docs/risk-boundaries.md` before touching firmware, flashing, partition,
   baseband, kernel, or GitHub Actions behavior.
4. For Feature, Optimization, Refactoring, Troubleshooting, or long-running
   work, follow the protocols in `docs/task-playbooks.md`. When cross-session
   state is needed, use `docs/task-state-template.md`.

## Task Routing

- Device build profiles: `config/*.config`
- GitHub Actions firmware build: `.github/workflows/build-immortalwrt-msm8916.yml`
- Self-hosted runner build request: when the user explicitly asks to compile
  with `self-hosted-runner`, first run
  `./scripts/setup-self-hosted-runner.sh <runner-ip-or-hostname>` for the
  provided runner IP or host. Do not call GitHub workflow dispatch before that
  setup script finishes and the runner is visible online.
- OpenWrt source customization: `diy-part1.sh`, `diy-part2.sh`
- Firmware overlay files: `files/`
- Flashing tool: `flashtool/`
- Repository documentation: `docs/`

## Hard Rules

- Do not overwrite user changes. Check `git status --short` before editing.
- This is a private repository. For GitHub operations, use the GitHub API with
  locally stored credentials such as the Git credential store. Do not try `gh`
  or other GitHub helper CLIs.
- Before modifying any non-Markdown file, tell the user why the change is
  needed and which file or area will be changed, then wait for explicit
  permission to continue.
- Do not remove existing device profiles unless explicitly requested.
- Do not casually edit binary firmware, baseband, or flashing assets.
- Treat partition names, baseband backup/restore logic, and Fastboot operations
  as high-risk.
- Keep repository documentation concise and action-oriented. Avoid duplicating the
  full README tutorial unless it helps future maintenance.
- When changing behavior, update the relevant repository document if the project
  map, task flow, or risk boundary changed.

## Delivery Expectations

When completing a task, report:

- Files changed.
- Behavior changed.
- Verification performed, or why verification was not run.
- Remaining risk when the change touches build, firmware, flashing, or hardware.
