# Change: Plugin-driven prefix-tag sources (no NetBox in core)

## Why

`add-flow-prefix-tag-enrichment` delivered a solid **platform** (snapshot tables,
LPM trie, flow columns, SRQL filters, Settings UI) but regressed into the
anti-pattern the external-inventory plugin contract already forbids for
devices: **product-specific NetBox code in core**.

Concrete hardcoding today:

- `IntegrationSource.source_type` is a closed atom list including `:netbox`
- `NetflowEnrichmentDatasetScheduler` aliases and schedules
  `PrefixTags.NetboxImportWorker` by name
- `PrefixTags.NetboxImportWorker` is a full HTTP client + NetBox JSON mapper +
  pagination engine living under `serviceradar_core`
- Integrations and Prefix Tags UIs hardcode NetBox labels, filters, and source
  tabs

That does not scale. Every new IPAM (Infoblox, phpIPAM, custom) would force
another core worker, enum value, scheduler line, and HEEx branch. NetBox must
stand alone as a signed Wasm plugin that **publishes capabilities**; core must
only supply generic promote / schedule / catalog surfaces.

This change is the prefix-tag twin of
`add-external-inventory-wasm-plugin-contract` (device inventory) and follows the
same ownership boundary already partially built as
`ServiceRadar.Plugins.IntegrationDescriptor` /
`IntegrationCatalog`.

Depends on / follows: forgejo issue **#4650**,
`add-flow-prefix-tag-enrichment` (#4641 / PR #4642) landing first.

## What Changes

- **Extend package `integrations` descriptors** with a bounded
  `prefix_tag_sources` claim (source id, label, cadence / producer schedule,
  optional config schema hints). Catalog loads these from **approved** packages
  only; duplicate source ids are rejected.
- **Generic prefix-tag ingest contract**: plugins (or core workers for
  first-party platform sources like `provider` / `ti` / `dns-policy`) emit
  complete prefix-row snapshots in a versioned payload shape; core validates,
  bulk-loads, atomically promotes, and broadcasts Loader invalidation. **No**
  product-specific HTTP or JSON mapping in core.
- **Catalog-driven scheduling**: replace the NetBox-specific
  `ensure_scheduled(NetboxImportWorker, …)` line with discovery of claimed
  prefix-tag sources (assignment + producer schedule / maintenance job),
  analogous to inventory producer schedules.
- **Open `IntegrationSource` typing**: stop growing the closed
  `one_of: […, :netbox, …]` enum for product integrations; prefer catalog /
  plugin-declared source identifiers (string provider/source id).
- **UI from catalog**: Integrations source-type options and Prefix Tags
  imported-source tabs are driven by approved package descriptors + active
  snapshots, not hard-coded NetBox lists.
- **Move NetBox IPAM fetch/map out of core** into a first-party (or external)
  NetBox Wasm plugin that declares `prefix_tag_sources: [{ source: "netbox",
  … }]` and emits the generic payload. Delete `NetboxImportWorker` and all
  NetBox-named promote helpers from `serviceradar_core` once the plugin path
  is green.
- Platform-owned sources (`manual`, `provider`, `ti`, `dns-policy`) remain
  core-owned materializers (they are not third-party products); they still
  use the same promote API as plugins.

## Non-Goals

- Reworking the LPM engine, flow columns, or SRQL tag filters (already in
  `add-flow-prefix-tag-enrichment`).
- Device-inventory NetBox sync (separate inventory plugin / PR #4643 track).
- Infoblox or other IPAM plugins beyond the contract + one NetBox migration.
- Multitenancy.

## Impact

- Affected specs: `prefix-tagging` (delta, not yet archived into `openspec/specs`),
  `wasm-plugin-system`, `build-web-ui`
- Affected code (implementation phase — not this PR):
  - `elixir/serviceradar_core/lib/serviceradar/prefix_tags/**`
  - `elixir/serviceradar_core/lib/serviceradar/observability/netflow_enrichment_dataset_scheduler.ex`
  - `elixir/serviceradar_core/lib/serviceradar/integrations/integration_source.ex`
  - `elixir/serviceradar_core/lib/serviceradar/plugins/integration_{descriptor,catalog}.ex`
  - `elixir/web-ng/.../integrations_live`, `.../prefix_tags_live`
  - `go/cmd/wasm-plugins/` (new or extended NetBox plugin)
- Related changes: `add-flow-prefix-tag-enrichment`,
  `add-external-inventory-wasm-plugin-contract`, `add-alienvault-otx-integration`
- **BREAKING** (implementation): removal of core `NetboxImportWorker` requires
  operators to assign/approve the NetBox plugin before prefix imports resume.
  Document migration in the release notes for that cut.

## Success criteria

- Adding a second IPAM plugin requires **zero** new modules under
  `serviceradar_core/lib/serviceradar/prefix_tags/` named after that product
- `NetflowEnrichmentDatasetScheduler` has no product-specific aliases
- `IntegrationSource` does not gain a new atom per product
- NetBox package alone describes credentials, schedule, and prefix-tag claim

## References

- Forgejo issue: https://code.carverauto.dev/carverauto/serviceradar/issues/4650
- Parent enrichment: #4641 / PR #4642 (`add-flow-prefix-tag-enrichment`)
- Parallel inventory contract: `add-external-inventory-wasm-plugin-contract`
