# AI Entry Guide

This repository builds customized ImmortalWrt firmware for Qualcomm MSM8916
portable Wi-Fi devices and provides helper assets for flashing and device setup.

AI agents should use this file as the starting point, then read only the project
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

- GitHub Actions firmware build: `.github/workflows/Build_高通410 imm.yml`
- Device build profiles: `config/*.config`
- OpenWrt source customization: `diy-part1.sh`, `diy-part2.sh`
- Firmware overlay files: `files/`
- Flashing tool: `flashtool/`
- User-facing documentation: `README.md`, `README_EN.md`, `img/`

## Hard Rules

- Do not overwrite user changes. Check `git status --short` before editing.
- Before modifying any non-Markdown file, tell the user why the change is
  needed and which file or area will be changed, then wait for explicit
  permission to continue.
- Do not remove existing device profiles unless explicitly requested.
- Do not casually edit binary firmware, baseband, or flashing assets.
- Treat partition names, baseband backup/restore logic, and Fastboot operations
  as high-risk.
- Keep AI-facing documentation concise and action-oriented. Avoid duplicating the
  full README tutorial unless it helps future maintenance.
- When changing behavior, update the relevant AI-facing document if the project
  map, task flow, or risk boundary changed.

## Delivery Expectations

When completing a task, report:

- Files changed.
- Behavior changed.
- Verification performed, or why verification was not run.
- Remaining risk when the change touches build, firmware, flashing, or hardware.
