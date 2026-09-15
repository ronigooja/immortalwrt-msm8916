# Task Playbooks

Use this file as the first practical checklist before changing the repository.
For hardware, partition, kernel, or flashing work, also read
`docs/risk-boundaries.md`.

## Task Types

### Feature

Use for new capabilities such as a new device profile, package option, workflow
input, firmware default, documentation, or helper script.

Default flow:

1. Define the user-visible value and affected areas.
2. Find the closest existing implementation.
3. Make the smallest complete implementation.
4. Update user-facing or AI-facing docs when behavior changes.
5. Verify the main path.

Report:

- What was added.
- How users activate or use it.
- Whether defaults changed.
- Whether existing devices, builds, or firmware behavior are affected.

### Optimization

Use for improving speed, size, reliability, maintainability, or UI quality while
preserving intended behavior.

Default flow:

1. State the optimization target.
2. Identify the current bottleneck, waste, or repeated work.
3. Keep behavior compatible unless the user asked for a tradeoff.
4. Describe the before/after difference.
5. Verify there is no obvious regression.

Report:

- What was optimized.
- Expected benefit.
- Behavior compatibility.
- Any tradeoff or remaining uncertainty.

### Refactoring

Use for reorganizing code, scripts, docs, names, or structure without intending
to change behavior.

Default flow:

1. Confirm existing behavior first.
2. Keep changes small and reviewable.
3. Avoid mixing feature work into the refactor.
4. Preserve paths, inputs, outputs, and user-facing behavior where possible.
5. Run the narrowest useful validation.

Report:

- Refactor scope.
- Behavior that should remain unchanged.
- Validation result.
- Any risk from touched shared code.

### Troubleshooting

Use for build failures, package conflicts, flashing failures, boot problems,
network issues, documentation issues, or unclear regressions.

Default flow:

1. Collect the error, logs, reproduction context, and recent changes.
2. Locate the failing stage.
3. Form the smallest likely hypothesis.
4. Test or inspect one main cause at a time.
5. Fix the root cause when possible, then record the verification path.

Report:

- Root cause, or strongest current hypothesis.
- Fix or diagnostic result.
- Verification performed.
- Next diagnostic step if unresolved.

## Long-Running Work

Most tasks do not need saved state. Use saved state only when work spans multiple
conversations, is paused before completion, touches high-risk areas, or the user
explicitly asks to record progress.

When saved state is needed:

- Use `docs/task-state-template.md` as the format.
- Save records under `docs/task-states/YYYY-MM-DD-short-task-name.md`.
- Do not create `docs/task-states/` until there is a real task state to save.
- Keep saved state factual: goal, phase, files read, files changed, decisions,
  verification, risks, and next step.

## Change A Device Profile

Read:

- `.github/workflows/build-immortalwrt-msm8916.yml`
- Existing `config/*.config`
- `README.md`
- `README_EN.md`

Common edits:

- Add or update `config/{profile}.config`.
- Add or update the workflow `profile` choice.
- Update supported-device tables in both READMEs.

Verify:

- The profile name matches the config file name exactly.
- The workflow `CONFIG_FILE` expression still resolves to the expected path.
- Existing profiles were not removed unintentionally.

## Change Build Feeds Or Packages

Read:

- `diy-part1.sh`
- `diy-part2.sh`
- `.github/workflows/build-immortalwrt-msm8916.yml`
- README sections listing default packages and packages that should not be
  duplicated.

Common edits:

- Add source repositories in `diy-part1.sh`.
- Add post-feed package/config tweaks in `diy-part2.sh`.
- Adjust extra-package handling in the workflow only when input parsing or build
  behavior must change.

Verify:

- Feed changes happen before `./scripts/feeds update -a`.
- Package path changes happen after feeds are installed.
- New defaults do not duplicate packages already built into the base image.

## Change Firmware Overlay

Read:

- `docs/project-map.md`
- Relevant files under `files/`
- README sections that describe default behavior.

Common edits:

- First-boot defaults: `files/etc/uci-defaults/`
- Runtime scripts: `files/usr/sbin/`
- Init behavior: `files/etc/init.d/`

Verify:

- Shell scripts remain executable if they are meant to run on-device.
- UCI defaults are idempotent and safe on first boot.
- Network, SSH, and WAN defaults are documented when behavior changes.

## Change GitHub Actions

Read:

- Target workflow under `.github/workflows/`
- `docs/project-map.md`
- `docs/risk-boundaries.md`
- `scripts/setup-self-hosted-runner.sh` when self-hosted runner behavior or
  setup changes

Common edits:

- Build inputs, cache keys, package install steps, release naming, or upstream
  hash selection.
- Runner setup helper defaults, labels, service installation, or token handling.

Verify:

- Required permissions are still present.
- Cache keys include files that affect build output.
- For self-hosted runner work, confirm the runner appears online in the GitHub
  Actions API and the `build` job uses the expected runner name.
- `upstream_lock.txt` and `upstream_history.txt` are only changed by an explicit
  maintenance task.

## Change The Flashing Tool

Read:

- `flashtool/main.go`
- `flashtool/fastboot/`
- `flashtool/winenv/`
- `.github/workflows/Build_刷机工具.yml`
- `docs/risk-boundaries.md`

Common edits:

- User prompts and validation in `main.go`.
- Fastboot protocol behavior in `flashtool/fastboot/`.
- Windows driver/helper setup in `flashtool/winenv/`.
- Cross-platform release packaging in the flashing-tool workflow.

Verify:

- `go test ./...` from `flashtool/` when tests exist or compile checks are
  possible.
- `go build ./...` from `flashtool/` for local compile validation.
- Partition and baseband behavior is explicitly called out in the final report.
