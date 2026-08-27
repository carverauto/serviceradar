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

- **Topology link retention works.** Zero canonical edges are older than 30 days. It
  aged out the removed UniFi topology exactly as designed.
- **The mass-deletion guard works, and blocks silently.** It refuses a pass deleting
  more than 50% of canonical edges. After the cutover that figure is **82.6%**, so the
  guard will refuse forever -- the stale fraction never shrinks on its own. Nothing is
  logged, because nothing logs until an edge is prune-eligible. An operator sees a
  network they no longer poll and no indication why.

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
- ~~**Guard observability.**~~ WITHDRAWN: already implemented -- see tasks.md 3.1.
  that unblocks it. A guardrail that fails closed and silently is indistinguishable from
  a mechanism that was never built.
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
