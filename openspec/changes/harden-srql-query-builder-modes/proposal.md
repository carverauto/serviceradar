# Change: Harden SRQL query builder with query-mode capabilities

## Why

The web-ng SRQL query builder can emit queries the engine rejects. The catalog exposes a single flat `filter_fields` list per entity, while the Rust SRQL engine enforces **different allowlists** for row queries, stats queries (`stats:`), and downsample/chart queries (`bucket:` / `agg:`).

Concrete failure (observed on demo Flows chart):

```
in:flows time:last_1h bucket:5m agg:avg value_field:bytes_total series:app cidr:10.0.0.0/8 ...
→ SRQL error: unsupported filter field for downsample flows: 'cidr'
```

The builder offered CIDR because it is in the flows catalog. Chart mode routes through downsample filters, which historically rejected `cidr` (engine fixed in #4859). The same class of bug remains for other catalog fields that are still illegal on downsample (e.g. `tag`, `near`, geo, BGP arrays, bare `port:`).

We need a **pragmatic** program: make builder-composed queries executable by default, without rewriting the entire builder UI.

## What Changes

### 1. Query modes as a first-class concept
Define modes the builder and catalog share:

| Mode | How detected | Engine path |
|------|----------------|-------------|
| `row` | no `bucket:` / no `stats:` | entity row query |
| `stats` | `stats:` present | stats aggregation |
| `downsample` | `bucket:` present (chart) | downsample SQL |

### 2. Mode-aware filter allowlists in the catalog
Extend the entity catalog (starting with **flows**, then high-traffic entities) so the builder can answer:

- Which filters are valid in the **current** mode?
- Which filters become invalid when the user enables chart mode?

### 3. Builder UX rules (prevent > silent rewrite)
- Filter field dropdown **only lists filters legal for the active mode**.
- Enabling chart (`bucket`) **drops illegal filters** and surfaces a short notice (count + names).
- Clearing chart knobs restores the full filter field list.
- Free-typed SRQL remains allowed; builder desync (`builder_sync: false`) behavior stays as-is for unparseable queries.

### 4. Drift prevention
Add tests so catalog downsample allowlists cannot silently diverge from the Rust downsample match arms for scoped entities (start with flows).

### 5. Engine parity (as needed)
Where the product already advertises a field on charts, prefer engine support (as with #4859 `cidr`) over permanently hiding it—when cheap and correct. Otherwise hide until supported.

## Out of scope (for this change)

- Full visual redesign of the builder pill UI
- Making the builder support 100% of freeform SRQL
- Auto-rewriting free-typed bar content on every keystroke
- Exhaustive matrices for every SRQL entity on day one

## Phased delivery

| Phase | Scope | Outcome |
|-------|--------|---------|
| **0** | Inventory matrices (flows first; then devices, attributed_flows, events, logs) | Known gaps documented |
| **1** | Catalog + builder modes for **flows** | Chart mode cannot pick illegal filters |
| **2** | Mode transition notices + apply/run pre-check | Fail closed before SRQL when possible |
| **3** | Expand to next entities + engine parity PRs as needed | Same pattern elsewhere |

## Impact

- **Affected specs**: `srql` (query builder integration + new mode requirements)
- **Affected code** (implementation later, after approval):
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/builder.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/srql_components.ex` (builder UI)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/page.ex` (optional flash on strip)
  - `rust/srql/src/query/downsample/filters.rs` (parity only when product requires)
  - Tests under `elixir/web-ng/test/**/srql*` and `rust/srql`

## Related

- #4859 — engine: downsample `cidr` / `src_cidr` / `dst_cidr` (merged)
- Demo failure: builder + chart + CIDR before #4859
- Spec note: existing “Query Builder Integration” only describes AND stacking, not modes
