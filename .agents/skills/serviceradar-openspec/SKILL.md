---
name: serviceradar-openspec
description: Use when creating, changing, validating, or archiving a ServiceRadar OpenSpec proposal, delta, requirement, or specification.
user-invocable: false
metadata:
  internal: true
---

# ServiceRadar OpenSpec Rules

- **OpenSpec**: See [Requirement Wording](openspec/AGENTS.md#requirement-wording)
  for the SHALL/MUST positional validation rule and examples.

  **Editing a requirement in `openspec/specs/` is not enough.** A pending change
  under `openspec/changes/` may carry its own `## MODIFIED Requirements` copy of
  the same `### Requirement:` block, and archiving that change replays its copy
  over `specs/` -- silently restoring the wording you just removed, with nothing
  in the archive step to flag the conflict. Before amending a requirement, run
  `grep -rn "<the exact bullet>" openspec/` and fix every pending delta that
  repeats it. Leave the copies under `openspec/changes/archive/` alone: they
  record what was true at the time, and rewriting them falsifies the record.
