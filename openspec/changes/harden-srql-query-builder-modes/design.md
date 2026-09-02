# Design: SRQL builder query modes

## Context

Three layers disagree today:

1. **Catalog** - flat `filter_fields` used by the builder dropdown
2. **Builder** - composes tokens; weak mode awareness (only knows entity has `downsample: true`)
3. **Engine** - separate match arms for row (`flows/filters.rs`), stats (`flows/stats/filters.rs`), downsample (`downsample/filters.rs`)

Contract for this change: every filter field the builder advertises in a mode is accepted by the corresponding engine path. Operator capabilities are deferred until they have their own verified matrix.

## Builder mode detection

```text
if bucket is non-empty -> downsample
else                    -> row
```

These are the only modes represented by builder state in this change.

`stats:` remains an engine/freeform capability. `Builder.parse/1` does not model a stats expression, so a stats query may set `builder_supported: false` and `builder_sync: false`; the page preserves the raw query instead of applying the row allowlist or rebuilding it. A later stats-builder change must add explicit stats state and a verified stats allowlist before composing stats queries.

## Catalog shape (proposed)

Prefer additive, non-breaking fields on entity config:

```elixir
# Existing
filter_fields: [...],      # continues to mean "row" (and builder default when no bucket)
downsample: true | false,

# New (optional; absent = same as filter_fields for row-only entities)
filter_fields_downsample: [...],  # if nil and downsample: true, must be filled for scoped entities
```

Helpers:

- `Catalog.filter_fields(entity, mode)` returns the list used by the UI and normalizer.
- `:row` returns `filter_fields`.
- `:downsample` returns `filter_fields_downsample` when explicitly configured.
- Unscoped entities preserve the existing row-list fallback for compatibility; that fallback is not a claim of engine parity. This change hardens only `flows`.

**Do not** invent fields the engine rejects. Catalog is a projection of engine allowlists.

## Builder behavior

### Field dropdown
- Source = `Catalog.filter_fields(entity, current_mode)`
- When a builder-driven mode switch makes a selected field invalid, strip it during the update and report it to the page

### Mode switch: empty to non-empty bucket
1. Compute illegal filters whose fields are not in the downsample allowlist.
2. Remove them from builder state.
3. Show an inline note: `"Removed N filter(s) not available in chart mode: tag, near, ..."`.
4. Rebuild draft

### Mode switch: non-empty bucket to empty
- Keep filters; expand dropdown to full row list

### Free text vs builder sync
- Unparseable free text sets `builder_supported: false` with no silent rewrite of the bar.
- `Builder.parse/1` also returns an error when normalization would have to drop a mode-illegal raw filter. Callers preserve the exact query and mark builder sync false instead of accepting a lossy builder state.
- Filter stripping only affects **builder-driven** mode transitions while sync is true.

## Drift tests

The Elixir fixture mirrors the current `flows_filter_clause` engine arms, including engine-only `device_addr` and `device_address`. The test asserts that the builder-advertised downsample list is a subset of that fixture. Equality is intentionally not required because engine-supported fields may be withheld from manual builder composition.

A second contract test feeds every advertised downsample field through builder normalization. This prevents a chart option from being silently rewritten because it was missing from the row-superset catalog.

## Error UX priority

1. Prevent illegal selection (dropdown)
2. Strip + notice on mode transition
3. Future pre-run validation message
4. Engine error (last resort)

## Non-goals

- Auto-removing free-typed illegal tokens without user opening the builder
- Any stats-mode visual-builder support
- A mode-specific filter-operator capability matrix
- Enum/CIDR/near specialized widgets (later polish)

## Coordination with active SRQL changes

- `add-srql-timeseries-tag-dimensions` and `add-srql-downsample-tag-filters` apply to `timeseries_metrics tags.<key>` only. They do not make flows prefix-tag filters (`tag`, `src_tag`, `dst_tag`) valid in downsample.
- `enhance-srql-search-input` consumes public catalog JSON. Row `filter` and `filter_downsample` inventories remain distinct and must not be flattened.
- `fix-srql-dashboard-authoring-ux` owns editor/dashboard authoring UX. This change only constrains visual-builder filter composition and removal notices.

## Rollout

1. Spec + matrix (this change docs)
2. Implement flows only behind normal staging merge
3. Expand entity matrices incrementally
4. Engine PRs only for high-value advertised fields
