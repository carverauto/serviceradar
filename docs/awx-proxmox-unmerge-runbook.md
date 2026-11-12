# AWX/Proxmox guest-binding unmerge runbook

This runbook covers the `awx-proxmox-unmerge` and `awx-proxmox-verify` steps of the DIRE
remediation (OpenSpec change `remediate-awx-proxmox-guest-merges`). They repair the records that
the AWX reconciliation merged before `fix-awx-proxmox-guest-binding-evidence` shipped.

Before that change, an AWX host imported from a Proxmox inventory was bound to a Proxmox guest
on node name and VMID alone, across clusters that reuse both, and a locally administered MAC
(such as the fixed veth MAC a CNI gives every Kubernetes node) counted as corroboration. The
reconciliation then merged the guest's device, the device holding the guest's MACs and the AWX
record. The survivor kept the other machine's MACs, addresses and Proxmox references, and kept
absorbing correct records through other merge paths (`hypervisor_guest_network_match`,
`identifier_backfill` and the rest) after the fix shipped, because it still held them.

Every one of those merges, of any reason, has a `platform.merge_audit` row, so the step undoes
them by audit id with `MergeEngine.unmerge_device/2`. The set grows until the repair runs, so the
step computes its plan when it runs, never from a fixed list.

## What the step does

1. **Reads the merges around the AWX merges.** It starts from every merge with reason
   `awx_proxmox_network_match` or `awx_host_network_match`, reads every merge of any reason
   touching their records, and widens to the records the plan implicates until nothing new is
   implicated (at most 8 rounds and 50,000 records, or `candidate_limit_reached`).

2. **Judges each merge in time order.** An AWX merge is bad when its own evidence proves the
   two records are different machines:

   | Proof | Meaning |
   | --- | --- |
   | `different_awx_hosts` | each side holds an AWX v2 host id of one controller, and no id is on both |
   | `proxmox_guest_mismatch` | each side holds a Proxmox guest identity (v2 id or v3 reference), and no cluster and VMID is on both |
   | `laa_only_corroboration` | the merge was corroborated by a MAC, and every MAC the corroborating record held was locally administered |

   "Each side" means what the merged record owned at the merge (`source_identifiers` in the audit
   row) and what the survivor owns that no merge brought it (a merge brought the row of the type,
   value and partition it recorded, or of every partition when it recorded none). A proof is void
   when the two sides share an AWX host id, a guest identity or a universally administered MAC
   (`conflicting_evidence`). For that MAC comparison each side also counts its display MAC, and
   the survivor also counts the MACs other merges into it had brought it, those made before or in
   the same second as this one (`created_at` has second precision). The NIC MACs of the guest the
   merge bound do not count on the side that does not hold that guest's identity: there they are
   the AWX update's copy, and the guest's own record shows the same MACs. Clusters are compared by
   name: two clusters that share a name are never proved distinct.

   **The chain rule.** A bad merge *poisons* its survivor from that moment: the survivor's
   *foreign* set is what the merge recorded for the merged record, the NIC MACs and addresses of
   the guest the merge named (unless the survivor holds that guest's identity itself) and the
   merged record's address. A MAC row the record holds in a partition the merge did not record
   for that value stays its own, except a wrong guest's NIC MAC, which is foreign in every
   partition (an AWX update copied it and no merge recorded it). A merge that stays carries a
   poisoned record's foreign set to its survivor, except poison introduced in its own second,
   which it does not carry. Every merge of a later second touching a poisoned record, of any
   reason, is judged too (`created_at` has second precision, so a merge in the same second as the
   bad merge that shares a record with it is reported as `chained_unproven` and left), and is bad
   when:

   | Proof | Meaning |
   | --- | --- |
   | `proxmox_guest_mismatch` | the merged record holds a guest identity (or, for a non-AWX merge, the merge names one), the survivor had established another, and none is common. Distinct VMIDs or clusters are distinct machines |
   | `tainted_evidence` | everything the match rested on is in the poisoned record's foreign set and none is that record's own (an address the record holds as an ip identifier stays its own even when a bad merge also brought it): the evidence the merge recorded (`identifier_backfill`'s `evidence`), or else the identifiers the two records shared and the address when it was both records' |

   A survivor's established guests are its own and those of merges into it that stay. A shared
   AWX host id, guest identity or universal MAC with the survivor's own identity (display MAC
   included) voids the proof (`conflicting_evidence`); as above, a NIC MAC of a guest the merge
   names or the merged record holds does not count on the side without that guest's identity.
   A merge on a poisoned record that proves
   nothing stays and is reported (`chained_unproven`). That includes the first guest merged
   into a record with no guest identity of its own, which may be that record's machine; every
   later guest with a different VMID is then a second machine.

3. **Groups the bad merges into units.** Bad merges that share records form one unit. A unit is
   undone as a whole or not at all: newest first, a merge after the merge that took its survivor
   away. When any merge of a unit cannot be undone (`not_merged`, `merge_superseded`,
   `survivor_not_live`, or `blocked_by_later_merge` when a merge that stays took a survivor
   away), the whole unit is reported: that merge with its reason, the others as
   `chain_blocked`.

4. **Unmerges each unit in one transaction**: it locks every record of the unit, plans again
   from the same full read as the dry run on the state under the locks (one full read per unit,
   so a unit poisoned through a merge outside it is still seen), and requires the same unit; it
   then undoes each merge by audit id and records each pair as distinct. A refusal anywhere
   rolls the whole unit back.

5. **Returns or archives the wrong-guest MACs.** An AWX update bound to the wrong guest wrote
   that guest's NIC MACs onto whichever record it landed on. No merge recorded them, so no
   unmerge returns them. After the unmerges, a guest MAC row on either record of an undone merge
   is acted on only when all of this holds:

   - the record is proved not to be the guest: it holds another guest's identity, or another
     record holds this guest's identity;
   - the value is a universally administered NIC MAC of the guest (as
     `virtualization_network_interfaces` reports it now);
   - the row was last written by an AWX update (`source` `sync_ingestor` and
     `metadata.integration_type` `awx`), or by the guest's own Proxmox report
     (`integration_type` `hypervisor`, `hypervisor_provider_ref` the guest's);
   - the record's own interfaces do not report it, its AWX host's own Proxmox inventory
     variables do not declare it, and no merge still in place brought it.

   The row goes to the record that holds the guest's identity when exactly one live record does
   (`move`, often the record a unit just restored). When none does, an AWX-written row goes to
   `device_identifier_archive` with reason `awx_wrong_guest_mac` (`remove`); when several do,
   the row is kept (`guest_record_ambiguous`); a row the guest's own report refreshed is never
   archived. Every other row of a guest MAC is kept and reported with its reason:
   `device_not_proven_other_machine`, `locally_administered`, `not_awx_provenance`,
   `refreshed_by_guest_report`, `guest_record_ambiguous`, `observed_on_device`,
   `declared_by_awx_host` or `absorbed_by_merge`. Afterwards the step re-queries every row it
   acted on; one not where it should be counts in `mac_rows_not_settled` and
   `mac_cleanup_failures`.

## Preconditions

1. **The release carrying `fix-awx-proxmox-guest-binding-evidence` runs on every core pod, and
   the rollout has finished.** That change closes the path that created the bad merges. An old
   pod still binds AWX hosts by node name and VMID and recreates what the step removes.
2. **At least one AWX sync and one Proxmox sync completed after the rollout**, so the guests'
   NIC MACs and the AWX records are current.
3. **Copy each manifest off the pod as soon as its run returns** (see Manifests below).

## Running in a release pod

The release image has no Mix. Run the steps through the release's remote shell, or its `rpc`
command, on one core pod, and use that pod for the whole procedure: the manifests are written to
its filesystem. Do not use `eval`: it starts a separate VM without the application or its
database connection.

```bash
kubectl get pods -n <namespace> -l app=serviceradar-core
kubectl exec -it -n <namespace> <pod> -c core-elx -- /app/bin/serviceradar_core_elx remote
```

In the console:

```elixir
alias ServiceRadar.Inventory.Remediation.DireRemediation
```

The non-interactive form runs one expression in the running node and prints what it returns.
Write the report to a file and copy it off, because a dry run report can be long:

```bash
kubectl exec -n <namespace> <pod> -c core-elx -- /app/bin/serviceradar_core_elx rpc '
  result = ServiceRadar.Inventory.Remediation.DireRemediation.run(steps: ["awx-proxmox-unmerge"])
  File.write!("/tmp/awx_unmerge_dry_run.txt", inspect(result, pretty: true, limit: :infinity))
  IO.puts("written")'
kubectl cp -n <namespace> -c core-elx <pod>:/tmp/awx_unmerge_dry_run.txt ./awx_unmerge_dry_run.txt
```

`DireRemediation.run/1` options for these steps:

| Mix task flag | `run/1` option |
| --- | --- |
| `--execute` | `mode: :execute` (default `:dry_run`) |
| `--step <name>` | `steps: ["awx-proxmox-unmerge"]`, `steps: ["awx-proxmox-verify"]` |
| `--manifest <path>` | `manifest_path: "<path>"` |
| `--awx-proxmox-unmerge-event <uuid>` (repeatable) | `awx_proxmox_unmerge_event_ids: ["<uuid>", ...]` |
| `--awx-proxmox-unmerge-candidate-limit <n>` | `awx_proxmox_unmerge_candidate_limit: n` (default 5000) |
| `--awx-proxmox-unmerge-report-limit <n>` | `awx_proxmox_unmerge_report_limit: n` (default 500) |
| `--rollback-manifest <path>` (repeatable) | `rollback_manifests: ["<path>", ...]` |

From a checkout with the database configured, the mix task takes the same steps as flags, for
example `mix serviceradar.dire_remediation --step awx-proxmox-unmerge`.

## 1. Verify before you start

```elixir
DireRemediation.run(steps: ["awx-proxmox-verify"])
```

On a deployment that needs the repair, A2 fails and lists the merges that join different
machines. A1, A4 and A5 pass trivially and A3 is `not_run` before any repair.

## 2. Dry run

```elixir
{:ok, %{reports: %{"awx-proxmox-unmerge" => report}}} =
  DireRemediation.run(steps: ["awx-proxmox-unmerge"])
```

Read:

- `merges_read`, `proved_different_machines`, `dispositions` (count per disposition),
  `planned_units`, `planned_unmerges` and `candidate_limit_reached`. Execute refuses while
  `candidate_limit_reached` is true: raise the limit so every AWX merge is read, or chains could
  be cut.
- `unmerge_plan`: every unit the step will undo (`order`, `unit`), each with its merges in
  execution order. Each merge has the audit id, reason, `proofs`, `match_evidence` (what a
  chained merge rested on, as `mac:`, `ip:` or `<type>:` values), `recorded_evidence`,
  `corroboration`, `awx_integration_id` and `guest_provider_ref`, and for both records (`from`,
  the merged record, and `to`, the survivor) the uid, hostname, IP (and the hostname and IP at
  the merge) and Proxmox guest identities; an AWX merge also shows AWX host ids
  (`controller/host`) and universally administered MACs.
- `reported_merges`: every other judged merge with its `disposition`: an ambiguity
  (`no_distinguishing_evidence`, `conflicting_evidence`, `source_identifiers_unrecorded`,
  `chained_unproven`), `already_unmerged`, a refusal (`not_merged`, `merge_superseded`,
  `survivor_not_live`, `blocked_by_later_merge` with `blocked_by`, the event id of the merge
  that took the survivor away), `chain_blocked` (with `blocked_by`, the merge of its unit that
  refused and why) or `not_selected`.
- `mac_cleanup_plan`: every MAC row the step will move (`decision` `move`, with `target_uid`) or
  archive (`remove`), with its row id, record, value, `source`, `integration_type`,
  `sync_service_id`, `reported_guest_ref`, `first_seen`, `last_seen`, the guest it belongs to,
  the merges it follows from, and the latest archive history of the value.
- `mac_rows_kept` (count per reason), `mac_kept_sample` and `mac_guests_skipped`
  (`guest_not_found`, `guest_not_unique`).

Check every unit: in each merge the two records must be different machines by their AWX host
ids, guest identities, hostnames, addresses and match evidence. Review every `chained_unproven`
merge on a poisoned record too: it stays, and A2 keeps reporting nothing for it, but it may be
the one guest that record really is. To execute only the units you have checked, name any merge
of each with `awx_proxmox_unmerge_event_ids`: a unit runs whole, so naming one of its merges
selects all of them.

## 3. Execute

Enable the gate in the running node. It is runtime configuration: it lasts until the pod
restarts, and you switch it off again in step 4.

```elixir
config = Application.get_env(:serviceradar_core, DireRemediation, [])

Application.put_env(
  :serviceradar_core,
  DireRemediation,
  Keyword.put(config, :enable_awx_proxmox_unmerge_execute, true)
)

DireRemediation.run(
  mode: :execute,
  steps: ["awx-proxmox-unmerge"],
  manifest_path: "/tmp/awx_proxmox_unmerge_1.ndjson"
)
```

Or, without the console:

```bash
kubectl exec -n <namespace> <pod> -c core-elx -- /app/bin/serviceradar_core_elx rpc '
  alias ServiceRadar.Inventory.Remediation.DireRemediation
  config = Application.get_env(:serviceradar_core, DireRemediation, [])
  Application.put_env(:serviceradar_core, DireRemediation,
    Keyword.put(config, :enable_awx_proxmox_unmerge_execute, true))
  result = DireRemediation.run(mode: :execute, steps: ["awx-proxmox-unmerge"],
    manifest_path: "/tmp/awx_proxmox_unmerge_1.ndjson")
  File.write!("/tmp/awx_unmerge_execute_1.txt", inspect(result, pretty: true, limit: :infinity))
  IO.puts("written")'
kubectl cp -n <namespace> -c core-elx <pod>:/tmp/awx_proxmox_unmerge_1.ndjson ./awx_proxmox_unmerge_1.ndjson
```

Read `units_applied`, `unmerged`, `distinct_asserted`, `units_skipped` (per reason: the plan
under the locks no longer gave the same unit, or an unmerge refused; the whole unit rolled back),
`unit_failures`, `mac_rows_moved`, `mac_rows_archived`, `mac_rows_stale` (rows that changed
between the plan and the lock), `mac_rows_not_settled` and `mac_cleanup_failures`. Any
`*_failures` above zero, or `execution_blocked`, makes the call return
`{:error, {:step_failures, result}}`. `halted` `"manifest"` means a manifest entry could not be
written and the step stopped there.

The step is idempotent: a re-run with a new manifest acts only on what is left.

## 4. Switch the gate off

```elixir
config = Application.get_env(:serviceradar_core, DireRemediation, [])

Application.put_env(
  :serviceradar_core,
  DireRemediation,
  Keyword.delete(config, :enable_awx_proxmox_unmerge_execute)
)
```

## 5. Verify, now and after later syncs

```elixir
DireRemediation.run(steps: ["awx-proxmox-verify"])
```

| Check | Passes when |
| --- | --- |
| A1 | no pair the step unmerged is one record again, following each record through the merges that took it away |
| A2 | no merge the plan judges bad is still in place, AWX merges and chained merges of any reason alike |
| A3 | no such merge was made after the repair started (`not_run` before any repair) |
| A4 | no MAC row the step archived is back on the record it was taken from |
| A5 | every unmerged pair is still asserted distinct |

While `candidate_limit_reached` is true, A2 and A3 fail with reason `candidate_limit_reached`
(once a repair has run, for A3): a merge outside the read window is not checked.

`verification_failures` above zero fails the call. `settled` is true once every AWX controller
and every guest the repair touched has been observed again since the repair finished; until then
`verification_pending` is 1, and a pass says nothing about whether the result holds. Repeat after
the next AWX and Proxmox syncs. A2 keeps failing for a merge the step reported as
`blocked_by_later_merge`: it is still wrong, and needs an operator decision on the blocking merge.

## Rollback

`source-id-rollback` reverses the step from its manifests. It runs alone and needs at least one
manifest. Dry run it first:

```elixir
DireRemediation.run(
  steps: ["source-id-rollback"],
  rollback_manifests: ["/tmp/awx_proxmox_unmerge_1.ndjson"]
)

DireRemediation.run(
  mode: :execute,
  steps: ["source-id-rollback"],
  rollback_manifests: ["/tmp/awx_proxmox_unmerge_1.ndjson"],
  manifest_path: "/tmp/awx_proxmox_unmerge_rollback_1.ndjson"
)
```

The dry run reports `would_remerge` and `would_restore_macs`. The rollback reads the entries last
first:

| Action | Rollback |
| --- | --- |
| archived wrong-guest MAC | returned to its record while the record is live and no record holds the value now; others count in `skipped` as `mac_not_restorable` |
| moved wrong-guest MAC | moved back from the guest's record to the record it was taken from, while it is still on the guest's record and the other record is live; others count as `mac_not_restorable` |
| unmerge | the distinct assertion the step recorded is removed, and the pair is merged again, the merged record into the survivor, as an administrative merge (reason `manual_awx_unmerge_rollback`); skipped as `not_unmerged`, `record_changed` or `merged_since` when the pair is no longer as the unmerge left it |

Reading last first re-merges a chain in its original order. When undoing an unmerge, a MAC
archive or a MAC move fails, the rollback stops there (`halted` names the action,
`rollback_failures` counts it): going on would re-merge a later pair of the chain and take away
the record the failed entry needs. Fix the cause and run the rollback again; entries already
undone are skipped. The re-merge is a new merge: it records its own audit row and moves what the
merged record holds now. The rollback does not remove an assertion that existed before the step
ran.

## Cooldown and re-merge

- The unmerge writes a merge audit row (reason `unmerge`) for the pair. The merge guard counts
  any audit row of the pair, in either direction, in the last `merge_cooldown_seconds` (86,400 by
  default), so no automatic merge joins the pair for a day.
- The step also records the pair as distinct (`identity_distinct_assertions`). The merge guard
  refuses an asserted pair on every automatic path (ingest, alias, registration, the scheduled
  backfill), with no time limit. Only an administrative merge passes it.
- `fix-awx-proxmox-guest-binding-evidence` removed the binding that produced these merges. The
  unmerges return what each merge recorded, and the MAC cleanup moves or archives the wrong-guest
  MACs no merge recorded, which are what let a survivor match further records
  (`hypervisor_guest_network_match`, `identifier_backfill`). A merge guard between records with
  distinct Proxmox guest identities is a separate change; this step changes no guard.

## What the step leaves

- **AWX host ids on the guest's device.** When an AWX host had no record of its own at its first
  sync, its update registered its AWX id directly on the wrong guest's device, with no merge.
  Undoing the holder's merge does not move it. The AWX host's updates keep landing on that device
  until the id is moved by hand. The dry run shows it as an AWX host id on a `to` record whose
  guest identity is the bound guest.
- **What a merge moved besides identifiers.** An unmerge returns identifiers and archived
  identifiers. Interfaces, service checks, alerts and availability the merge moved stay on the
  survivor.
- **Display fields.** The display MAC and the address an AWX update set on a record are not
  changed. A survivor that kept a wrong address can still match by address until a sync of its
  own source corrects it; such later merges are judged on the next run.
- **`chained_unproven` merges**, among them the first guest merged into a record with no guest
  identity of its own.
- **Rows the step cannot prove**, listed in `mac_kept_sample` and `reported_merges`.

## Manifests

- Name every manifest; the path must not exist.
- On the core pod, `/tmp` goes away with the pod. Copy each manifest off as soon as its run
  returns, and keep every manifest, including those of re-runs and halted runs:

  ```bash
  kubectl cp -n <namespace> -c core-elx <pod>:/tmp/awx_proxmox_unmerge_1.ndjson ./awx_proxmox_unmerge_1.ndjson
  ```

- Each unit writes a `candidate_preflight` entry before its transaction, one `awx_unmerge`
  entry per merge inside it and a `candidate_committed` marker after it. Each record's MAC
  cleanup writes the same three, with `archive_wrong_guest_mac` (an archive) or
  `reassign_wrong_guest_mac` (a move to the guest's record) in the middle. An `awx_unmerge` entry
  without a committed marker means the transaction may not have committed; the rollback checks
  the state before it acts.
