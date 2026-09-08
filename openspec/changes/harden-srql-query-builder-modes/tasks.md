## 1. Inventory (Phase 0)

- [x] 1.1 Confirm/refresh `matrix-flows.md` against current staging engine + catalog
- [x] 1.2 List next-entity inventory stubs for `devices`, `attributed_flows`, `events`, and `logs`
- [x] 1.3 List top known-broken builder combinations (for example chart + `tag`, chart + `near`, and chart + `port`)

## 2. Catalog modes (Phase 1 - flows)

- [x] 2.1 Add `filter_fields_downsample` (or equivalent) to catalog entity schema + accessors
- [x] 2.2 Populate flows `filter_fields_downsample` from matrix (engine allowlist only)
- [x] 2.3 Keep `filter_fields` as row/default list; document aliases
- [x] 2.4 Unit tests: downsample list is a subset of the engine allowlist fixture; row list covers advertised row filters
- [x] 2.5 Keep the flows row allowlist a superset of every manually advertised downsample field

## 3. Builder compose + UI (Phase 1 - flows)

- [x] 3.1 `Builder` resolves active mode from state (`bucket` present means downsample)
- [x] 3.2 Filter field options use mode-specific allowlist
- [x] 3.3 `normalize_state` / bucket change: strip illegal filters; record stripped names
- [x] 3.4 Surface strip notice in builder UI (inline text or flash once)
- [x] 3.5 `build/parse` tests for chart + legal filter; mode-invalid raw parse rejected without clause loss
- [x] 3.6 Clearing the bucket preserves row mode instead of restoring the default chart bucket

## 4. Page / apply path (Phase 2)

- [x] 4.1 On `srql_builder_change` / apply, ensure draft never contains illegal mode+filter pairs when sync is true
- [x] 4.2 Preserve `stats:` and parseable mode/filter conflicts on the desynchronized path without pre-run rewriting
- [x] 4.3 Page-event and component tests cover mode-switch stripping and field visibility

## 5. Deferred follow-ups (not completion criteria)

- Repeat the catalog/builder pattern for the next priority entity.
- Add downsample `port:` engine support if the product wants chart parity.
- Resolve flows tag/near chart expectations through separate engine changes.
- Add a verified per-mode operator matrix before claiming operator-level parity.

## 6. Validation

- [x] 6.1 `openspec validate harden-srql-query-builder-modes --strict`
- [x] 6.2 Focused Elixir SRQL builder/page/component tests green on the rebased branch
- [ ] 6.3 Manual demo: flows chart mode excludes `tag`; enabling bucket drops illegal filters with an accurate notice; `cidr` remains available
