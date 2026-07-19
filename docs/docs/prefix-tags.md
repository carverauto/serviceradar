---
title: Prefix Tags (flow enrichment)
---

# Prefix Tags

Prefix tags attach business context (site, role, tenant, zone, …) to every
NetFlow/sFlow/IPFIX row at ingest time using an in-memory longest-prefix-match
(LPM) trie. Tags are imported from NetBox IPAM (and can be authored manually)
and are queryable in SRQL and the flow UI.

This is the operational runbook for enabling, monitoring, and rolling back the
feature. Design background lives in OpenSpec change
`add-flow-prefix-tag-enrichment` and forgejo issue #4641.

## Architecture (short)

| Piece | Where |
|-------|--------|
| Source of truth | CNPG tables `platform.prefix_tag_snapshots`, `platform.prefix_tags` |
| Hot-path lookup | Pure-Elixir LPM trie in `:persistent_term` (`ServiceRadar.PrefixTags`) |
| Replication | Per-node `PrefixTags.Loader` on core-elx and web-ng; PubSub topic `prefix_tags:snapshot` |
| Import | Oban `:maintenance` worker `ServiceRadar.PrefixTags.NetboxImportWorker` |
| Enrichment | EventWriter `FlowEnrichment` → columns `src_prefix_tags` / `dst_prefix_tags` (+ provenance) |
| Feature flag | `:prefix_tag_enrichment_enabled` (default **off**) |

Device inventory sync is a separate track (Wasm plugin / agent sync). This
feature only imports IPAM **prefixes and tags** for flow enrichment.

## Feature flags

| Flag | Default | Purpose |
|------|---------|---------|
| `prefix_tag_enrichment_enabled` | **false** | Write `src/dst_prefix_tags` on flow ingest |
| `prefix_tag_provider_trie_enabled` | **true** | Hosting-provider LPM via `provider` trie (SQL/`ProviderCidrCache` only if trie empty or flag off) |
| `threat_intel_engine_match_enabled` | **true** | CTI `IpThreatIntelCache` current-match via `ti` trie (SQL if trie empty) |
| `geo_tag_derivation_enabled` | **false** | Merge `geo:country:` / `geo:asn:` from Geolix into tag columns |
| `prefix_tags_loader_enabled` | **true** | Boot the per-node Loader |

## Enable enrichment

1. Apply migrations (includes prefix-tag tables, additive flow columns, geo-cache
   `location`).
2. Configure a NetBox integration source under **Settings → Integrations**
   (type Netbox: `url`, `token`, `verify_ssl`). Ensure an agent is registered
   so the Integrations UI allows create.
3. Wait for (or trigger) a NetBox prefix import:
   - Scheduled via the netflow enrichment dataset scheduler (same cadence loop
     as provider CIDR / OUI refresh), or
   - Manually enqueue `ServiceRadar.PrefixTags.NetboxImportWorker` on the
     coordinator node.
4. Confirm a snapshot is active:

```sql
SELECT id, source, status, is_active, record_count, promoted_at
FROM platform.prefix_tag_snapshots
WHERE is_active;
```

5. Preview tags for an IP in **Settings → Integrations → CRM/IPAM → Prefix tag
   preview** (reads the local node's trie; no DB hop).
6. Enable flow tag columns on core-elx (and any process that runs the EventWriter):

```elixir
# runtime config / env-backed Application env
config :serviceradar_core, prefix_tag_enrichment_enabled: true
```

Provider and CTI engine matching are already on by default once the Loader /
materializers have populated tries. Reload or roll core-elx so Application env
is picked up.

7. Verify new flow rows carry tags:

```sql
SELECT time, src_endpoint_ip, dst_endpoint_ip,
       src_prefix_tags, dst_prefix_tags,
       src_prefix_tags_source, dst_prefix_tags_source
FROM platform.ocsf_network_activity
WHERE src_prefix_tags IS NOT NULL OR dst_prefix_tags IS NOT NULL
ORDER BY time DESC
LIMIT 20;
```

SRQL:

```text
in:flows tag:site:austin time:last_1h
in:flows dst_tag:role:guest-wifi time:last_1h
```

## Tag mapping (NetBox)

| NetBox field | Tag form |
|--------------|----------|
| Explicit tags | `netbox:tag:<slug>` |
| Site | `site:<slug>` |
| Role | `role:<slug>` |
| Tenant | `tenant:<slug>` |
| Status | `status:<value>` |
| VRF | `vrf:<slug-or-name>` |

Mapping namespaces and max tags per prefix are configurable on
`ServiceRadar.PrefixTags.NetboxImportWorker` Application env.

## Additional tag sources (advisory)

| Source | Tags | Cadence | Authority |
|--------|------|---------|-----------|
| Provider CIDRs | `provider:<name>` | After provider dataset refresh | Hosting-provider columns (same chain) |
| Geo (Geolix) | `geo:country:`, `geo:asn:` | Per-flow derivation | MMDB only; not stored in trie |
| Threat intel | `ti:<feed>`, `ti:label:…` | High (default ~5m) | **Advisory** — authoritative matching stays on `threat_intel_matches` / match pipeline |
| DNS policy (RPZ) | `dns-policy:hit`, `dns-policy:<policy>` | Default ~15m | **Advisory** — clients that recently triggered RPZ |

Threat and DNS-policy tags are **point-in-time evidence** at flow ingest. They
are never retro-applied to historical rows. Investigation surfaces must not
treat tag columns as the sole authority for threat coverage.

Import rules:

- Follows NetBox `next` pagination to exhaustion.
- Validates fetched count against NetBox `count`.
- **Never promotes a partial snapshot** (fail-fast on HTTP/decode/count mismatch).
- On success: atomic single-active flip per source + PubSub invalidation.

## Monitoring

Telemetry events (attach your usual handler / metrics pipeline):

| Event | Metrics / metadata |
|-------|--------------------|
| `[:serviceradar, :prefix_tags, :lookup]` | `count`, `match_depth`, `outcome` hit/miss |
| `[:serviceradar, :prefix_tags, :rebuild]` | `duration_us`, prefix counts, `outcome` |
| `[:serviceradar, :prefix_tags, :import]` | `duration_us`, `record_count`, `outcome`, `source` |

Practical checks:

- **Import success**: Oban job history for `NetboxImportWorker`; logs
  `"NetBox prefix-tag snapshot promoted"`.
- **Staleness**: alert when active NetBox snapshot `promoted_at` age exceeds
  **2×** the configured poll interval (design success metric).
- **Trie size**: rebuild telemetry `ipv4_prefixes` / `ipv6_prefixes`.
- **Enrichment path**: when the flag is on, rows should show
  `*_prefix_tags_source` of `netbox` or `manual` for matching traffic.

## Rollback

1. Set `prefix_tag_enrichment_enabled: false` and roll core-elx.
2. New inserts stop writing tag columns (flag-off path omits the fields).
3. Existing columns remain additive and inert; no schema rollback required.
4. Deactivate snapshots if needed:

```sql
UPDATE platform.prefix_tag_snapshots
SET is_active = FALSE, status = 'superseded', updated_at = now()
WHERE is_active AND source = 'netbox';
```

Then broadcast is optional (loaders will empty on next failed/empty load or
process restart). Prefer promoting a new empty import only when intentional.

## Manual tags

Manual entries use source `manual` (permanent snapshot, not replaced by NetBox
imports). Ash resources:

- `ServiceRadar.PrefixTags.Snapshot`
- `ServiceRadar.PrefixTags.PrefixTag`

Permission: `settings.prefix_tags.manage` (operator+ by default).

## RBAC

| Permission | Use |
|------------|-----|
| `settings.prefix_tags.manage` | Manual prefix tags / snapshot ops |
| `settings.integrations.manage` | NetBox credentials + tag preview UI |
| `observability.netflow.view` | Flow pages / SRQL flow results |

## Performance notes

- Lookups are local and GC-friendly (`:persistent_term`).
- Synthetic bench (default 5k prefixes): well above 10k lookups/s on developer
  hardware.
  - Full size: `PREFIX_TAG_BENCH_SIZE=400000 mix test
    test/serviceradar/prefix_tags/benchmark_test.exs --include benchmark --no-start`
  - Multi-source (bench + provider co-resident): add
    `PREFIX_TAG_BENCH_MULTI_SOURCE=1`
- M1 design gate: if EventWriter P99 batch latency rises more than ~5% with the
  flag on at production volume, evaluate a Rustler NIF behind the same
  `PrefixTags.Engine` behaviour (no API change).
- Rollback provider path: set `prefix_tag_provider_trie_enabled: false` to
  restore GiST + `ProviderCidrCache` (cache GenServer starts only when the flag
  is false).

## Proximity queries (geo cache)

Flow proximity does **not** store geometry on the flow hypertable. Instead:

1. Migration adds a generated `location geography(Point, 4326)` column on
   `platform.ip_geo_enrichment_cache` (from lat/lng) plus a partial GiST index.
2. SRQL `near:lat,lng,radius` runs `ST_DWithin` against that cache and filters
   flows by IP membership (src and/or dst).

Writers of the geo cache continue to set `latitude`/`longitude` only; Postgres
maintains `location`. See [SRQL Cookbook](./srql-cookbook.md) for examples.

## Related

- [NetBox Integration](./netbox.md) — credentials UI and current capability status
- [NetFlow](./netflow.md) — collector and EventWriter path
- [SRQL Cookbook](./srql-cookbook.md) — example `tag:` and `near:` queries
