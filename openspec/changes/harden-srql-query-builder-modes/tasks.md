## 1. Inventory (Phase 0)

- [x] 1.1 Confirm/refresh `matrix-flows.md` against current staging engine + catalog
- [x] 1.2 Draft stub matrices for `devices`, `attributed_flows`, `events`, `logs` (row vs stats vs downsample if any)
- [x] 1.3 List top known-broken builder combos still open after #4859 (e.g. chart + `tag`, chart + `near`, chart + `port`)

## 2. Catalog modes (Phase 1 — flows)

- [x] 2.1 Add `filter_fields_downsample` (or equivalent) to catalog entity schema + accessors
- [x] 2.2 Populate flows `filter_fields_downsample` from matrix (engine allowlist only)
- [x] 2.3 Keep `filter_fields` as row/default list; document aliases
- [x] 2.4 Unit tests: downsample list ⊆ engine allowlist fixture; row list covers advertised row filters

## 3. Builder compose + UI (Phase 1 — flows)

- [x] 3.1 `Builder` resolves active mode from state (`bucket` present → downsample)
- [x] 3.2 Filter field options use mode-specific allowlist
- [x] 3.3 `normalize_state` / bucket change: strip illegal filters; record stripped names
- [x] 3.4 Surface strip notice in builder UI (inline text or flash once)
- [x] 3.5 `build/parse` tests for chart + legal filter; chart + illegal filter stripped

## 4. Page / apply path (Phase 2)

- [x] 4.1 On `srql_builder_change` / apply, ensure draft never contains illegal mode+filter pairs when sync is true
- [ ] 4.2 Optional: pre-run validation message if draft still illegal (free-typed)
- [ ] 4.3 LiveView / component tests for mode switch stripping

## 5. Expand + engine parity (Phase 3+)

- [ ] 5.1 Repeat catalog/builder pattern for next priority entity
- [ ] 5.2 Engine PR: downsample `port:` if product wants chart parity (optional)
- [ ] 5.3 Engine or catalog: resolve BGP / tag / near chart expectations
- [ ] 5.4 Document operator guidance: freeform SRQL vs builder subset

## 6. Validation

- [x] 6.1 `openspec validate harden-srql-query-builder-modes --strict`
- [x] 6.2 Elixir SRQL builder tests green
- [ ] 6.3 Manual demo: flows chart mode cannot select `tag`; enabling bucket drops illegal filters with notice; `cidr` remains available after #4859
