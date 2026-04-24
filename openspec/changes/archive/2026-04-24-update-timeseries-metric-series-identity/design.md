## Context
`platform.timeseries_metrics` is modeled as a hypertable but the current Ash identity and schema fixtures treat `(timestamp, gateway_id, metric_name)` as unique. That only works when each metric name appears once per gateway at a given timestamp. Real SNMP payloads violate that assumption immediately because `ifInOctets`, `ifOutOctets`, `ifInErrors`, and similar counters are emitted once per interface. ICMP and plugin telemetry can also collide when multiple checks/plugins emit the same metric name through a gateway.

The current ingestors partially hide the problem by deduping rows in-memory on the same narrow key, which silently drops distinct data. When two distinct rows survive into the same insert batch, Postgres raises `ON CONFLICT DO UPDATE command cannot affect row a second time`.

## Goals
- Preserve all legitimate per-device and per-interface metric samples.
- Keep repeated identical samples idempotent.
- Define one timeseries identity contract shared by all ingestors.
- Migrate existing data without forcing consumers to stop querying `timeseries_metrics`.

## Non-Goals
- Rebuild historical metrics semantics beyond deterministic backfill of the new identity.
- Redesign SRQL query syntax.
- Introduce metric-type-specific tables.

## Decision
Introduce a stable `series_key` text column. `series_key` is the canonical identity for one metric series within a gateway at a point in time. It must include enough dimensions to distinguish distinct sources while staying deterministic across replays.

Minimum inputs for `series_key`:
- `metric_type`
- `metric_name`
- `partition` when present
- `device_id` when present
- `target_device_ip` when present
- `if_index` when present
- stable tag-derived identifiers used by non-SNMP ingestors when they materially distinguish series (for example check/plugin IDs)

The exact encoding can be a delimited canonical string or a hash derived from a canonical string, but it must be deterministic and shared across all ingestors.

## Migration Shape
1. Add nullable `series_key` column.
2. Backfill existing rows in batches from current dimensional fields.
3. Make `series_key` non-null for newly written rows and switch Ash/resource code to populate it.
4. Create the new unique index/constraint on `(timestamp, gateway_id, series_key)`.
5. Remove the old uniqueness contract once readers and writers are aligned.

## Risks
- Backfill on a large hypertable can be expensive; migration should batch and/or use a helper function that can be resumed safely.
- Some historical rows may not have enough dimensions populated to perfectly distinguish old collisions; the deterministic backfill should still preserve the best available separation from existing fields.
- Any downstream code assuming `metric_name` uniqueness within a timestamp/gateway needs validation.

## Validation Plan
- Unit tests for `series_key` generation across SNMP, ICMP, and plugin samples.
- Integration tests that ingest multiple same-metric samples from different interfaces/devices in a single batch.
- Manual verification that the previous `cardinality_violation` log pattern disappears on demo after rollout.
