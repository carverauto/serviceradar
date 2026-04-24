## 1. Implementation
- [ ] 1.1 Audit current `/settings/auth/access` UX and capture a before/after checklist of features that must remain available (role mappings, clone, create, delete, save).
- [ ] 1.2 Define the UI permission grid mapping strategy (permission key -> {resource, action}) and document edge cases (multi-part resources like `settings.auth.manage`).
- [ ] 1.3 Implement the new policy editor layout in LiveView (profile cards horizontally stacked; grid inside each card).
- [ ] 1.4 Implement bulk toggles (toggle action row, toggle resource column, clear all, select all) per profile card.
- [ ] 1.5 Add dirty state, per-profile save, and optional "save all" UX with clear success/error affordances.
- [ ] 1.6 Remove the persistent legend and redundant header/stats UI; replace with minimal inline help and concise copy.
- [ ] 1.7 Add/adjust API client calls as needed (optionally add a single aggregated fetch endpoint to reduce loading jitter).
- [ ] 1.8 Add tests:
  - LiveView render + interaction coverage for toggling, dirty state, and save behavior
  - Regression tests for permission key mapping into the grid

