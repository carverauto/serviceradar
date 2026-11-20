# Proxmox Monitoring

ServiceRadar Solution Pack (`io.serviceradar.proxmox-monitoring`) that watches a
Proxmox VE estate through the inventory the Proxmox plugin already collects. It
answers three questions: is a datastore about to fill, has a guest stopped
running, and is the inventory those answers rest on current.

## Requirements

- The `proxmox-inventory` plugin, version 0.1.14 or later, assigned to an agent
  that can reach the Proxmox API.
- An agent release that permits the plugin's runtime-state read. An older agent
  still reports guests, and the paused-guest check then answers
  `runtime_state_not_reported` instead of `no_paused_guests`.

The pack needs no credential of its own. The plugin assignment holds the Proxmox
API credential.

## Checks (3)

Every check is evaluated by ServiceRadar itself against inventory reported in
the last hour. None of them contacts Proxmox.

- `proxmox-datastore-capacity` -- Takes the fullest datastore and compares its
  used space with `storage_warn_pct` (default 80) and `storage_crit_pct`
  (default 90). Verdicts: `datastores_have_headroom`, `datastore_filling`,
  `datastore_nearly_full`, `no_fresh_datastore_inventory`.
- `proxmox-paused-guests` -- Counts virtual machines that are paused, stopped on
  an I/O error or panicked. Proxmox lists such a guest as running, so only the
  runtime state shows it. A paused guest that was seen is reported as
  `guests_paused` even when another of the check's queries failed. Verdicts:
  `no_paused_guests`, `guests_paused`, `runtime_state_not_reported`,
  `no_fresh_guest_inventory`, `paused_guest_query_failed`,
  `runtime_state_query_failed`.
- `proxmox-inventory-freshness` -- Fails when no Proxmox host was reported in
  the last hour. Verdicts: `inventory_current`, `inventory_stale`.

The checks open no alert on their own. Every alert comes from a rule below, so
each one can be paused or tuned in one place.

## Alert Rules (5)

- `proxmox_datastore_nearly_full` (enabled, critical) -- The fullest datastore
  crossed the critical threshold.
- `proxmox_datastore_filling` (enabled, warning) -- The fullest datastore
  crossed the warning threshold.
- `proxmox_guests_paused` (enabled, critical) -- At least one guest is paused.
- `proxmox_inventory_stale` (enabled, critical) -- No host was reported in the
  last hour.
- `proxmox_guest_runtime_state_unavailable` (installed paused, warning) -- When
  paused guests cannot be detected. Enable it once every agent that runs the
  Proxmox plugin has been upgraded.

## Dashboard (1)

- `proxmox-monitoring-overview` -- Check verdicts, the ten fullest datastores,
  paused guests, and running guests whose runtime state is not reported.

## Limits

- The checks judge the whole estate, not one datastore or guest each. The alert
  says that something is wrong; the dashboard says which datastore or guest.
- Containers have no runtime state and are never reported as paused.
- The one-hour inventory window is fixed.
