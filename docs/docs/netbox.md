---
title: NetBox Integration
---

# NetBox Integration

The NetBox integration keeps ServiceRadar's device inventory synchronized with
your source-of-truth IPAM/DCIM. It ships as the `netbox-inventory` Wasm plugin:
a sandboxed, signed plugin that runs on an agent, walks NetBox's
`/api/dcim/devices/` listing, and emits device-discovery snapshots into the
standard agent -> gateway -> DIRE pipeline.

Devices appear with `source=netbox`, carry `netbox_device_id` as a strong
identity signal, and surface role, site, status, manufacturer, and model in the
device metadata card.

## Requirements

- NetBox 3.5+ with API access enabled.
- A service account token scoped to read DCIM device objects.
- Outbound HTTPS connectivity from the assigned ServiceRadar agent to your
  NetBox deployment.

## Installation

1. Import the `netbox-inventory` plugin in **Admin -> Plugin Packages** (it is
   published and signed with every ServiceRadar release).
2. Approve the package. The wasm artifact is mirrored to the data service so
   agents can fetch it.
3. Create a plugin assignment for a sync-capable agent with the source
   parameters below. The agent runs the sync on the assignment interval.

## Configuration

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

## How Data Flows

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

## Validation

- Run `in:devices source:netbox sort:hostname limit:20` in SRQL to confirm
  imports.
- Check the plugin result stream for the assignment: the summary reports
  devices per source and the `snapshot_complete` label.

## Troubleshooting

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

## Notes

- The legacy NetBox connector that ran inside the agent's embedded sync
  runtime was removed in the January 2026 sync rearchitecture; the Wasm plugin
  above is its replacement. The NetBox source form under **Integrations ->
  New Source** configures the legacy path and does not drive this plugin yet.
- Prefix and IPAM tag import (for NetFlow prefix tagging) is tracked
  separately in the `add-flow-prefix-tag-enrichment` OpenSpec change.
