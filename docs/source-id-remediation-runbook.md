# Source id remediation runbook

This runbook covers the source id steps of the DIRE remediation (OpenSpec change
`add-source-id-succession`, design D11). They clean up the device records that a source left
behind when it re-keyed its devices before the fix shipped. When a source replaced a device's
id, the record holding the old id stayed live beside the record created for the new one.

The steps are operator-invoked and dry-run by default. They write only under `--execute`,
each action writes a rollback manifest entry, and a read-only verification step judges the
result.

| Class | Records | Disposition | Step |
| --- | --- | --- | --- |
| 1 | a live record holding a stale source id beside a current one | retire the stale ids; the record stays | `source-id-retire` |
| 2 | a predecessor and a successor sharing a universal MAC and a hostname | succession merge | `source-succession` |
| 3 | a predecessor and a successor sharing a universal MAC and a first-seen time only | succession merge | `source-succession` |
| 4 | a MAC only, or a hostname and a first-seen time without a MAC | review task | `source-succession` |
| 5 | a record holding only retired ids, with no successor | mark `source_retired`; the grace delete follows | `source-id-retire` |
| 6 | sets that are not one-to-one | review task | `source-succession` |
| 7 | released-seed shells (no address, no identifiers, sweep-only) | soft-delete, reason `seed_released` | `released-seed-shells` |
| 8 | one source id in the metadata of several live records | review only | none |

The review tasks of classes 4 and 6 appear under Devices > De-duplication tasks
(`/devices/deduplication`). Class 8 is never merged: `armis-dups` stays disabled.

## Preconditions

1. **The release with the fix runs on every core pod, and the rollout has finished.** Start
   no step mid-rollout: an old pod still ingests with the old rules and keeps creating the
   records the steps remove. Check that every `serviceradar-core` pod runs the new image and
   started before the first step.
2. **Each source instance has had enough exact collections since the release.** An id
   retires once it was absent from N consecutive exact collections (3 by default) and
   unreported for T hours (24 by default). The absences are counted from the first exact
   collection after the release, so until then the dry run counts no retirement and no
   class 5 record. An instance whose latest collection is not exact is left alone (status
   `no_exact_collection`), and its part of each check stays pending.
3. **The Inventory Cleanup settings exist** (Settings > Networks > Inventory Cleanup). Every
   step reads its rules and the mass guard from them, and fails closed without them
   (`settings_unavailable`).
4. **Source retirement is enabled** ("Retire source ids their source stopped reporting").
   `source-id-retire --execute` is refused while it is off (`execution_blocked`, reason
   `source_retirement_disabled`), and the run stops there.

## Settings during the run

All of these are on Settings > Networks > Inventory Cleanup.

- **"Most source succession merges per reconciliation run"**
  (`max_successions_per_run`, default 200): set it to 0 for the whole procedure, so the
  reconciler merges no pair outside a manifest. Restore it once verification passes.
- **Retirement rule**: leave "Retire after missing from consecutive exact collections"
  (default 3) and "And unreported for at least (hours)" (default 24) as they are. The step
  applies the same rule as a scheduled pass.
- **Scheduled retirement passes keep running** after each exact collection, under the same
  rule. Their retirements are in no manifest, and a rollback does not reverse them.
- **Grace period**: "Hide a device left with only retired ids for (days)" (default 7) is the
  rollback window for the marked records. Once it ends, the grace delete removes them
  (`deleted_reason` `source_retired`), and a rollback cannot restore a record it did not
  delete itself. Raise it before the run if you want a longer window.

## Running the steps

### From the core release (production)

Pick one core pod and use it for the whole procedure. The manifests are written to that
pod's filesystem.

```bash
kubectl get pods -n <namespace> -l app=serviceradar-core
kubectl exec -it -n <namespace> <pod> -c core-elx -- /app/bin/serviceradar_core_elx remote
```

In the console:

```elixir
alias ServiceRadar.Inventory.Remediation.DireRemediation

result = DireRemediation.run(steps: ["source-id-retire", "source-succession", "released-seed-shells"])
IO.inspect(result, limit: :infinity, pretty: true)
```

`DireRemediation.run/1` takes the options of the mix task as keywords:

| Mix task flag | `run/1` option |
| --- | --- |
| `--execute` | `mode: :execute` (default `:dry_run`) |
| `--step <name>` (repeatable) | `steps: ["<name>", ...]` |
| `--manifest <path>` | `manifest_path: "<path>"` |
| `--source-batch-size <n>` | `source_batch_size: n` (1..10000; default 500) |
| `--reviewed-source-id <value>` (repeatable) | `reviewed_source_ids: ["<value>", ...]` |
| `--verify-manifest <path>` (repeatable) | `verify_manifests: ["<path>", ...]` |
| `--rollback-manifest <path>` (repeatable) | `rollback_manifests: ["<path>", ...]` |

The call returns `{:ok, result}`, or `{:error, {:step_failures, result}}` when any report
counts a failure (`errors`, any `*_failures` above zero, or `execution_blocked`). Either way
`result` holds every step's report and the manifest path.

Keep the console open until the call returns. If the session drops part way, treat the step
as stopped there: the manifest holds every action up to that point, and a re-run with a new
manifest continues.

### From a checkout

With the database configured, `mix serviceradar.dire_remediation` takes the same steps as
flags, for example
`mix serviceradar.dire_remediation --step source-id-retire --execute --manifest <path>`. It
prints the reports and raises "Remediation completed with failures" when `run/1` returns
step failures. `mix help serviceradar.dire_remediation` lists every option.

### Manifests

- **Name every manifest.** Without `--manifest`, the run writes
  `dire_remediation_<timestamp>_<uuid>.ndjson` under the system tmp dir.
- **The path must not exist.** A manifest is never appended to or overwritten: the run
  refuses to start on an existing file.
- **Copy each manifest off the pod as soon as its run returns.** On the core pod, `/tmp` is
  an `emptyDir` that goes away with the pod:

  ```bash
  kubectl cp -n <namespace> -c core-elx <pod>:/tmp/source_id_retire_1.ndjson ./source_id_retire_1.ndjson
  ```

  Verification and rollback read the manifests from the filesystem of the node they run on.
  Copy them back first if the pod has been replaced.
- **Keep every manifest** of the procedure, including those of re-runs and halted runs.
  Verification and rollback take all of them.

## Order

Always name the steps. `all` (the default) also runs every other DIRE step.

1. **Verify before you start.** Run `source-id-verify` without manifests (see Verification).
   On a deployment that needs the remediation, V1, V2 or V4 fails. If none fails, there is
   nothing to remediate, or the checks cannot see it; do not use them to judge the run.
2. **Dry run the three steps** and read the counts:

   ```elixir
   DireRemediation.run(steps: ["source-id-retire", "source-succession", "released-seed-shells"])
   ```

   - `source-id-retire`: `would_retire_ids`, `would_retire_records`, `class_1_records`,
     `would_leave_retired_only`, `class_5_records`, `guard_would_refuse`, and per instance
     `instance_plans` (status and mass guard verdict).
   - `source-succession`: `class_2_pairs`, `class_3_pairs`, `class_4_reviews`,
     `class_6_reviews`, `review_reasons`, `class_8_groups` and `class_8_records`.
   - `released-seed-shells`: `class_7_shells`.
   - Each count comes with a sample of at most 20 records. Check a few of them by hand
     before executing.

   The counts are taken before any retirement, so the succession counts leave out the pairs
   that the retirements will create. They move with every collection, so recount before
   each execute.
3. **Execute `source-id-retire` alone**, with its own manifest:

   ```elixir
   DireRemediation.run(
     mode: :execute,
     steps: ["source-id-retire"],
     manifest_path: "/tmp/source_id_retire_1.ndjson"
   )
   ```

4. **Dry run `source-succession` again.** The retirements created the predecessors it merges.
5. **Execute `source-succession` and `released-seed-shells`**, with a new manifest:

   ```elixir
   DireRemediation.run(
     mode: :execute,
     steps: ["source-succession", "released-seed-shells"],
     manifest_path: "/tmp/source_id_merge_1.ndjson"
   )
   ```

6. **Verify** with every manifest, and repeat until no check is pending.
7. **Restore** "Most source succession merges per reconciliation run".

The steps are idempotent. A re-run recounts the classes and acts only on what is left. Give
each re-run a new manifest.

## The mass guard

The retire step applies the mass guard per source instance, as a scheduled pass does: a pass
that would affect more than "Largest share of live devices one retirement (per source) or
grace pass may affect" (default 0.5) of the instance's live records is refused. The dry run
reports the verdict per instance (`guard_would_refuse`, `instance_plans[].guard`).

A refused instance is left alone (status `mass_guard_refused`) and counted in
`mass_guard_failures`, which fails the run. Its records are not marked as class 5 either.
If the share is expected, for example a source that re-keyed most of its devices, set
"Allow the next retirement or grace pass to exceed that share" and execute the step again.
The setting admits one pass and then clears itself, so each refused instance needs it set
again. A scheduled pass or grace pass that runs first uses it up.

## Batches and the harm checks

The retire, succession and shell steps work in batches of `source_batch_size` records
(default 500). After each batch they run V6, V7 and V8 over the manifest so far, and stop at
the first check that fails. They also stop at a manifest entry they cannot write, for example
on a full disk.

A stopped step reports `halted` with the check (`"V6"`, `"V7"`, `"V8"`) or `"manifest"`.
The steps after it report `not_run`. Read the failing check in the step's `checks` before
running anything else. If the batch did harm, roll back the manifests.

Other report fields to read after an execute:

- `source-id-retire`: `retired_ids`, `retired_records`, `marked_at_retirement`,
  `class_5_marked`, `class_5_not_marked`, `skipped`, and per instance `instance_plans`. The
  instance statuses are `retired`, `nothing_to_retire`, `mass_guard_refused`,
  `collection_changed`, `unscoped`, `no_exact_collection` and `not_run`.
  - `skipped` counts the records that the recheck under the lock found no longer retirable.
    They stay as they are.
  - An instance whose latest collection changes during the step is left at that point
    (`collection_changed`), and a re-run continues it.
- `source-succession`: `merged`, `merge_blocked` (the merge guard refused the pair), `stale`
  (the pair changed since the plan) and `reviews_recorded`.
- `released-seed-shells`: `tombstoned`, and `shells_left`, the shells still live when the
  step ends. A shell held for review stays, and keeps V4 failing until its review is
  resolved.

## Verification

`source-id-verify` is read-only and is refused under `--execute`. Give it every manifest of
the procedure:

```elixir
DireRemediation.run(
  steps: ["source-id-verify"],
  verify_manifests: ["/tmp/source_id_retire_1.ndjson", "/tmp/source_id_merge_1.ndjson"],
  reviewed_source_ids: []
)
```

The run is taken to start at the earliest manifest header and to finish at its latest entry.
Each check reports `pass`, `fail`, `pending` (it cannot be judged yet) or `not_run` (nothing to
judge, or it needs a manifest it was not given).

| Check | Passes when |
| --- | --- |
| V1 | per source instance, the live records holding an id of the source, plus the unmarked retired-only records, are at most 1.02 per id that the latest exact collection reported, and none when it reported none |
| V2 | the retirement rule admits no id of a live record |
| V3 | no Armis id appears in the metadata of more than one live, unmarked record of one integration source, apart from the reviewed values |
| V4 | no released-seed shell is live |
| V5 | V1-V4 pass after two complete collections of each instance and one completed cycle of each sweep group, all started after the last batch |
| V6 | `device_revival_audit` has no row since the run started for a record the manifests name, apart from the rollback's own |
| V7 | the reconciliation runs since the run started report no failed run and no errors, and one of them started after the last batch |
| V8 | no `source_succession` merge that is still in place joined a retired id and a current id that the latest exact collection both reports |

- **A failing check fails the call**: `verification_failures` above zero makes it return
  step failures, even without `--execute`. A pending check does not (`verification_pending`).
- **V5 waits**:
  - for two complete collections of each source instance that started after the last batch,
    including the instance's latest activated collection;
  - for one completed cycle of each enabled sweep group, per agent, that ran in the day
    before the last batch.
- **V7 waits** for a reconciliation run that started after the last batch.
- **Repeat the verification** until V5 and V7 are no longer pending. Until then, a pass of
  V1-V4 says nothing about whether the result holds.
- **Class 8**: review each group in `class_8_sample` (from the `source-succession` dry run or
  the V3 details). Name each value you have reviewed with `reviewed_source_ids`
  (`--reviewed-source-id`), and V3 leaves it out. A source that aggregates several devices
  under one id is a legitimate class 8 group. Do not enable `armis-dups` for it.
- **Without manifests**, V5 and V6 are not run and V7 judges the latest reconciliation run.
  Use this form before the run and for later spot checks.

## Rollback

`source-id-rollback` reverses the three steps from their manifests. It runs alone, only when
named, and needs at least one manifest. Dry run it first, to see what it would reverse:

```elixir
DireRemediation.run(
  steps: ["source-id-rollback"],
  rollback_manifests: ["/tmp/source_id_merge_1.ndjson", "/tmp/source_id_retire_1.ndjson"]
)

DireRemediation.run(
  mode: :execute,
  steps: ["source-id-rollback"],
  rollback_manifests: ["/tmp/source_id_merge_1.ndjson", "/tmp/source_id_retire_1.ndjson"],
  manifest_path: "/tmp/source_id_rollback_1.ndjson"
)
```

The rollback orders the manifests by their header's start time, the newest first, whatever
order you name them in, and reverses each one's entries last first. To reverse a whole
procedure, name all of its manifests.

| Action | Rollback |
| --- | --- |
| soft-deleted shell | restored, while it is still the tombstone the step made |
| succession merge | unmerged by its merge audit id; the predecessor is marked `source_retired` again, unless an identity-bearing observation reached it since |
| class 5 mark | cleared, unless the record changed since |
| retired ids | returned to their record (or its merge survivor); the returned id clears a mark the retirement made, and the identity state the mark replaced comes back |

Each action reads the state it reverses first. A record that changed since the run is left
as it is and counted in `skipped`, by reason:

| Reason | Meaning |
| --- | --- |
| `shell_changed` | the shell is no longer the tombstone the step made: it was restored, or deleted again |
| `not_merged` | the merged record is no longer the merge's tombstone (it was restored, or deleted otherwise) |
| `merge_superseded` | the record has been merged again since |
| `already_unmerged` | the merge was already reversed |
| `no_merge_audit_found` | no merge audit row of the record has the id the entry names |
| `mark_changed` | the mark was cleared or replaced since, or the grace delete removed the record |
| `not_archived`, `archive_changed` | the id is no longer archived, or its archive row changed |
| `not_source_identifier` | the archive row is not a source id |
| `already_held`, `claimed` | the record already holds the id, or another record does |
| `holder_missing`, `merged_holder` | the record that held the id is gone, or merged away |

A replayed rollback does nothing. The rollback's restores and unmerges carry the application
name `dire_remediation_rollback`, which `device_revival_audit` records, and V6 does not count
them.

The rollback does not reverse:

- **the review decisions** of classes 4 and 6. Close each review task that is no longer
  needed under Devices > De-duplication tasks;
- **the distinct assertion** an unmerge records. The pair stays asserted distinct, so no
  later succession merge joins it again;
- **the facts a merge moved** to the survivor;
- **the grace delete** of a marked record. Its ids return to the tombstone, which stays
  deleted;
- **retirements by scheduled passes**, which are in no manifest.

The rollback writes what it reversed to its own manifest. Keep that manifest with the
others.
