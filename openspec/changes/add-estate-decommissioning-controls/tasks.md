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

- [ ] 3.1 Log a refused canonical prune with counts, fraction and the override that permits
      it. Today nothing logs until an edge is prune-eligible, so a blocked guard is
      invisible.
- [ ] 3.2 Fix `raw_evidence_class/1` precedence, or rename its counters. It resolves
      explicit evidence before `relation_type`, the inverse of `evidence_class/1`, so
      `raw_attachment: 0` was reported against 334 real `ATTACHED_TO` links. That single
      counter is what sent the 2026-08-27 investigation looking for missing data.
- [ ] 3.3 Stop deriving `pair_*` and `final_*` from the same list.
      `prepare_runtime_edge_pipeline/2` sets `pair_edges: final_edges`, so the two families
      can never disagree and cannot localise a loss.

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
