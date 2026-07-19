---
title: NetBox Integration
---

# NetBox Integration

ServiceRadar integrates with NetBox in two complementary ways:

1. **Device inventory sync** — the `netbox-inventory` Wasm plugin (agent-side)
   walks `/api/dcim/devices/` and feeds the standard discovery → DIRE pipeline.
2. **IPAM prefix tags for NetFlow** — a core Oban worker imports
   `/api/ipam/prefixes/` into the prefix-tag snapshot store for flow enrichment
   (tracked in OpenSpec `add-flow-prefix-tag-enrichment`; product fetch will move
   to a plugin under #4650).

Credentials may still be stored under **Settings → Integrations** (type
**Netbox**) for the prefix-import path. Device inventory uses **plugin
assignment parameters**, not that form, today.

---

## Device inventory (`netbox-inventory` Wasm plugin)

The NetBox inventory integration keeps ServiceRadar's device inventory
synchronized with your source-of-truth IPAM/DCIM. It ships as the
`netbox-inventory` Wasm plugin: a sandboxed, signed plugin that runs on an
agent, walks NetBox's `/api/dcim/devices/` listing, and emits device-discovery
snapshots into the standard agent → gateway → DIRE pipeline.

Devices appear with `source=netbox`, carry `netbox_device_id` as a strong
identity signal, and surface role, site, status, manufacturer, and model in the
device metadata card.

### Requirements

- NetBox 3.5+ with API access enabled.
- A service account token scoped to read DCIM device objects.
- Outbound HTTPS connectivity from the assigned ServiceRadar agent to your
  NetBox deployment.

### Installation

1. Import the `netbox-inventory` plugin in **Admin → Plugin Packages** (it is
   published and signed with every ServiceRadar release).
2. Approve the package. The wasm artifact is mirrored to the data service so
   agents can fetch it.
3. Create a plugin assignment for a sync-capable agent with the source
   parameters below. The agent runs the sync on the assignment interval.

### Configuration

Assignment parameters (see the plugin's config schema):

| Option | Description | Default |
|--------|-------------|---------|
| `sources` | List of NetBox instances to sync (`source_id`, `base_url`, `api_token`, per-source options below). | required |
| `source_id` | Stable identifier scoping device identities and snapshot bookkeeping. Never change it after devices are discovered. | required |
| `base_url` | NetBox base URL, e.g. `https://netbox.example.com`. | required |
| `api_token` | NetBox API token, sent as `Authorization: Token <value>`. Stored in the assignment parameters, so scope it to read-only DCIM access; secret-reference delivery is a planned follow-up. | required |
| `page_size` | DRF page size (`limit` parameter). | `100` |
| `timeout_ms` | Per-request timeout. | `30000` |
| `insecure_skip_verify` | Skip TLS validation for self-signed certs. Combine with the [Self-Signed Certificates guide](./tls-security.md#self-signed-certificates). | `false` |
| `network_blacklist` | CIDRs whose devices are excluded from discovery. | `[]` |

### How data flows

- The plugin follows NetBox pagination to exhaustion and validates the fetched
  device count against NetBox's reported total. A pull that fails during
  pagination emits nothing, and device rows that fail to parse mark the
  snapshot incomplete (absence marking is skipped), so a flaky NetBox can
  never retire previously discovered devices.
- Complete snapshots carry `snapshot_complete` bookkeeping: when a device
  disappears from NetBox, the next complete snapshot marks it absent for the
  `netbox` source (the canonical device record is never deleted).
- Devices without a primary IP are skipped and counted in the envelope
  metadata (`devices_without_primary_ip`).

### Validation

- Run `in:devices source:netbox sort:hostname limit:20` in SRQL to confirm
  imports.
- Check the plugin result stream for the assignment: the summary reports
  devices per source and the `snapshot_complete` label.

### Troubleshooting (inventory)

- Permission errors indicate insufficient API token scopes; the plugin needs
  read access to DCIM devices.
- Large instances: raise `page_size` (up to 1000) to reduce request count. The
  plugin bounds a single source at 2,000 devices per sync (the agent caps a
  scheduled result payload at 2 MiB); larger inventories fail loudly on the
  first page. Use NetBox-side filtering or `network_blacklist` to scope the
  source, and track chunked-snapshot support as a follow-up.
- `base_url` with a literal IP address works for RFC1918 addresses (the
  manifest grants those networks); a NetBox reached via a public IP literal
  needs a DNS hostname.
- `CRITICAL` results with "request failed" indicate connectivity, TLS, or
  auth problems; response bodies are never included in results, so check the
  agent log for the paired HTTP host-call entries.
- See the [Troubleshooting Guide](./troubleshooting-guide.md#netbox) for log
  locations.

### Notes (inventory)

- The legacy NetBox connector that ran inside the agent's embedded sync
  runtime was removed in the January 2026 sync rearchitecture; the Wasm plugin
  above is its replacement. The NetBox source form under **Integrations →
  New Source** configures the legacy/prefix path and does **not** drive this
  plugin yet.
- Prefix and IPAM tag import (for NetFlow prefix tagging) is described next
  and tracked in `add-flow-prefix-tag-enrichment` / forgejo #4641; moving that
  fetch into a plugin is #4650.

---

## IPAM prefix tags (flow enrichment)

An Oban maintenance worker (`ServiceRadar.PrefixTags.NetboxImportWorker`) pulls:

- `/api/ipam/prefixes/` (required, paginated to exhaustion, same-origin `next`)
- `/api/ipam/aggregates/` (optional; 404 is ignored)

…maps site/role/tenant/status/VRF/tags into namespaced tag strings, and promotes
an atomic snapshot used by the prefix-tag LPM engine.

| Capability | Status |
|------------|--------|
| Prefix → tag snapshot in CNPG | Supported |
| Flow enrichment (`src_prefix_tags` / `dst_prefix_tags`) | Supported behind feature flag (default **off**) |
| SRQL `tag:` / `src_tag:` / `dst_tag:` | Supported (requires migration columns) |
| Settings UI: Prefix Tags + IP preview | Supported |
| Device / VM inventory sync into the registry | **Via `netbox-inventory` plugin** (above) |
| Prefix-driven sweep job generation | **Not restored** |

Operational detail: [Prefix Tags runbook](./prefix-tags.md).

### Requirements (prefix import)

- NetBox 3.5+ with API access.
- Service account token with read access to IPAM prefixes (and aggregates if used).
- Outbound HTTPS from **core-elx** (Oban worker), not from edge agents.
- Elixir migrations applied (prefix-tag tables + flow columns) **before** enabling
  enrichment or rolling a SRQL binary that selects the new columns.

### Configuration steps (prefix import)

1. **Settings → Integrations → New Source → Netbox.** Enter URL, token, TLS verify.
2. Confirm import: check Oban for `NetboxImportWorker`, or query
   `platform.prefix_tag_snapshots` for an active `netbox` row.
3. Manage / preview under **Settings → Network Services → Prefix Tags**.
4. After migrations are applied on every core-elx **and** SRQL/web-ng node,
   enable flow enrichment via runtime env (see [Prefix Tags](./prefix-tags.md)):

```bash
SERVICERADAR_PREFIX_TAG_ENRICHMENT_ENABLED=true
```

### Tag mapping

| NetBox | ServiceRadar tag |
|--------|------------------|
| Tag slug | `netbox:tag:<slug>` |
| Site slug | `site:<slug>` |
| Role slug | `role:<slug>` |
| Tenant slug | `tenant:<slug>` |
| Status | `status:<value>` |
| VRF | `vrf:<name>` |

### Validation (prefix / flow)

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

### Troubleshooting (prefix)

| Symptom | Likely cause |
|---------|----------------|
| No active snapshot | Missing/invalid credentials; import job failing; count mismatch on paginated pull |
| Preview returns empty | Loader not running / empty snapshots; wrong IP family |
| Flows untagged | flag not enabled; empty tries; traffic outside imported prefixes |
| Partial NetBox pages | Importer refuses partial promote; check logs for count mismatch |
| SRQL `column src_prefix_tags does not exist` | Migration not applied before SRQL roll — apply `20260718010000` first |

Import always follows NetBox pagination and refuses to promote incomplete pulls
(lessons from the archived NetBox pagination fix).
