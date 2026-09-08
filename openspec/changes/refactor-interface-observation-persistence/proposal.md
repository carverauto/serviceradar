# Change: Persist interface discovery as current state, not one row per poll

## Why

`platform.discovered_interfaces` grows without bound and stores ~98 rows for every
one thing it actually knows.

Measured on farm01 (2026-08-24), a **4-device** sample:

| property | value |
| --- | --- |
| rows | 36,816 |
| distinct semantic states | **374** |
| amplification | **98x** |
| growth | 767 rows / device / day |
| hypertable | no |
| retention policy | none |
| compression | none |
| size | 57 MB for 4 devices |

"Semantic state" here is `(device_id, if_index, if_name, if_phys_address,
if_oper_status, if_admin_status, if_speed, sorted(ip_addresses))` -- everything a
consumer of interface inventory reads.

### Why every row looks different

Two causes, both mechanical:

1. **Per-poll provenance is stored in the row.** `metadata` carries `discovery_id`,
   `mapper_job_id` and `discovery_time`, so a fresh UUID and timestamp land on every
   row of every poll. For one interface, `metadata` had **129 distinct values across
   129 rows** while `if_name`, `if_phys_address`, `if_oper_status`, `if_speed`,
   `available_metrics` and `interface_uid` each had exactly **one**.
2. **`ip_addresses` ordering is unstable.** The same interface showed **12 distinct
   textual values** for **3 distinct sorted sets**. Nine of the twelve were pure
   permutations of an identical address set.

The result is that no de-duplication is possible after the fact: every row is
byte-distinct, so a `DISTINCT` cannot collapse them and nothing can tell a real
change from poll noise.

### Why this is urgent rather than untidy

ServiceRadar targets deployments of **50,000 to 1,000,000+ devices**. The driver is
devices with SNMP interface tables (network gear), not the total device count, so
the honest extrapolation is per SNMP-polled device:

| SNMP-polled devices | rows/day | storage/day |
| --- | --- | --- |
| 4 (measured) | ~3,070 | ~5 MB |
| 50,000 | ~38M | ~60 GB |
| 1,000,000 | ~767M | ~1.2 TB |

Unbounded, uncompressed, not partitioned, no retention. Roughly 99% of it carries no
information that was not already stored.

The existing `Mapper interface de-duplication and merging` requirement covers
coalescing duplicates **within one job before publishing**. Nothing covers what
happens **across polls over time**, which is where the growth is.

## What Changes

- **ADD a current-state model.** One row per `(device_id, interface_uid)`, upserted. On the
  measured sample this is 374 rows in place of 36,816.

  **The key is `interface_uid`, NOT `if_index`** -- corrected after reading the schema. `if_index`
  is `allow_nil? true` and `inventory/sync/interfaces.ex` never sets it, so sync-produced rows
  carry NULL and a Postgres unique index would not dedupe them. `interface_uid` is
  `allow_nil? false` and already `primary_key? true`. On farm01 the two keys are currently
  indistinguishable (340 distinct pairs each, zero NULLs) only because every interface there comes
  from the mapper -- which is exactly the kind of coincidence that makes a wrong key look right
  until another producer appears.
- **ADD semantic change detection.** A poll that observes no change to the semantic
  state SHALL NOT produce a new stored observation. Per-poll provenance
  (`discovery_id`, `mapper_job_id`, `discovery_time`) updates `last_seen`-style fields
  on the current row; it MUST NOT participate in change detection and MUST NOT create
  a new row on its own.
- **ADD canonical address ordering.** `ip_addresses` SHALL be stored in a canonical
  order so a reordered but identical set is not a change.
- **ADD a bounded history.** Where interface history is required, it SHALL be a
  separate append-only store written ONLY on semantic change, with an explicit
  retention policy and compression. History MUST NOT be a side effect of polling
  frequency.
- Not BREAKING for readers of current interface state; readers of raw per-poll rows
  are enumerated in tasks before anything is removed.

## Impact

- **Affected specs:** `network-discovery` (ADDED). Complements the existing
  `Mapper interface de-duplication and merging` requirement (within-job) by defining
  across-poll persistence.
- **Affected code:** `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex`
  (interface record construction and `prepare_bulk_records/3`, currently
  `upsert_fields: []`), the `DiscoveredInterface` Ash resource and a `platform`
  migration for the current-state key and retention.
- **Open decision for the maintainer:** the retention window for interface history,
  and whether history is required at all beyond "when did this interface last change".
  `tasks.md` measures the real consumer set before choosing; this proposal does not
  assume an answer.
- **Related:** `update-device-identity-interface-and-address-selection` reads interface
  MACs for identity. It deliberately does NOT scan this table -- it registers a compact
  `:interface_mac` identifier instead -- so it is unaffected by this change and does
  not block on it.
