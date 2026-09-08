# Tasks

## 0. PRIORITY: endpoint clustering produces no summaries on qualifying anchors

Observed on `demo` 2026-08-27. Nothing renders beneath `aruba-24g-02` or `tonka01` even
though the attachment data is complete and qualifying:

```
aruba-24g-02 (192.168.10.154)
  attached endpoints        : 10
  resolved to live devices  : 10   (unresolved: 0)
  infrastructure-typed      :  2   (tonka01, MikroTik)
  endpoint-like             :  8   >= @endpoint_cluster_min_members (3)
  clusters produced         :  0
```

Pipeline stats for the same run: `final_attachment: 17`, `pair_attachment: 24`,
`clustered_endpoint_summaries: 0`, `quarantined_unresolved_endpoint_nodes: 33`.

- [ ] 0.1 Determine why `endpoint_cluster_groups/3` yields no group for an anchor with 8
      resolvable endpoint-like attachments. This is NOT the connectivity-forest routing bug
      (fixed, #4067) and NOT sub-threshold admission (PR #4068 -- 8 is above the minimum).
- [ ] 0.2 Account for `pair_attachment: 24 -> final_attachment: 17`; 7 attachments are lost
      after pairing.
- [ ] 0.3 Account for `quarantined_unresolved_endpoint_nodes: 33`. Aruba's endpoints all
      resolve, so the quarantined set is elsewhere -- find whose, and whether quarantine is
      correct now that 109 devices were deliberately deleted.
- [ ] 0.4 Add a regression test with a real device map: an anchor with N >= minimum
      resolvable endpoint-like attachments MUST produce exactly one summary. Every existing
      conversion test passes an EMPTY device map, which is why this class of bug survives.

## 0b. A down host reads as healthy and freshly seen

RESOLVED on 2026-08-27: this is NOT an identity or IP-reuse problem, and the sweep is not
fabricating results. `MikroTik` (192.168.6.167) is genuinely powered off -- unreachable from
the operator's workstation AND from dusk01, the host running the reporting agent. The agent
reports it correctly. Two defects then discard that answer:

```
device 192.168.6.167  is_available: TRUE   last_seen_time: 06:19:46  modified: 06:19:47
                      availability_source_agent_id: (empty)
agent-dusk01          06:19:30  is_available: FALSE   <- correct, and ignored
agent-sr-test-pve04   05:05:37  is_available: TRUE    <- 77 min stale, never expired
```

- [ ] 0b.1 **Inventory presence is recorded as liveness.** CORRECTED 2026-08-27: the sweep is
      NOT the culprit. `sweep_results_ingestor.ex` writes `last_seen_time` in exactly one place
      (line 1252, the positive path); the negative path deliberately does not, and carries the
      comment "Do not use last_seen_time here: inventory integrations can refresh it
      independently and would otherwise keep failed sweep targets online forever."
      That is exactly what is happening through another door: MikroTik's sources are
      `mapper,proxmox,sweep`, and Proxmox still lists a POWERED-OFF guest as a configured VM,
      so the inventory sync refreshes last-seen for a host that cannot answer. Decide whether
      an inventory integration may refresh last-seen at all -- being *configured* is not being
      *present*.
- [ ] 0b.2 **The canonical bit is frozen true.** `availability_source_agent_id` is empty, so
      per the v1.4.45 upgrade note the canonical `is_available` is never updated for a device
      covered only by an all-agents group. The agent's correct `false` never lands.
- [ ] 0b.3 **Per-agent observations never expire.** `agent-sr-test-pve04` last checked at
      05:05:37 and still asserts `is_available: true` 77 minutes later. A stale positive
      outlives a fresh negative.
- [ ] 0b.4 **BLOCKS TASK 2.** Device expiry keys on `last_seen_time`. While 0b.1 stands, a
      dead-but-still-swept device has its last-seen refreshed forever, so expiry can never
      fire. Building expiry without fixing 0b.1 produces a feature that silently does
      nothing. Fix 0b.1 first, or expiry must key on something other than last-seen.

## 1. Agent decommissioning

- [ ] 1.1 Add a decommission action to `ServiceRadar.Infrastructure.Agent`. The resource has
      no destroy action today; `retire_stale` exists but is invoked only by
      `PruneStaleAgentsWorker` after `@default_retention_hours 24`.
- [ ] 1.2 Have it call `GatewayCertificateIssuer.revoke_agent_certificate/3`, which already
      RPCs the issuing gateway. Reachable today only as
      `POST /api/admin/gateways/:gateway_id/agent-certs/:component_id/revoke`.
- [ ] 1.3 Surface it on `AgentLive.Show`, which currently defines **zero** `handle_event`
      clauses -- the page is entirely read-only.
- [ ] 1.4 Authorize the event (LiveView iron law: authorize in every `handle_event`).
- [ ] 1.5 Record actor and timestamp; keep the row queryable for audit.
- [ ] 1.6 Make the Edge Ops package dialog stop reading as a removal path. Deleting a
      `delivered` package revokes nothing -- verified on `agent-dusk01`, which stayed
      `Connected` and acked config 22s after its package was deleted.
- [ ] 1.7 Handle the already-offline case: revoke without failing on the absent session.

## 2. Device expiry

- [ ] 2.1 Add a scheduled expiry pass that soft-deletes devices unseen beyond a retention
      window, with reason and actor. `DeviceCleanupWorker` today purges only rows that are
      *already* soft-deleted.
- [ ] 2.2 Default to disabled. `demo` holds 49,932 devices unseen >30d; a first pass would
      soft-delete them all at once.
- [ ] 2.3 Apply a mass-deletion guard on the same terms as the canonical prune, and log a
      refusal rather than failing silently.
- [ ] 2.4 Confirm revival behaviour: a device that reports again must be revived through the
      existing identity paths and recorded in `platform.device_revival_audit`, not silently
      cleared. Three code paths clear a tombstone (`:gateway_sync`, `:restore`, and a raw
      Ecto `on_conflict` in `inventory/sync/device_writes.ex`) -- a guard in an Ash change
      module is blind to the third.

## 3. Guard and stats observability

- [x] 3.1 WITHDRAWN -- already implemented, and correctly. `report_prune_refusal/5`
      (canonical_rebuild.ex:397) emits a `prune_refused` telemetry event AND
      `Logger.error("Canonical topology stale prune refused (reason): would delete N of M
      canonical edges in one pass (max fraction F); set canonical_prune_guard_override to
      force")` -- counts, total, fraction and the override, exactly what this task proposed
      adding. The reason no such line appeared in demo's logs is that nothing was
      prune-eligible yet. Corrected 2026-08-27 with the actual mechanism: the canonical AGE
      prune keys off `Utils.stale_cutoff_iso8601()`, driven by
      `SERVICERADAR_MAPPER_TOPOLOGY_EDGE_STALE_MINUTES` (values-demo.yaml:662 = 10080, i.e.
      7 days) -- NOT `SERVICERADAR_TOPOLOGY_LINK_RETENTION_DAYS`, which feeds
      `data_retention_worker.ex` for the relational links table. Demo's oldest canonical edge
      is 2026-08-21 against a 2026-08-20 cutoff, so `prune_result: :ok` with
      `before_edges == after_prune_edges == 228` is correct behaviour, not a blocked prune.
      "The guard blocks silently" was wrong.
- [ ] 3.4 Wire the `TopologyGraph` guard config into the DEPLOYED release. The guard reads
      `Application.get_env(:serviceradar_core, ServiceRadar.NetworkDiscovery.TopologyGraph)`
      for `canonical_prune_max_fraction` and `canonical_prune_guard_override`, but that
      `config` block exists only in `elixir/serviceradar_core/config/runtime.exs:1256`. The
      deployed app is `serviceradar_core_elx`, and a release evaluates only its OWN
      runtime.exs -- which has no `TopologyGraph` block at all. Both settings therefore fall
      to compiled defaults (0.5 / false) in production and CANNOT be overridden.
      Setting `SERVICERADAR_TOPOLOGY_CANONICAL_PRUNE_GUARD_OVERRIDE=true` on the demo
      deployment on 2026-08-27 was verified to be a no-op for this reason.
      This is imminent, not theoretical: 174 of demo's 228 canonical edges (76.3%) are
      ghosts from the decommissioned 192.168.1.x estate. They cross the 7-day cutoff around
      2026-08-28, at which point the guard refuses (76.3% > 50%) and the documented escape
      hatch does not exist. Either add the block to core_elx's runtime.exs or move it to a
      shared config the release actually loads; then re-check with the refusal log line.

- [ ] 3.2 Fix `raw_evidence_class/1` precedence, or rename its counters. It resolves
      explicit evidence before `relation_type`, the inverse of `evidence_class/1`, so
      `raw_attachment: 0` was reported against 334 real `ATTACHED_TO` links. That single
      counter is what sent the 2026-08-27 investigation looking for missing data.
- [ ] 3.3 Stop deriving `pair_*` and `final_*` from the same list.
      `prepare_runtime_edge_pipeline/2` sets `pair_edges: final_edges`, so the two families
      can never disagree and cannot localise a loss.

- [ ] 3.5 Re-point canonical topology after an identity merge. When
      `identity_reconciler` merges two devices it soft-deletes the loser with
      `deleted_reason: "merged"`, but nothing re-points or removes the canonical edges that
      reference the retired uid. Measured on demo 2026-08-27: `pve02` had BOTH a live uid
      (`sr:5bf1b6f6...`, 9 edges) and a merged tombstone (`sr:9792202c...`, 7 edges) in
      `CANONICAL_TOPOLOGY`, and their peer sets were IDENTICAL (tonka01, aruba-24g-02,
      EDGE-1 under two IPs). So the graph draws the same host twice, and the tombstone half
      is indistinguishable from a departed-estate ghost by the deleted_at test. These edges
      are still being refreshed (last observed within the hour), so deleting them is
      pointless until the merge path re-points them -- they simply come back. Note this also
      means "edges whose endpoint device is soft-deleted" is NOT a safe purge predicate; it
      must exclude `deleted_reason = 'merged'`.

- [ ] 3.6 **CORRECTED 2026-08-28 -- the original claim here was wrong.** This task first
      said "topology evidence has no expiry or deletion path at all". That is FALSE.
      `prune_stale_mapper_evidence_links_query/1` (queries/edge_links.ex) deletes every
      evidence type -- `CONNECTS_TO`, `LOGICAL_PEER`, `HOSTED_ON`, `INFERRED_TO`,
      `ATTACHED_TO`, `OBSERVED_TO` -- older than the stale cutoff. It is enabled by default
      (`mapper_topology_prune_stale_projected_links_enabled` defaults true, pruning.ex:117)
      and is invoked from `do_upsert_links/1` (links.ex:67) on every mapper link upsert.
      There are two more pruners beside it: a device-scoped `prune_stale_projected_links/1`
      and an `unseen` pruner.
      The claim came from a line-scoped grep: the query's `DELETE r` sits four lines below
      the `type(r) IN [...]` list, so searching for delete keywords on the same line as a
      label name found nothing. The demo behaviour that prompted it -- ghosts persisting,
      and a manual canonical delete being undone by the next rebuild -- is fully explained
      by the 7-day stale window, exactly like the canonical prune in 3.1. Neither mechanism
      was broken; neither had anything eligible yet.
      **What was actually real, and is fixed in `fix/topology-evidence-timestamp-symmetry`:**
      the upsert and the evidence prune disagreed about a missing timestamp. The upsert
      admitted `r.last_observed_at IS NULL` unconditionally
      (queries/canonical_rebuild.ex:180) while both evidence pruners required
      `IS NOT NULL`. An evidence edge with no `last_observed_at` was therefore projected on
      every rebuild and could never be pruned -- and because the upsert emits
      `coalesce(r.last_observed_at, r.observed_at)`, the canonical edge it produced WAS
      prunable, giving an hourly delete/recreate loop that also inflates the candidate count
      feeding the mass-deletion guard. Both sides now use that same coalesce, and the
      evidence prune deletes edges carrying no usable timestamp at all. No current writer
      emits a null (every `SET r.last_observed_at` is unconditional), so this was latent
      rather than active -- it is hardening, not an outage fix.

## 4. Causal horizon labelling

- [ ] 4.1 Report "not reached within N hops" instead of "not causally linked" when a node
      lies beyond the cascade horizon (`causality.rs`, bare literal `3` in two places).
- [ ] 4.2 Distinguish genuinely disconnected from beyond-horizon; the BFS truncates at 3 so
      both currently collapse to `usize::MAX`.
- [ ] 4.3 Share one constant. `rust/correlation-engine/src/god_view.rs` has
      `MAX_AFFECTED_HOPS` and a comment saying it "mirrors the NIF's BFS" -- hand-mirrored
      constants drift.
- [ ] 4.4 Decide the hop budget deliberately: a cluster member is already 2 hops from its
      own gateway, so 3 is tight for a multi-subnet estate.

## 5. Tracked, needs its own design (NOT specified in this change)

- [ ] 5.1 **Hypervisor guests are drawn as network peers.** `MikroTik` (192.168.6.167,
      sources `mapper,proxmox,sweep`) is a Proxmox guest -- there is a hosted link
      `192.168.2.254 -> mikrotik-routeros-chr` -- yet the overview draws it adjacent to
      `aruba-24g-02` because the VM speaks LLDP. The overview ignores the `hosted` plane
      entirely, so the real path (guest -> PVE host -> switch) collapses into a false
      adjacency. 61 hosted-only nodes are dropped outright.
      The exclusion is deliberate: the bounded-fanout fixture names a `virtual-guest` node
      among what must not be admitted. Changing it is a design decision, not a patch.
- [ ] 5.2 **Guest identity is split**, so hypervisor rendering would not connect anyway:
      `mikrotik-routeros-chr` (source `awx`, no IP) and `MikroTik` (192.168.6.167). The
      hosted edge names the first; the surface draws the second.

## 6. Housekeeping (no spec delta required)

- [ ] 6.1 `req 0.7.3` is unsatisfiable on Hex, so `serviceradar_core_elx` deps will not
      resolve and the `mix format` pre-commit hook fails repo-wide. CI is unaffected (it
      resolves fresh). Bump deliberately rather than leaving everyone on `--no-verify`.
- [ ] 6.2 `//elixir/web-ng:static_files` is still a bare `glob(["priv/static/**"])`. A local
      asset build collides with `//elixir/web-ng/assets:static_undigested` and breaks
      `make push_all`, not just `make test`. Add the `exclude` for the gitignored
      `priv/static/assets/**` and `priv/static/cache_manifest.json`.

## 7. Operational follow-ups (demo, not code)

- [ ] 7.1 Run the one-time prune override after the estate split, then unset:
      `SERVICERADAR_TOPOLOGY_LINK_RETENTION_DAYS=2`,
      `SERVICERADAR_TOPOLOGY_CANONICAL_PRUNE_GUARD_OVERRIDE=true`. Expect canonical
      190 -> ~33 edges (23 attachment + 10 backbone rows survive the split).
- [ ] 7.2 Re-check that the 109 soft-deleted 192.168.1.x devices stay deleted after a sweep
      cycle; query `platform.device_revival_audit` for any that return.
- [ ] 7.3 Decide whether to reconnect the armis sync source so the faker repopulates demo.
      Nothing polls it today -- the only armis reference in `serviceradar-config` is the
      faker's own server config, and armis devices froze at 2026-06-26.
- [ ] 7.4 Fix faker identity churn before 7.3: 1,000 simulated devices produced 49,829
      records (49,764 distinct IPs) because each `ip_shuffle` minted a new device instead of
      updating one. Reconnecting without this restarts the pile.
