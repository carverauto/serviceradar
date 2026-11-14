## 1. Preview delegation
- [ ] 1.1 `Targeting.count_target_devices/2` counts through `SNMPCompiler.reduce_target_pages/4` and maps read failure to `:unknown`
- [ ] 1.2 Delete the web-ng filter reimplementation (field/op tables, per-entity counters, NIF-direct parse)
- [ ] 1.3 Keep `normalize_target_query`, `extract_srql_entity`, `format_target_count`, `profile_target_query`, `resolve_target_query` and their callers unchanged

## 2. Regression tests
- [ ] 2.1 `target_preview_test.exs`: tag filter, in-list, builder-style like, equality, unfiltered, unparseable-counts-nothing, format cases (fail-first, then green on scratch DB)
- [ ] 2.2 Register the file in exactly one `NETWORKS_LIVE_DB_SHARD_SRCS` shard and `SHARED_FIXTURE_SOURCES`

## 3. Validation and landing
- [ ] 3.1 `openspec validate fix-default-snmp-profile-preview --strict`
- [ ] 3.2 `mix format --check-formatted`, `git diff --check`, Bazel `//build/elixir_quality:quality_check`
- [ ] 3.3 No-mistakes gate (reviewer is not claude), PR against staging, `gh pr merge --merge`
- [ ] 3.4 Demo verification: preview counts a narrowed query on the real Default profile; no hand edits
