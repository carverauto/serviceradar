## 1. Implementation

- [ ] 1.1 Build a concrete old-versus-new parity matrix from the existing renderer, tests and documented behavior: infrastructure/attachment visibility, labels, picking and details, search and filtering, expansion/paging, status colors, traffic controls, Fit/Home, pan/zoom and detail entry/return. Link overlapping search/filter work in #4449 rather than implementing a competing path.
- [ ] 1.2 Fix regressions in the tile engine and bounded detail renderer. Audit existing ELK radial/forest adapters before rebuilding them.
- [ ] 1.3 Preserve #4749's typed schema-3/WebGPU layers and per-edge procedural packet animation.
- [ ] 1.4 The world overview uses persisted server coordinates. ELK remains the layout authority inside explicitly entered, bounded detail scenes. Do not run ELK on the entire million-device world or claim a coordinate grid alone proves ELK parity.
- [ ] 1.5 Preserve map camera/cache when entering and leaving details, correctly scoped Fit behavior, stable selection and compact location links.

## 2. Acceptance

- [ ] Publish the parity matrix with pass/fail evidence and explicit disposition for each supported behavior; fix unapproved losses.
- [ ] In a real hardware-WebGPU browser with traffic enabled, enter multiple invented neighborhoods/attachment pages and show actual ELK node/edge layouts, labels and usable picking.
- [ ] Reopening, paging, resizing and exiting details retain compatible camera/selection state and remain within scene budgets.
- [ ] Exercise direction changes, idle and stale traffic; packet animation must not depend on having multicast and broadcast counters.
- [ ] Run the existing browser/regression owners and record commit, workload, browser/GPU and failures. A passing mocked browser scenario is not a substitute for product UI verification.

## 3. Delivery

- [ ] 3.1 Validate this proposal with openspec validate --strict and run applicable remote checks.
- [ ] 3.2 Run make test and deliver code changes through no-mistakes with the srql-fixtures-only database restriction in the intent.
- [ ] 3.3 Record evidence and close only this issue after its own acceptance passes.
