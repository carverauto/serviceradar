# Tasks

## 1. Size it before changing it

- [ ] 1.1 Re-measure on the largest available deployment, not only farm01 (4 devices).
  The query that produced the baseline: rows vs `DISTINCT (device_id, if_index, if_name,
  if_phys_address, if_oper_status, if_admin_status, if_speed, sorted(ip_addresses))`.
  Baseline to beat: **36,816 rows / 374 states = 98x**, 767 rows/device/day, 57 MB for
  4 devices, no hypertable, no retention, no compression.
- [ ] 1.2 Enumerate every reader of `platform.discovered_interfaces` before changing the
  write path -- application code, SRQL surfaces, dashboards, and anything that
  compensates today by ordering on `timestamp` and taking the newest. A reader that
  silently depends on duplicates is the way this change breaks something.
- [x] 1.3 **ANSWERED (maintainer, 2026-08-25): history IS needed, for causal analysis.**
  The use case is outage forensics -- "what changed on the network around the time this
  broke". That shapes the schema rather than merely enabling it: the history must record
  WHAT CHANGED (previous value, new value, which fields), not just a snapshot of the new
  state, because a causal query asks "what changed in this window", not "what did every
  interface look like". A poll log cannot answer it -- 98 near-identical rows per
  interface bury the three real transitions. Retention window still to be set; it must
  cover the forensic horizon the causal engine looks back over.

## 2. Stop manufacturing changes

- [ ] 2.1 Sort `ip_addresses` canonically on write. Measured: 12 textual values for 3
  real sets on a single interface.
- [ ] 2.2 Move per-poll provenance (`discovery_id`, `mapper_job_id`, `discovery_time`)
  out of anything that participates in change detection. Measured: `metadata` had 129
  distinct values across 129 rows while every semantic column had exactly 1.
- [ ] 2.3 Confirm no OTHER column carries per-poll noise. The audit that found the two
  above: for one `(device_id, if_index)`, count DISTINCT per column and compare against
  the row count.

## 3. Current state

- [ ] 3.1 Add the current-state key `(device_id, if_index)` and upsert onto it. Today
  `prepare_bulk_records/3` writes with `upsert_fields: []`, which is why every poll
  appends.
- [ ] 3.2 Record last-observation fields (last seen at, last discovery id, last mapper
  job id) on the current row.
- [ ] 3.3 Verify a poll with no semantic change performs no write, or an idempotent one
  -- and prove it by row count, not by reading the code.

## 4. History, only if 1.3 says it is needed

- [ ] 4.1 Write a history row ONLY on semantic change.
- [ ] 4.2 Make it a hypertable with compression and an explicit retention policy.
- [ ] 4.3 Assert the property that matters: halving the discovery interval does not
  increase retained history.

## 5. Migration

- [ ] 5.1 Derive current-state rows from the latest observation per
  `(device_id, if_index)`. The existing rows cannot be de-duplicated in place -- per-poll
  provenance made each byte-distinct, so there is no "true row" to keep.
- [ ] 5.2 State plainly in the migration what is discarded. This drops historical rows
  that were never a deliberate history, but it IS data loss and must be visible.
- [ ] 5.3 Schema changes go in an Elixir migration under `platform`. Ingestion runs no
  DDL.

## 6. Verify against the real failure

- [ ] 6.1 Re-run 1.1 after the change. Expect rows to approach the semantic-state count
  (374 on the farm01 sample), not merely to grow more slowly.
- [ ] 6.2 Confirm interface reads still return correct current state for a device with
  multiple interfaces -- gate on the artefact, and confirm the run postdates the rollout.
- [ ] 6.3 Confirm the row count stops growing while nothing changes. Sample the table,
  wait for at least two discovery cycles with a stable topology, and re-count. A count
  that still climbs means change detection is not detecting.
- [ ] 6.4 Confirm a genuine change is still captured -- take an interface down and see it
  reflected. A change detector that suppresses everything passes 6.3 perfectly.

## 7. Close out

- [ ] 7.1 `openspec validate refactor-interface-observation-persistence --strict`
- [ ] 7.2 Re-check `platform.discovered_interfaces` size and growth on the largest
  deployment and record before/after in the change.
