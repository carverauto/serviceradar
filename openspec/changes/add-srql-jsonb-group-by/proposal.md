# Change: Group device stats by a JSONB sub-key (`tags.<key>` / `metadata.<key>`)

## Why

Device GROUP BY is limited to a fixed set of scalar columns. Every dimension an
operator introduces themselves lives in the `tags` JSONB map -- gate, site,
controller, role -- and none of it can be aggregated. Charting "devices per
gate" for an airport display fleet means issuing one query per gate (78 of them
for a single airport), which is not a dashboard so much as a workaround.

`tags.<key>` and `metadata.<key>` are already first-class in *filters*. The
asymmetry is the whole problem: you can narrow to a tag but you cannot count by
one.

Three defects surfaced while building this, each of which independently broke
the same target query, and each of which is in scope here because a proposal
that adds grouping while leaving them in place would ship a capability that
still cannot run:

1. Grouped stats accept `metadata.<key>` filters but reject `tags.<key>` and the
   bare `tags:<key>` existence check, so filtering by one tag while grouping by
   another fails.
2. JSONB sub-key filters implement only equality and LIKE; the list form
   `tags.gate:(B40,B41)` errors.
3. Grouped-stats SQL is emitted with `?` placeholders and rewritten to `$n`
   only on the translate path. The execute path passed raw SQL to the driver,
   so **every filtered grouped device query was a Postgres syntax error at
   runtime** while translation-only tests stayed green. This predates the tag
   work -- `vendor_name:Cisco stats:count() as total by type` fails on `staging`
   today.

A fourth, quieter one: field names are case-folded wholesale, but Postgres JSONB
keys are case-sensitive and tag ingestion preserves the operator's casing. So
`tags.Gate` silently probes `tags->>'gate'` and matches nothing.

## What Changes

### Grouping
- **ADD** `tags.<key>` and `metadata.<key>` as device stats grouping fields.
  Rows missing the key group under `Unknown`, consistent with how `type` and
  `vendor_name` already bucket NULLs.
- The grouped response names the column by its full path (`tags.gate`), which is
  also what `sort:` accepts.
- The JSONB key is interpolated into SQL rather than bound -- Postgres has no
  bind placeholder for a key -- so it passes the same `is_valid_jsonb_key`
  whitelist the existing sub-key filters use.

### Filtering (parity fixes required to make grouping usable)
- **MODIFY** grouped stats to accept `tags.<key>` and bare `tags:<key>` filters,
  matching the `metadata.<key>` support already present.
- **MODIFY** JSONB sub-key filters to accept the list form (`In` / `NotIn`).
  A negated list keeps rows missing the key entirely, since `NULL <> x` is NULL.
- **MODIFY** field-name normalization so only the namespace is case-folded and
  the JSONB key keeps the casing the operator wrote -- in filters and grouping
  alike, so the two cannot disagree.

### Execution correctness
- **MODIFY** the device execute path to rewrite `?` placeholders to `$n` before
  handing SQL to the driver, as the process-metrics and OTEL-metric-point paths
  already do.
- The grouped tag-existence check is spelled `jsonb_exists` / `jsonb_exists_any`
  rather than the `?` / `?|` operators, because placeholder rewriting would
  otherwise turn the operator into a bind placeholder.

## Impact

- Affected specs: `srql`
- Affected code: `rust/srql/src/query/devices/**`, `rust/srql/src/parser/filters.rs`
- Docs: `docs/docs/srql-language-reference.md`
- **Behavior change**: `tags.Foo` / `metadata.Foo` filters now address the key as
  written instead of lowercasing it. A query relying on the old folding to reach
  a lowercase key must be written with the key's real casing. This is the same
  correction the grouping path needs, and leaving the two inconsistent would be
  worse than either uniform behavior.
- No schema migration. No API shape change.
