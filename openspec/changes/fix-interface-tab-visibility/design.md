## Context
Operators use discovery jobs to populate network interface data. When SRQL returns no interface rows, the Interfaces tab is hidden, which masks discovery failures or data retention gaps. The discovery job editor currently allows manual agent-id entry, enabling invalid assignments with no feedback.

## Goals / Non-Goals
- Goals:
  - Prevent discovery jobs from being saved with invalid agent assignments.
  - Provide clear diagnostics for discovery job execution and interface visibility in device details.
  - Preserve SRQL as the source of interface rows while surfacing actionable empty states.
- Non-Goals:
  - Changing SRQL retention policies or data model semantics.
  - Reworking discovery pipelines beyond validation and status reporting.

## Decisions
- Decision: Add server-side validation that discovery job agent assignments exist and are eligible; surface the agent list in the UI as a dropdown.
- Decision: Persist discovery job run diagnostics (timestamp, status, interface count, error) and expose them in the discovery job API response.
- Decision: Keep SRQL as the interface data source, but show the Interfaces tab when a discovery job targets the device and provide an empty-state with last run diagnostics when no rows are returned.

## Risks / Trade-offs
- Additional API fields require UI updates across discovery settings and device detail pages.
- Devices without discovery jobs may still hide the Interfaces tab when no SRQL rows exist; this is intentional to avoid confusing non-network devices.

## Migration Plan
- Add nullable metadata fields for discovery job run diagnostics via standard Elixir migrations if required.
- Backfill is not required; missing diagnostics should render a generic empty state.

## Open Questions
- How should the system determine that a discovery job targets a device (by seed match, job-to-device mapping, or explicit linkage)?
- Should empty-state messaging include a retention window hint (e.g., "no interface data in the last 3 days")?
