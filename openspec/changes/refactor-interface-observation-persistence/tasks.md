# Tasks

## 1. Size it before changing it

- [ ] 1.1 Re-measure on the largest available deployment, not only farm01 (4 devices).
  The query that produced the baseline: rows vs `DISTINCT (device_id, if_index, if_name,
  if_phys_address, if_oper_status, if_admin_status, if_speed, sorted(ip_addresses))`.
  Baseline to beat: **36,816 rows / 374 states = 98x**, 767 rows/device/day, 57 MB for
  4 devices, no hypertable, no retention, no compression.
- [x] 1.2 **DONE. 19 Elixir modules + SRQL read this table.** Every read site classified; the
  findings below were verified against the source and the database, not inferred.

  **The key must be `(device_id, interface_uid)`, not `(device_id, if_index)`.** `if_index` is
  `allow_nil? true` (`interface.ex:182-184`) and `sync/interfaces.ex` never sets it, so sync rows
  carry NULL and a unique index would not dedupe them. `interface_uid` is `allow_nil? false` and
  already `primary_key? true` (`interface.ex:175-178`). On farm01 both keys look identical -- 340
  distinct pairs each, zero NULLs -- but only because every interface there comes from the mapper.

  **Four things must change BEFORE the identity does, in this order:**

  1. `identity :unique_interface, [:timestamp, :device_id, :interface_uid]` (`interface.ex:401`)
     is the append-only mechanism itself. `timestamp` in the key is why every poll inserts.
  2. `upsert_fields: []` at both writers (`mapper_results_ingestor.ex:3833`,
     `sync/interfaces.ex:164`) is dead today but becomes destructive the moment the key changes:
     ash_postgres emits `DO UPDATE SET <key> = EXCLUDED.<key>`, so every column would freeze at
     its first-observed value forever. Enumerate the fields explicitly first.
  3. `reassignments.ex:219-235` probes for collisions with `timestamp in ^timestamps` and maps to
     `{timestamp, interface_uid}`. Drop `timestamp` from the identity and the probe always misses,
     rows route to `bulk_update`, and hit a duplicate key. It runs inside `Ash.transact` with
     `rollback_on_error?: true` (`merge_engine.ex:226`), so the failure is **every device merge
     rolling back** -- presenting as a merge bug, not an interface bug.

     **CORRECTION to this ordering: it must change in the SAME commit as the identity, not
     before.** The probe decides move-vs-destroy: non-colliding rows are moved to the survivor
     (`bulk_update_interfaces/3`), colliding ones are destroyed (`bulk_delete_interfaces/2`).
     Re-keying the probe on `interface_uid` alone while the identity still contains `timestamp`
     would classify rows as colliding that today do not collide, and destroy rows that today are
     legitimately moved. The probe key must equal the identity at all times, so the two move
     together.
  4. `timestamp` must keep meaning "last observed" and be bumped on every poll. Three readers
     depend on it: `mapper_results_ingestor.ex:2193` (`ago(6, "hour")` liveness -- stable tunnels
     would age out and derived topology edges silently stop) and `interface_data.ex:661/:720`
     (`time:last_3d` -- the device Interfaces tab renders empty).

  **The only user-visible count** is `web-ng .../snmp_profiles_live/index/targeting.ex:144/158`
  ("N targets"). Its `distinct(:device_id)` hides the 98x today; keep it, or a device count becomes
  an interface count.

  Its comment has been corrected already, because the comment WAS the hazard: it said the distinct
  exists "to avoid counting historical snapshots", which this change makes false. A reader would
  then correctly conclude the line is obsolete and delete it, silently turning a device count into
  an interface count -- a factor of hundreds on a switch. The durable reason is now stated: "N
  targets" is a DEVICE count and the distinct is what makes it one.

- [ ] 1.2c Pin that count's device-semantics in a web-ng test (a device with several matching
  interfaces counts once). Not done here: it needs web-ng DB fixtures, and web-ng's formatter
  cannot run without its own deps -- borrowing another project's `deps` swaps the Styler version
  and silently reformats. Do it alongside the rekey.

  **Only three sites are history-dependent** -- `reassignments.ex:219`, `:295`, and the JSON:API id
  at `interface.ex:69` (which embeds the timestamp, an external contract). **None is a trend or
  diff query**, so no reader anywhere requires multiple rows over time.

- [ ] 1.2b Not classified because they sit outside the file set but do read the table:
  `rust/srql/src/query/interfaces/sql.rs`, `.../interfaces/stats.rs:35`, `.../logs/metadata.rs:123`,
  and `web-ng .../live/interface_live/index.ex:290` (`stats:count() as total`, likely a second
  user-visible count). Classify before shipping. Also unknown: whether any dashboard or alert
  threshold is calibrated on the inflated `:active` interface count.
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

## 4. History (needed per 1.3, but NOT required on day one)

Because no reader requires multiple rows over time (1.2), the current-state change can ship before
the history store exists. The causal-analysis consumer needs it; nothing today breaks without it.

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
