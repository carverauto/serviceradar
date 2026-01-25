## Context
Sysmon profiles are currently modeled with an `is_default` flag that drives fallback behavior and UI protections. This makes SRQL targeting hard to reason about and masks cases where no profile matches a device.

## Goals / Non-Goals
- Goals:
  - Remove the `is_default` flag from sysmon profiles.
  - Make SRQL target matching the only remote profile resolution mechanism.
  - Allow devices to be truly unassigned (no sysmon profile) when no match exists.
- Non-Goals:
  - Changing SNMP profile defaults.
  - Redesigning the sysmon UI beyond removing default-specific behavior.

## Decisions
- Decision: Drop the `is_default` column and stop creating or protecting a default sysmon profile.
- Decision: If no SRQL profile matches and no local sysmon.json is present, the control plane returns a disabled sysmon config and the agent does not collect sysmon metrics.
- Decision: UI and APIs show "Unassigned" when no profile is applied.

## Risks / Trade-offs
- Existing deployments relying on the default profile will see sysmon disabled until a profile is created or assigned.
  - Mitigation: Call out the breaking change in release notes and provide a migration guide.

## Migration Plan
1. Add an Elixir migration to drop `is_default` from sysmon profile storage.
2. Remove `is_default` from Ash resources and any profile bootstrapping.
3. Update config resolution to return disabled config when no match exists.
4. Update UI strings and flows to reflect the unassigned state.

## Open Questions
- Should the agent retain the last valid config when no profile matches, or immediately disable sysmon? (Current plan: disable.)
