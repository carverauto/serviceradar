---
title: NetBox Integration
---

# NetBox Integration

ServiceRadar's NetBox integration is **partial** today. The Integrations UI can
store NetBox credentials, and core can import IPAM prefixes for flow tagging.
Full device/VM inventory sync is being restored on a separate track (Wasm plugin
/ agent sync runtime) and is **not** provided by this page's historical
"device connector" description.

## What works today

### 1. Credentials (Integrations UI)

- Create a source with type **Netbox** under **Settings → Integrations**.
- Fields: API URL, token, verify SSL (stored encrypted).
- Permission: `settings.integrations.manage`.
- A connected agent is still required by the Integrations UI before creating
  sources (same gate as other integration types).

### 2. Prefix and tag import (flow enrichment)

An Oban maintenance worker (`ServiceRadar.PrefixTags.NetboxImportWorker`) pulls:

- `/api/ipam/prefixes/` (required, paginated to exhaustion)
- `/api/ipam/aggregates/` (optional; 404 is ignored)

…maps site/role/tenant/status/VRF/tags into namespaced tag strings, and promotes
an atomic snapshot used by the prefix-tag LPM engine.

| Capability | Status |
|------------|--------|
| Prefix → tag snapshot in CNPG | Supported |
| Flow enrichment (`src_prefix_tags` / `dst_prefix_tags`) | Supported behind feature flag |
| SRQL `tag:` / `src_tag:` / `dst_tag:` | Supported |
| UI chips + tag filter + IP preview | Supported |
| Device / VM inventory sync into the registry | **Not restored** (separate change) |
| Prefix-driven sweep job generation | **Not restored** |

Operational detail: [Prefix Tags runbook](./prefix-tags.md).

### 3. Device provenance scaffolding (no active driver)

The following still exist for **display and identity** when something else
writes NetBox-shaped metadata:

- `IDENTITY_KIND_NETBOX_ID` / `netbox_device_id` on devices
- Device UI discovery-source labels for `netbox`
- Docs and Integrations type selector

They do **not** mean a NetBox device poller is running. The historical
`pkg/sync/integrations/netbox` driver was removed in the 2026-01 sync
rearchitecture; only Armis was ported to the embedded sync runtime at that time.

## Requirements (prefix import)

- NetBox 3.5+ with API access.
- Service account token with read access to IPAM prefixes (and aggregates if used).
- Outbound HTTPS from **core-elx** (Oban worker), not from edge agents.
- Elixir migrations applied (prefix-tag tables + flow columns).

## Configuration steps (prefix import)

1. **Settings → Integrations → New Source → Netbox.** Enter URL, token, TLS verify.
2. Confirm import: check Oban for `NetboxImportWorker`, or query
   `platform.prefix_tag_snapshots` for an active `netbox` row.
3. Preview an IP under the Integrations CRM/IPAM **Prefix tag preview** panel.
4. Enable flow enrichment (`prefix_tag_enrichment_enabled: true` on core-elx).
   See [Prefix Tags](./prefix-tags.md#enable-enrichment).

## Tag mapping

| NetBox | ServiceRadar tag |
|--------|------------------|
| Tag slug | `netbox:tag:<slug>` |
| Site slug | `site:<slug>` |
| Role slug | `role:<slug>` |
| Tenant slug | `tenant:<slug>` |
| Status | `status:<value>` |
| VRF | `vrf:<name>` |

## Validation

**Prefix / flow path**

```text
in:flows tag:site:austin time:last_1h
in:flows dst_tag:role:guest-wifi time:last_1h
```

```sql
SELECT source, status, is_active, record_count, promoted_at
FROM platform.prefix_tag_snapshots
ORDER BY promoted_at DESC NULLS LAST
LIMIT 5;
```

**Device path (only after device sync is restored)**

```text
in:devices source:netbox sort:hostname limit:20
```

Expect empty or stale results until the device-inventory track lands.

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| No active snapshot | Missing/invalid credentials; import job failing; count mismatch on paginated pull |
| Preview returns empty | Loader not running / empty snapshots; wrong IP family |
| Flows untagged | `prefix_tag_enrichment_enabled` still false; traffic outside imported prefixes |
| Partial NetBox pages | Fixed by fail-fast importer (no partial promote); check logs for count mismatch |
| "Device sync from NetBox" expected | Not implemented yet — see Wasm/plugin restore work |

Import always follows NetBox pagination and refuses to promote incomplete pulls
(lessons from the archived NetBox pagination fix).

## Related

- [Prefix Tags](./prefix-tags.md) — enable, monitor, rollback
- [NetFlow](./netflow.md) — ingest path
- [Sync Service](./sync.md) — agent-side discovery architecture
