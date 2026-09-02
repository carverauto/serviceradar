# Change: Harden SRQL query builder with query-mode capabilities

## Why

The web-ng SRQL query builder can emit queries the engine rejects. The catalog exposes a single flat `filter_fields` list per entity, while the Rust SRQL engine enforces different allowlists for row queries, stats queries (`stats:`), and downsample/chart queries (`bucket:` / `agg:`).

Concrete failure (observed on demo Flows chart):

```
in:flows time:last_1h bucket:5m agg:avg value_field:bytes_total series:app cidr:10.0.0.0/8 ...
SRQL error: unsupported filter field for downsample flows: 'cidr'
```

The builder offered CIDR because it is in the flows catalog. Chart mode routes through downsample filters, which historically rejected `cidr`; the current engine supports it. The same class of bug remains for row-only catalog fields such as `tag`, `near`, geo fields, and bare `port:`.

This change makes builder-advertised filter fields valid for the selected row or downsample path without rewriting the entire builder UI. Mode-specific operator capabilities remain separate work.

## What Changes

### 1. Row and downsample as first-class builder modes

Define the two modes represented by visual-builder state:

| Builder mode | How detected | Engine path |
|--------------|--------------|-------------|
| `row` | `bucket` is empty | entity row query |
| `downsample` | `bucket` is non-empty (chart) | downsample SQL |

`stats:` is a separate engine query path but is not represented by visual-builder state in this change. Stats queries remain available through freeform SRQL and may leave the builder unsupported and desynchronized rather than being normalized as row queries.

### 2. Mode-aware filter allowlists in the catalog
Extend the `flows` entity catalog so the builder can answer:

- Which filters are valid in the **current** mode?
- Which filters become invalid when the user enables chart mode?

### 3. Builder UX rules (prevent > silent rewrite)
- Filter field dropdown **only lists filters legal for the active mode**.
- Enabling chart (`bucket`) **drops illegal filters** and surfaces a short notice (count + names).
- Clearing chart knobs restores the full filter field list.
- Free-typed SRQL remains unchanged when the builder cannot represent it losslessly. Unparseable queries and parseable mode/filter conflicts use the desynchronized path (`builder_sync: false`) instead of silently dropping raw clauses.

### 4. Drift prevention
Add tests that reject flows downsample catalog entries absent from the documented current engine allowlist. Engine-supported fields may remain intentionally unadvertised when that omission is documented.

### 5. Current engine parity

Keep this change catalog-only: advertise fields the current engine accepts and hide unsupported fields. New engine filters belong in follow-up changes.

## Out of scope (for this change)

- Full visual redesign of the builder pill UI
- Making the builder support 100% of freeform SRQL
- Auto-rewriting free-typed bar content on every keystroke
- Visual-builder composition or mode-specific catalog filtering for `stats:`
- Pre-run validation or rewriting of free-typed/desynchronized SRQL
- Mode-aware catalogs for entities other than `flows`
- Engine filter additions
- A mode-specific filter-operator capability matrix

## Phased delivery

| Phase | Scope | Outcome |
|-------|--------|---------|
| **0** | Inventory the flows matrix and list later entity work | Known gaps documented |
| **1** | Catalog + builder modes for **flows** | Chart mode cannot pick illegal filters |
| **2** | Mode transition notices + synchronized apply path | Fail closed before SRQL when possible |
| **3** | Expand to next entities + engine parity PRs as needed | Same pattern elsewhere |

## Impact

- **Affected specs**: `srql` (query builder integration + new mode requirements)
- **Affected code**:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/builder.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/srql_components.ex` (builder UI)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/page.ex` (inline removal notice)
  - Tests under `elixir/web-ng/test/**/srql*`

## Related

- Current downsample flows support in `rust/srql/src/query/downsample/filters.rs`
- Historical demo failure: builder + chart + CIDR before current engine support
- Existing "Query Builder Integration" describes AND stacking but not builder modes
