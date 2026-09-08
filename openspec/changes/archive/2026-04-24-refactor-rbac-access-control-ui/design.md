## Context
The existing RBAC Access Control view mixes role mapping configuration, profile management, and a permission list in a layout that is difficult to scan and awkward to edit at speed.

Admins want a single, opinionated policy editor experience: profiles are the primary unit of work, and permissions should be editable via a compact grid similar to permit.io’s policy editor.

## Goals / Non-Goals
- Goals:
  - Make it fast to compare and edit permissions across profiles.
  - Keep everything relevant to RBAC profile configuration on one page.
  - Preserve existing RBAC semantics (this is a UX refactor, not an authorization model redesign).
- Non-Goals:
  - Introduce ABAC rules, condition builders, or new policy languages.
  - Add multitenancy or per-customer routing modes.

## Decisions
- Primary layout:
  - The page is organized around a horizontally scrollable list of profile cards.
  - Each card is self-contained: header (name/type/actions), grid, and save status.
- Grid mapping:
  - Permission keys are mapped into `{resource, action}` pairs for the grid.
  - Default mapping rule: split the permission key by `.` and treat the last segment as `action`, with the prefix as `resource`.
    - Example: `devices.delete` -> resource `devices`, action `delete`
    - Example: `settings.auth.manage` -> resource `settings.auth`, action `manage`
  - Action ordering is stable and comes from the canonical catalog (not inferred from UI toggles).
- Bulk editing:
  - Support toggling an entire action (row) for a profile and toggling all actions for a resource (column) for a profile.
  - Bulk actions operate only within the active profile card (no cross-profile bulk changes).
- Data loading:
  - Prefer one fetch for the RBAC editor payload (catalog + profiles; optional assignment counts) to reduce UI jitter.
  - Fallback remains compatible with existing list endpoints.

## Risks / Trade-offs
- Large catalogs can create wide tables; nested horizontal scrolling can become confusing.
  - Mitigation: keep actions as rows and resources as columns only when resource count is bounded; otherwise, use a per-card internal scroll area and keep headers sticky.
- Permission key mapping must remain stable; incorrect mapping yields missing or mis-grouped grid cells.
  - Mitigation: add mapping unit tests and keep a small "unmapped permissions" section in each card when needed.

## Migration Plan
- Replace the LiveView layout and interactions without changing persisted permission keys.
- Keep existing API endpoints; optionally add a new aggregated endpoint for the editor payload.

## Open Questions
- Do we want a global "Save All" action, or only per-profile save, for the initial iteration?

