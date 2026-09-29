## Goal and ownership

Completion gate for #4774 and #4901. Keep the current workstream focused on the mapping/topology engine. Audit the previous working topology experience and prove the replacement preserves its operator behavior.

## Scope

- Build a concrete old-versus-new parity matrix from the existing renderer, tests and documented behavior: infrastructure/attachment visibility, labels, picking and details, search and filtering, expansion/paging, status colors, traffic controls, Fit/Home, pan/zoom and detail entry/return. Link overlapping search/filter work in #4449 rather than implementing a competing path.
- Fix regressions in the tile engine and bounded detail renderer. Audit existing ELK radial/forest adapters before rebuilding them.
- Preserve #4749's typed schema-3/WebGPU layers and per-edge procedural packet animation.
- The world overview uses persisted server coordinates. ELK remains the layout authority inside explicitly entered, bounded detail scenes. Do not run ELK on the entire million-device world or claim a coordinate grid alone proves ELK parity.
- Preserve map camera/cache when entering and leaving details, correctly scoped Fit behavior, stable selection and compact location links.

## Acceptance

- [ ] Publish the parity matrix with pass/fail evidence and explicit disposition for each supported behavior; fix unapproved losses.
- [ ] In a real hardware-WebGPU browser with traffic enabled, enter multiple invented neighborhoods/attachment pages and show actual ELK node/edge layouts, labels and usable picking.
- [ ] Reopening, paging, resizing and exiting details retain compatible camera/selection state and remain within scene budgets.
- [ ] Exercise direction changes, idle and stale traffic; packet animation must not depend on having multicast and broadcast counters.
- [ ] Run the existing browser/regression owners and record commit, workload, browser/GPU and failures. A passing mocked browser scenario is not a substitute for product UI verification.

## Proposal ownership

This proposal owns its own tasks and deltas. See proposal.md for dependencies.

## Delivery and isolation

Use treehouse and remote RBE with --config=remote; no Docker, local compilation
or new shell scripts. Automated database tests use srql-fixtures scratch DB only.
All fixtures are independently invented. Use migrations for schema changes.
Run required checks and make test before a PR; deliver every PR through no-mistakes.
