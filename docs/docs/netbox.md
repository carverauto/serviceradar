---
title: NetBox Integration
---

# NetBox Integration

ServiceRadar integrates with NetBox in two complementary ways:

1. **Device inventory sync** - the `netbox-inventory` Wasm plugin (agent-side)
   walks `/api/dcim/devices/` and feeds the standard discovery -> DIRE pipeline.
2. **IPAM prefix tags for NetFlow** - a core Oban worker imports
   `/api/ipam/prefixes/` into the prefix-tag snapshot store for flow enrichment
   (tracked in OpenSpec `add-flow-prefix-tag-enrichment`; product fetch will move
   to a plugin under #4650).

The two paths take their credentials differently. Device inventory reads its
token from the plugin assignment's parameters under **Admin -> Plugins**
(`/settings/agents/plugins`). The prefix-import path uses the NetBox source
under **Settings -> Integrations** (type **Netbox**).

:::caution Not in 1.4.49
**The `netbox` credential rule provider.** On 1.4.49 the `netbox-inventory`
manifest declares no `integrations` block, so there is no `NetBox` entry under
**New Credential** or **New Rule**, no `netbox` provider, and no
`inventory_sync` purpose. Looking for NetBox on
**Settings -> Networks -> Credential Rules** is a dead end on that release, and
the assignment parameters below are the way to configure it.

Merged work adds an `integrations.credential_profiles` block to
`go/cmd/wasm-plugins/netbox/plugin.yaml` -- provider `netbox`, one `api_token`
auth method, purpose `inventory_sync`, `supports_rules: true` -- so the token
moves onto a credential and the rule delivers it, which is what
[Credential Management](./credentials.md) exists to do. That page's
[NetBox section](./credentials.md#netbox) has the full declaration.

Two rule fields behave differently here than they do for a per-device
integration. **Controller host** is the NetBox instance and becomes `base_url`,
so set the full origin (`https://netbox.example.com`). **Target query** is only
a delivery gate: the sync walks the instance named by the rule and ignores the
resolved targets, so the manifest default resolves a single device
(`in:devices sort:uid:asc limit:1`) and you narrow it to the NetBox host's own
device record. What the rule does not fix is that it renders the flat
single-source fields, so an assignment with a non-empty `sources[]` ignores what
the rule delivers.

The parameter shapes documented below -- the `sources` array and the flat
single-source shorthand -- stay supported either way. Multi-source assignments
remain hand-entered.

First release containing the profile: `<first-release>`.
:::

---

## Device inventory (`netbox-inventory` Wasm plugin)

The NetBox inventory integration keeps ServiceRadar's device inventory
synchronized with your source-of-truth IPAM/DCIM. It ships as the
`netbox-inventory` Wasm plugin: a sandboxed, signed plugin that runs on an
agent, walks NetBox's `/api/dcim/devices/` listing, and emits device-discovery
snapshots into the standard agent -> gateway -> DIRE pipeline.

Devices appear with `source=netbox`, carry `netbox_device_id` as a strong
identity signal, and surface role, site, status, manufacturer, and model in the
device metadata card.

### Requirements

- NetBox 3.5+ with API access enabled.
- A service account token scoped to read DCIM device objects.
- Outbound HTTPS connectivity from the assigned ServiceRadar agent to your
  NetBox deployment.

### Installation

1. Import the `netbox-inventory` plugin in **Admin -> Plugin Packages** (it is
   published and signed with every ServiceRadar release).
2. Approve the package. The wasm artifact is mirrored to the data service so
   agents can fetch it.
3. Create a plugin assignment for a sync-capable agent with the source
   parameters below. The agent runs the sync on the assignment interval.

### Credential rules

A NetBox credential rule is the supported way to deliver the API token: the
token stays on a credential secret and the assignment is materialized with the
base URL taken from the rule's controller host. Two rule fields behave
differently here than they do for a per-device integration:

- **Controller host** is the NetBox instance. It becomes `base_url`, so set the
  full origin (`https://netbox.example.com`), or a `base_url` metadata value
  when the deployment uses a BASE_PATH prefix.
- **Scope** is agent, and only agent. One run of the sync covers the whole
  instance, so the rule has to name the single agent that runs it. A gateway or
  partition scope would be in scope for every agent underneath it, and each one
  would walk the same instance and emit another complete snapshot under the
  same `source_instance`. Core does not pick an agent for you, because whether
  an agent can reach the NetBox host is not something core knows. The rule form
  offers no other scope; a rule that somehow carries one is not delivered, and
  the reconcile reports it as `single_target_rule_not_agent_scoped`.
- **Target query** is only a delivery gate. The sync walks the instance named
  by the rule and ignores the resolved targets, so a rule produces exactly one
  assignment and one complete snapshot per run regardless of how many devices
  the query matches. The default resolves a single device for that reason;
  narrow it to the NetBox host's own device record (for example
  `in:devices ip:10.0.0.5`) when you want the targets to name the instance.

Give each NetBox rule a distinct target query. Rules that share one are
collapsed to the highest-priority rule, so two instances behind the same query
means only one of them syncs.

### Configuration

Assignment parameters (see the plugin's config schema):

| Option | Description | Default |
|--------|-------------|---------|
| `sources` | List of NetBox instances to sync (`source_id`, `base_url`, `api_token`, per-source options below). | required |
| `source_id` | Stable identifier scoping device identities and snapshot bookkeeping. Never change it after devices are discovered. | required |
| `base_url` | NetBox base URL, e.g. `https://netbox.example.com`. | required |
| `api_token` | NetBox API token, sent as `Authorization: Token <value>`. Stored in the assignment parameters, so scope it to read-only DCIM access; a credential rule delivers it without storing it here from `<first-release>`. | required |
| `page_size` | DRF page size (`limit` parameter). | `100` |
| `timeout_ms` | Per-request timeout. | `30000` |
| `insecure_skip_verify` | Skip TLS validation for self-signed certs. Prefer trusting the issuing CA on the agent through `plugin_http_trusted_ca_files` in `agent.json`; see the [Self-Signed Certificates guide](./tls-security.md#self-signed-certificates). | `false` |
| `network_blacklist` | CIDRs whose devices are excluded from discovery. | `[]` |

The flat `source_id` / `base_url` / `api_token` fields are a single-source
shorthand: they are read only when `sources` is absent. Whichever shape you use,
`api_token` must be set per source, or that source fails with
`NetBox source <id> has no api_token configured`.

Scope the token to read-only DCIM access. It is stored in
`plugin_assignments.params`, which is a weaker placement than a credential, and
on 1.4.49 the only mitigation is least privilege on the NetBox side. From
`<first-release>` a `netbox` credential rule delivers the token instead, and the
assignment row holds a secret reference rather than the value -- see
[Credential Management: NetBox](./credentials.md#netbox).

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

- `NetBox inventory_sync has no sources configured`: the assignment's `sources[]`
  is empty and no flat `base_url` was given either. Fill in the source
  parameters on the assignment under **Admin -> Plugins**
  (`/settings/agents/plugins`). From `<first-release>` the message reads
  `NetBox inventory_sync has no source configured: set base_url and api_token,
  or attach a NetBox credential rule`, and the condition is narrower: the flat
  fallback engages as soon as any of `base_url`, `api_token`, `source_id` or
  `source_name` is set, so a half-configured source is reported by the field it
  is missing rather than as having no source.
- `NetBox source <id> has no api_token configured`: the source entry exists but
  its `api_token` is blank.
- `NetBox source <id> has an invalid base_url`: the entry's `base_url` is blank
  or does not parse. From `<first-release>` a blank one reports separately as
  `NetBox source <id> has no base_url configured`, and a malformed one appends
  the reason, as in `has an invalid base_url: base url must be http or https`.
- `NetBox configuration could not be loaded`: the plugin got no config from the
  agent runtime at all -- check that the assignment exists and is enabled.
  `NetBox configuration could not be parsed` (from `<first-release>`) means the
  config arrived but was not valid JSON in either the plain-object or the
  `serviceradar.plugin_inputs.v1` envelope shape.
- `NetBox inventory_sync failed for <id>: NetBox request failed: status 403`
  (or `401`) means the token was rejected: insufficient scopes, or a token the
  instance does not recognise. The plugin needs read access to DCIM devices.
- Large instances: raise `page_size` (up to 1000) to reduce request count. The
  plugin bounds a single source at 2,000 devices per sync (the agent caps a
  scheduled result payload at 2 MiB); larger inventories fail loudly on the
  first page. Use NetBox-side filtering or `network_blacklist` to scope the
  source, and track chunked-snapshot support as a follow-up.
- `base_url` with a literal IP address works for RFC1918 addresses (the
  manifest grants those networks); a NetBox reached via a public IP literal
  needs a DNS hostname.
- Any `CRITICAL` result reads `NetBox inventory_sync failed for <id>: <reason>`
  and means the pull aborted, so nothing was emitted and the previous complete
  snapshot stays authoritative. A `<reason>` of `NetBox request failed` is
  connectivity or TLS; a pagination `<reason>` such as
  `pagination returned 90 of 100 devices` or `device count changed during
  pagination` is NetBox changing under the walk. Response bodies are never
  included in results, so check the agent log for the paired HTTP host-call
  entries.
- See the [Troubleshooting Guide](./troubleshooting-guide.md#netbox) for log
  locations.

### Notes (inventory)

- The legacy NetBox connector that ran inside the agent's embedded sync
  runtime was removed in the January 2026 sync rearchitecture; the Wasm plugin
  above is its replacement. The NetBox source form under **Integrations ->
  New Source** configures the legacy/prefix path and does **not** drive this
  plugin; the plugin is driven by its assignment parameters.
- Prefix and IPAM tag import (for NetFlow prefix tagging) is described next
  and tracked in `add-flow-prefix-tag-enrichment` /
  [GitHub #3527](https://github.com/carverauto/serviceradar/issues/3527);
  moving that fetch into a plugin is
  [GitHub #3528](https://github.com/carverauto/serviceradar/issues/3528).

---

## IPAM prefix tags (flow enrichment)

An Oban maintenance worker (`ServiceRadar.PrefixTags.NetboxImportWorker`) pulls:

- `/api/ipam/prefixes/` (required, paginated to exhaustion, same-origin `next`)
- `/api/ipam/aggregates/` (optional; 404 is ignored)

...maps site/role/tenant/status/VRF/tags into namespaced tag strings, and promotes
an atomic snapshot used by the prefix-tag LPM engine.

| Capability | Status |
|------------|--------|
| Prefix -> tag snapshot in CNPG | Supported |
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

1. **Settings -> Integrations -> New Source -> Netbox.** Enter URL, token, TLS verify.
2. Confirm import: check Oban for `NetboxImportWorker`, or query
   `platform.prefix_tag_snapshots` for an active `netbox` row.
3. Manage / preview under **Settings -> Network Services -> Prefix Tags**.
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
| SRQL `column src_prefix_tags does not exist` | Migration not applied before SRQL roll - apply `20260718010000` first |

Import always follows NetBox pagination and refuses to promote incomplete pulls
(lessons from the archived NetBox pagination fix).
