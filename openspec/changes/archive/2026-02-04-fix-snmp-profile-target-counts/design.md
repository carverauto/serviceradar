## Context
SNMP profiles use SRQL `target_query` strings to match devices or interfaces. The SNMP profiles list currently renders a static "0 targets" badge and the default profile lacks a normalized query, leading the UI to show interface targeting even when `in:devices` should be the default. The edit form already parses SRQL, but its count semantics do not clearly distinguish devices vs interfaces.

## Goals / Non-Goals
- Goals:
  - Provide accurate, trustworthy target counts for SNMP profiles in the list and edit views.
  - Ensure empty/missing target queries default to `in:devices` for both targeting and display.
  - Treat interface-targeting queries as device targets by counting distinct devices.
- Non-Goals:
  - Redesign the SRQL language or change query semantics beyond SNMP profile targeting.
  - Add new SNMP data sources or alter device/interface storage.

## Decisions
- Decision: Normalize SNMP profile target queries to `in:devices` when empty (consistent with validation defaults) and reflect this in the UI label for default profiles.
- Decision: Target counts represent distinct device targets. Interface queries (`in:interfaces ...`) are reduced to a distinct device count rather than raw interface rows.
- Decision: The UI displays "Unknown" when target count evaluation fails or the query is invalid, avoiding silent "0" values.

## Risks / Trade-offs
- Counting targets per profile can be expensive if evaluated synchronously for large inventories.
  - Mitigation: cache counts for a short interval or evaluate counts asynchronously with loading states.

## Migration Plan
- Update default SNMP profile seeding/normalization to set `target_query` to `in:devices` when empty.
- Update SNMP profile UI to request and display counts using normalized queries.
- Add/adjust tests to cover default query normalization and count rendering.

## Open Questions
- Should the list view show live counts for all profiles or only on-demand (expand/hover) to reduce load?
- Should interface queries display both interface and device counts, or only device counts?
