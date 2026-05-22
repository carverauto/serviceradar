## Context
Plugin package versions are separate rows, while agent assignments point at one concrete `plugin_package_id`. Recent single-enabled-assignment enforcement correctly prevents an agent from running two enabled versions of the same logical plugin, but the operator workflow still assumes remove-and-recreate. That workflow is fragile and currently crashes when the delete path returns bare `:ok`.

## Goals / Non-Goals
- Goals:
  - Make delete assignment behavior crash-free.
  - Provide a first-class assignment upgrade path from one approved package version to another.
  - Keep the one-enabled-assignment-per-agent/plugin invariant intact.
  - Preserve existing assignment configuration when it remains valid for the target version.
- Non-Goals:
  - Do not allow multiple enabled versions of one plugin on the same agent.
  - Do not bypass policy-owned assignment rules from the manual package UI.
  - Do not introduce a new plugin package data model unless implementation proves it necessary.

## Decisions
- Decision: Prefer in-place assignment update over delete-and-create for upgrades.
  - Why: In-place updates preserve identity, audit timestamps, source metadata, and service-state relationships better than tearing down and recreating rows.
- Decision: Expose upgrade as an explicit context function rather than composing generic UI update calls.
  - Why: The operation has domain constraints: target package must be approved, logical plugin IDs must match, params must validate against the target schema, and policy-owned assignments need different handling.
- Decision: Treat "latest" as the newest approved package version using existing package ordering first, then tighten to semver ordering if current helpers are ambiguous.
  - Why: The UI already lists versions; this change should align with existing package semantics unless tests expose incorrect ordering.
- Decision: Allow multiple approved package versions for the same logical plugin.
  - Why: The safety invariant is one enabled assignment per agent/plugin, not one approved package globally. Operators need older approved versions available for explicit rollback or selected-version upgrades.

## Risks / Trade-offs
- Risk: Target package config schema can require new fields.
  - Mitigation: validate before update and show a specific message asking the operator to choose a version or edit config.
- Risk: Policy-owned assignments may be recreated by reconciliation if manually changed.
  - Mitigation: block manual upgrades for policy-owned rows and point users to the policy surface.
- Risk: Existing delete callers depend on `:ok`.
  - Mitigation: document and test the chosen return shape, or handle both return shapes at call sites.
- Risk: Multiple approved package versions can make implicit package selection ambiguous.
  - Mitigation: assignment materialization and "latest" selection use semver ordering first, then import/approval/insert timestamps as tie breakers.

## Migration Plan
Drop the partial unique index that allowed only one approved package per plugin. Existing assignments keep their current package IDs until an operator or policy explicitly upgrades them.

## Open Questions
- Should compatible defaults from the target package schema be merged during upgrade when params omit newly optional fields?
