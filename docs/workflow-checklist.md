# Workflow Checklist

Use this file before executing GitHub Actions workflows.

## Path Change Watchlist

### Purpose

Track active repository path changes that may break GitHub Actions workflows.

### Rules

- Write here when a path is renamed, moved, removed, or replaced and any
  workflow-facing reference may still use the old path.
- Read this watchlist before dispatching any GitHub Actions workflow.
- Check each active record against the workflow and helper scripts being
  executed.
- Remove a record only when it is confirmed irrelevant to that workflow, or
  after all affected references are fixed and verified.
- Keep only active records here. Do not archive resolved records in this file.

### Active Records

No active path-change records.
