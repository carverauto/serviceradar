# AWX/Proxmox guest-binding unmerge runbook

This runbook covers the `awx-proxmox-unmerge` and `awx-proxmox-verify` steps of the DIRE
remediation (OpenSpec change `remediate-awx-proxmox-guest-merges`). They repair the records that
the AWX reconciliation merged before `fix-awx-proxmox-guest-binding-evidence` shipped.

Before that change, an AWX host imported from a Proxmox inventory was bound to a Proxmox guest
on node name and VMID alone, across clusters that reuse both, and a locally administered MAC
(such as the fixed veth MAC a CNI gives every Kubernetes node) counted as corroboration. The
reconciliation then merged the guest's device, the device holding the guest's MACs and the AWX
record. Each survivor held more machines' MACs and matched more devices on the next sync.

Every one of those merges has a `platform.merge_audit` row with reason
`awx_proxmox_network_match` (or `awx_host_network_match`, without a guest), so the step undoes
them by audit id with `MergeEngine.unmerge_device/2`.

## What the step does

1. **Judges every AWX merge.** A merge is undone only when the evidence proves that the two
   records are different machines:

   | Proof | Meaning |
   | --- | --- |
   | `different_awx_hosts` | each side holds an AWX v2 host id of one controller, and no id is on both |
   | `proxmox_guest_mismatch` | each side holds a Proxmox guest identity (v2 id or v3 reference), and no cluster and VMID is on both |
   | `laa_only_corroboration` | the merge was corroborated by a MAC, and every MAC the corroborating record held was locally administered |

   "Each side" means what the merged record owned at the merge (`source_identifiers` in the
   audit row) and what the survivor owns that no merge brought it. A proof is void when the two
   sides share an AWX host id, a guest identity or a universally administered MAC
   (`conflicting_evidence`). Clusters are compared by name: two clusters that share a name are
   never proved distinct.

2. **Orders the unmerges.** Newest first. When the survivor of a merge was later merged away, the
   merge that took it away is undone first. When that merge does not qualify, neither is undone
   (`blocked_by_later_merge`). A later merge onto the survivor of a wrong merge is reported
   (`follows_bad_merge`) and never undone on that ground alone: it may have matched only on what
   the wrong merge brought, or on real evidence, and the audit does not say which.

3. **Unmerges** each merge in its own transaction: it locks both records, rechecks the plan for
   that merge under the locks, undoes it by audit id, and records the pair as distinct.

4. **Archives the wrong-guest MACs.** An AWX update bound to the wrong guest wrote that guest's
   NIC MACs onto whichever record it landed on. No merge recorded them, so no unmerge returns
   them. After the unmerges, a MAC identifier row is moved to `device_identifier_archive` (reason
   `awx_wrong_guest_mac`) only when all of this holds:

   - the record is proved not to be the guest: it holds another guest's identity, or the other
     side of a proved merge holds this guest's identity;
   - the value is a universally administered NIC MAC of the guest (as
     `virtualization_network_interfaces` reports it now);
   - the row was last written by an AWX update (`source` `sync_ingestor` and
     `metadata.integration_type` `awx`);
   - the record's own interfaces do not report it, its AWX host's own Proxmox inventory
     variables do not declare it, and no merge still in place brought it.

   Every other row of a guest MAC is kept and reported with its reason:
   `device_not_proven_other_machine`, `locally_administered`, `not_awx_provenance`,
   `observed_on_device`, `declared_by_awx_host` or `absorbed_by_merge`. After archiving, the
   step re-queries the rows; a row still present counts in `mac_cleanup_failures`.

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

- `awx_merges`, `proved_different_machines`, `dispositions` (count per disposition) and
  `candidate_limit_reached`. Execute refuses while `candidate_limit_reached` is true: raise the
  limit so every AWX merge is read, or chains could be cut.
- `unmerge_plan`: every merge the step will undo, in execution order (`order`). Each entry has
  the audit id, reason, `proofs`, `corroboration`, `awx_integration_id`, `guest_provider_ref`
  and the bound guest (`cluster/vmid`), and for both records (`from`, the merged record, and
  `to`, the survivor) the uid, hostname, IP (and the hostname and IP at the merge), AWX host ids
  (`controller/host`), Proxmox guest identities and universally administered MACs.
- `reported_merges`: every other merge with its `disposition`: an ambiguity
  (`no_distinguishing_evidence`, `conflicting_evidence`, `source_identifiers_unrecorded`),
  `already_unmerged`, `not_merged`, `merge_superseded`, `survivor_not_live`,
  `blocked_by_later_merge` (with `blocked_by`), `follows_bad_merge` (with `follows_bad_merges`)
  or `not_selected`.
- `mac_cleanup_plan`: every MAC row the step will archive, with its row id, record, value,
  `source`, `integration_type`, `sync_service_id`, `first_seen`, `last_seen`, the guest it
  belongs to, the merges it follows from, and the latest archive history of the value.
- `mac_rows_kept` (count per reason), `mac_kept_sample` and `mac_guests_skipped`
  (`guest_not_found`, `guest_not_unique`).

Check every `unmerge_plan` entry: the two records must be different machines by their AWX host
ids, guest identities, hostnames and addresses. To execute only the entries you have checked,
name them with `awx_proxmox_unmerge_event_ids`. A named merge whose survivor an unnamed merge took
away stays blocked.

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

Read `unmerged`, `distinct_asserted`, `unmerge_skipped` (per reason: the recheck under the locks
found the merge changed, or the unmerge refused it), `unmerge_failures`, `mac_rows_archived`,
`mac_rows_stale` (rows that changed between the plan and the lock), `mac_rows_still_present`
and `mac_cleanup_failures`. Any `*_failures` above zero, or `execution_blocked`, makes the call
return `{:error, {:step_failures, result}}`. `halted` `"manifest"` means a manifest entry could
not be written and the step stopped there.

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
| A2 | no AWX merge still in place is proved to join different machines |
| A3 | no such merge was made after the repair started (`not_run` before any repair) |
| A4 | no MAC row the step archived is back on the record it was taken from |
| A5 | every unmerged pair is still asserted distinct |

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
| unmerge | the distinct assertion the step recorded is removed, and the pair is merged again, the merged record into the survivor, as an administrative merge (reason `manual_awx_unmerge_rollback`); skipped as `not_unmerged`, `record_changed` or `merged_since` when the pair is no longer as the unmerge left it |

Reading last first re-merges a chain in its original order. The re-merge is a new merge: it
records its own audit row and moves what the merged record holds now. The rollback does not
remove an assertion that existed before the step ran.

## Cooldown and re-merge

- The unmerge writes a merge audit row (reason `unmerge`) for the pair. The merge guard counts
  any audit row of the pair, in either direction, in the last `merge_cooldown_seconds` (86,400 by
  default), so no automatic merge joins the pair for a day.
- The step also records the pair as distinct (`identity_distinct_assertions`). The merge guard
  refuses an asserted pair on every automatic path (ingest, alias, registration, the scheduled
  backfill), with no time limit. Only an administrative merge passes it.
- `fix-awx-proxmox-guest-binding-evidence` removed the binding that produced these merges. The
  MAC cleanup removes the wrong-guest MACs that let a survivor match the guest again.

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
  changed.
- **Rows the step cannot prove**, listed in `mac_kept_sample` and `reported_merges`.

## Manifests

- Name every manifest; the path must not exist.
- On the core pod, `/tmp` goes away with the pod. Copy each manifest off as soon as its run
  returns, and keep every manifest, including those of re-runs and halted runs:

  ```bash
  kubectl cp -n <namespace> -c core-elx <pod>:/tmp/awx_proxmox_unmerge_1.ndjson ./awx_proxmox_unmerge_1.ndjson
  ```

- Each unmerge writes a `candidate_preflight` entry before its transaction, an `awx_unmerge`
  entry inside it and a `candidate_committed` marker after it. Each record's MAC cleanup writes
  the same three, with `archive_wrong_guest_mac` in the middle. An `awx_unmerge` entry without a
  committed marker means the transaction may not have committed; the rollback checks the state
  before it acts.
