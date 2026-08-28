# Design: SRQL builder query modes

## Context

Three layers disagree today:

1. **Catalog** — flat `filter_fields` used by the builder dropdown
2. **Builder** — composes tokens; weak mode awareness (only knows entity has `downsample: true`)
3. **Engine** — separate match arms for row (`flows/filters.rs`), stats (`flows/stats/filters.rs`), downsample (`downsample/filters.rs`)

Contract we want: **any query the builder emits while in sync SHOULD execute successfully** on the engine for that mode.

## Mode detection

```
if query has stats:     → mode = stats
else if query has bucket: → mode = downsample
else                      → mode = row
```

Builder state equivalent:

```
if bucket is non-empty → downsample
else if stats present  → stats (future builder support; may stay parse-only initially)
else                   → row
```

v1 focuses on **row vs downsample** because that is what the builder UI knobs expose (`bucket` / `agg` / `value_field` / `series`).

## Catalog shape (proposed)

Prefer additive, non-breaking fields on entity config:

```elixir
# Existing
filter_fields: [...],      # continues to mean "row" (and builder default when no bucket)
downsample: true | false,

# New (optional; absent = same as filter_fields for row-only entities)
filter_fields_downsample: [...],  # if nil and downsample: true → must be filled for scoped entities
```

Helpers:

- `Catalog.filter_fields(entity, mode)` → list for UI + normalize
- Default: `mode: :row` → `filter_fields`; `mode: :downsample` → `filter_fields_downsample` or empty/error if missing when `downsample: true`

**Do not** invent fields the engine rejects. Catalog is a projection of engine allowlists.

## Builder behavior

### Field dropdown
- Source = `Catalog.filter_fields(entity, current_mode)`
- When user has invalid field already selected (mode switch), strip on normalize

### Mode switch: empty → non-empty bucket
1. Compute illegal = filters whose field ∉ downsample allowlist  
2. Remove them from builder state  
3. Flash / inline note: `"Removed N filter(s) not available in chart mode: tag, near, …"`  
4. Rebuild draft

### Mode switch: non-empty bucket → empty
- Keep filters; expand dropdown to full row list

### Free text vs builder sync
- Unchanged: unparseable free text → `builder_supported: false`, no silent rewrite of the bar
- This change only affects **builder-driven** compose when sync is true

## Drift tests (flows first)

Table-driven test:

- Parse Rust downsample arms (or maintain a mirrored allowlist constant in Elixir tests generated from a shared fixture)
- Pragmatic v1: **Elixir unit test** asserts every `filter_fields_downsample` entry for flows is in a hard-coded list kept next to a comment pointing at `downsample/filters.rs`
- Better v2: small Rust test or fixture file `flows_downsample_filters.txt` checked by both

## Error UX priority

1. Prevent illegal selection (dropdown)  
2. Strip + notice on mode transition  
3. Pre-run validation message  
4. Engine error (last resort)

## Non-goals

- Auto-removing free-typed illegal tokens without user opening the builder  
- Full stats-mode builder UI in phase 1  
- Enum/CIDR/near specialized widgets (later polish)

## Rollout

1. Spec + matrix (this change docs)  
2. Implement flows only behind normal staging merge  
3. Expand entity matrices incrementally  
4. Engine PRs only for high-value advertised fields
