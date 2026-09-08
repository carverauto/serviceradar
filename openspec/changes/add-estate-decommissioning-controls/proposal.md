# Change: Give operators a way to decommission what has left the estate

## Why

ServiceRadar can enrol an agent, discover a device and draw a topology. It cannot
*undo* any of those. On 2026-08-26 the `demo` estate was split in half -- the
192.168.1.x and 192.168.2.x networks moved to a separate cluster and their SNMP
community was rotated -- and every removal an operator tried to perform either did
nothing or had no interface at all.

Measured on `demo` during that cutover:

| what the operator wanted | what actually exists |
| --- | --- |
| remove agent `agent-dusk01` | no destroy action on the Agent resource; the detail page has **zero** `handle_event` |
| stop it reconnecting | `revoke_agent_certificate/3` exists, reachable **only** as an admin API |
| delete its onboarding package | succeeded, and changed nothing -- the package was already `delivered` |
| drop 109 departed devices | soft-delete worked, but nothing expires a device that merely stops being seen |
| drop the topology drawn from them | 147 of 190 canonical edges now reference deleted devices |

The agent detail page still reported `Connected -- Live Agent, connected via gateway
registry`, acking config 22 seconds after its onboarding package was deleted.

Two mechanisms exist and are correct; both are unreachable or silent:

- **Canonical edge ageing works.** Verified on `demo` 2026-08-27: the rebuild runs hourly,
  the guard allows the prune, and it correctly deletes nothing --
  `starved: false, prune_result: :ok, before_edges: 228, after_prune_edges: 228`. The
  cutoff is `2026-08-20` and the oldest canonical edge is `2026-08-21`, because
  `SERVICERADAR_MAPPER_TOPOLOGY_EDGE_STALE_MINUTES` is `10080` (7 days) at
  `values-demo.yaml:662`. Note this is NOT `SERVICERADAR_TOPOLOGY_LINK_RETENTION_DAYS`,
  which feeds `data_retention_worker.ex` for the relational links table and has no effect
  on the canonical AGE prune.
- **The mass-deletion guard reports refusals properly.** `report_prune_refusal/5`
  (canonical_rebuild.ex:397) emits `prune_refused` telemetry and a `Logger.error` naming
  the candidate count, the total, the fraction and the override. It has not appeared on
  `demo` only because nothing has been prune-eligible yet.
- **But the guard cannot be overridden in the deployed release.** The reader is
  `Application.get_env(:serviceradar_core, ServiceRadar.NetworkDiscovery.TopologyGraph)`,
  and that block is defined ONLY in `elixir/serviceradar_core/config/runtime.exs:1256`.
  The deployed app is `serviceradar_core_elx`, and a release evaluates only its own
  `runtime.exs` -- which has no `TopologyGraph` block. Confirmed by live RPC against the
  running node: the block returns `nil`, while a key core_elx does define
  (`mapper_topology_edge_stale_minutes`) correctly returns `10080`. So
  `canonical_prune_max_fraction` and `canonical_prune_guard_override` sit at their
  compiled defaults (0.5 / false) and no env var can change them. This is imminent, not
  theoretical: 174 of 228 canonical edges (76.3%) are ghosts of the departed estate and
  cross the 7-day cutoff around 2026-08-28, at which point the guard refuses correctly
  and the documented escape hatch does not exist.

There is also a class of stale data with no expiry at all: **49,932 of ~50,220 devices
have not been seen in over 30 days and are still live records.** `DeviceCleanupWorker`
purges devices that are *already* soft-deleted; nothing ever soft-deletes a device that
simply stopped reporting.

## What Changes

- **Agent decommissioning.** A first-class action that revokes an agent's mTLS identity
  so it cannot reconnect, and retires its registry row, reachable from the agent detail
  page rather than only by hand-crafted admin API call.
- **Device expiry.** A device unseen for a retention window is soft-deleted by the same
  mechanism topology links already use, instead of living forever.
- ~~**Guard observability.**~~ WITHDRAWN: already implemented, and correctly. See
  tasks.md 3.1.
- **The guard's config is wired into the release that actually runs.** A guardrail whose
  documented override is unreachable in production is indistinguishable from one with no
  override at all. See tasks.md 3.4.
- **Honest pipeline stats.** `raw_attachment` reports what the pipeline *decided*, not
  what the producer *claimed*; `pair_*` and `final_*` stop being computed from the same
  list, so a loss between stages can actually be localised.
- **Horizon-limited causal verdicts are labelled as such**, rather than asserting a
  causal conclusion the analysis never reached.

## Impact

- Affected specs: `agent-registry`, `device-inventory`, `topology-god-view`,
  `topology-causal-overlays`
- Affected code: `ServiceRadar.Infrastructure.Agent`, `GatewayCertificateIssuer`,
  `AgentLive.Show`, `DeviceCleanupWorker`, `TopologyStateCleanup`, `GodViewStream`
  pipeline stats, `god_view_nif` causality
- Operator-visible: device counts will drop sharply on first expiry run. The expiry
  window must be introduced deliberately, defaulting to disabled, or a first pass would
  soft-delete ~49,932 rows at once.
