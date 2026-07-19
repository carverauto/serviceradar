# Design: Plugin-driven prefix-tag sources

## Context

Prefix-tag **platform** (CNPG snapshots, per-source tries, FlowEnrichment,
SRQL) is product-agnostic. NetBox **import** was implemented as a core Oban
worker for delivery speed on `add-flow-prefix-tag-enrichment`, which violates
the ownership model already adopted for external device inventory:

> Core must not gain a provider module … every time one is added.
> (`add-external-inventory-wasm-plugin-contract`)

## Goals

1. Core owns only: storage, promote API, Loader/Store, enrichment lookup,
   generic schedule hooks, catalog validation.
2. Plugins own: credentials schema, HTTP, product JSON → prefix rows, cadence,
   domains/allowlists, documentation.
3. New IPAM = new signed package, not a core PR.

## Non-goals

See proposal. Platform sources (`manual`, `provider`, `ti`, `dns-policy`) stay
core materializers behind the same promote path.

## Decisions

### 1. Extend `integrations` descriptor (not a parallel root key)

Reuse `ServiceRadar.Plugins.IntegrationDescriptor` / `IntegrationCatalog`:

```yaml
integrations:
  documentation:
    path: docs/netbox.md
  credential_profiles:
    - provider: netbox
      # … existing shape …
  inventory_sources: []   # optional; device inventory is separate
  prefix_tag_sources:
    - source: netbox
      label: NetBox IPAM prefixes
      description: IP/CIDR tags for flow enrichment
      producer_schedule_id: netbox-prefix-tags-daily   # or equivalent binding
      # optional: max_prefixes, tag_namespace defaults
```

**Rationale:** Catalog load, approval, and duplicate-claim checks already exist
for inventory. Prefix tags are another claim type on the same package.

**Alternative rejected:** Hard-coded capability string only (`prefix-tags:v1`)
without structured source id — insufficient for multi-source packages and UI
labels.

### 2. Versioned prefix-row payload (plugin → core)

Plugins MUST NOT write CNPG. They emit a complete snapshot payload (via
existing plugin result / action-result ingest path — exact transport chosen
at implementation to match inventory/OTX patterns):

```json
{
  "schema": "serviceradar.prefix_tag_snapshot.v1",
  "source": "netbox",
  "fetched_at": "2026-07-19T12:00:00Z",
  "record_count": 1234,
  "etag": "optional",
  "rows": [
    {
      "prefix": "10.1.2.0/24",
      "vrf": null,
      "tags": ["site:hq", "role:wifi", "netbox:tag:guest"],
      "site": "hq",
      "role": "wifi",
      "tenant": null,
      "status": "active"
    }
  ]
}
```

Core `PrefixTags.Ingest` (name TBD):

1. Validate schema + source claim against approved catalog
2. Create `building` snapshot, bulk insert, promote atomically (existing
   snapshot semantics)
3. `Loader.broadcast_invalidation(%{source: source})`
4. Reject partial / count-mismatch payloads (same fail-fast as current worker)

**Rationale:** Keeps transactionality and GiST/jsonb concerns in Elixir; plugin
stays pure collect+map.

### 3. Scheduling without product modules

`NetflowEnrichmentDatasetScheduler` (or a renamed generic enrichment scheduler)
SHALL:

- Keep platform jobs that are not plugins: OUI, provider CIDR refresh,
  `ti` / `dns-policy` materializers as **registered platform adapters**
- Discover plugin prefix-tag sources from catalog + active assignments
- Ensure producer schedule / Oban maintenance entry from **descriptor**, not
  `alias ServiceRadar.PrefixTags.NetboxImportWorker`

Platform materializers may remain Elixir modules, but they register via a
behaviour/list of **source id → reload MFA**, not NetBox-specific names in the
scheduler.

### 4. IntegrationSource typing

**BREAKING-ish migration:**

- Prefer `source` / `provider` string aligned with catalog (`"netbox"`)
- Stop requiring a core PR to add `one_of: [:foo]`
- Transition path: accept existing `:netbox` atoms while UI writes catalog ids;
  migrate DB constraint when safe

Credential storage continues via cloak + integration sources or credential
rules (inventory contract), brokered to the plugin — same as Proxmox/OTX.

### 5. UI

- Integrations create form: source-type options = catalog
  `credential_profiles` / integration claims, not fixed HEEx list
- Prefix Tags LiveView source tabs = `manual` + active snapshot sources from
  CNPG (+ catalog labels), not `~w(manual netbox provider ti dns-policy)` only
- Product docs live in the package (`integrations.documentation`), not
  core-only NetBox import code comments

### 6. Migration from `NetboxImportWorker`

1. Ship NetBox Wasm plugin emitting `prefix_tag_snapshot.v1`
2. Dual-run or flag: core worker off when plugin assignment healthy
3. Delete worker, scheduler alias, tests, docs that describe core HTTP import
4. Keep table/trie semantics unchanged — operators should not re-author tags

## Risks

| Risk | Mitigation |
|------|------------|
| Large NetBox prefix lists and Wasm memory | Same pagination + memory limits as inventory/OTX; optional chunked multi-result promote if needed |
| Schedule gap during cutover | Feature flag / dual path; document operator steps |
| Catalog not loaded on agent-gateway | Catalog is core/web-ng concern; agent only runs package |

## Open questions (resolve in implementation PR)

1. Exact ingest transport: `plugin_result.v1` subtype vs dedicated NATS subject
   vs core-hosted action-result (OTX style for deployment-level feeds).
2. Whether NetBox device-inventory and IPAM share one package or two.
3. Whether `manual` remains the only operator-writable source in the Settings
   UI (likely yes).
