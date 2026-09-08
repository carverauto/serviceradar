# Change: Stop add-on rollouts wedging, and stop the fleet view showing dead work

## Why

The demo fleet has 11 paused add-on rollouts. Four of them have been paused for
19 days, two for 7 days, and the newest three for hours. Nothing is retrying
them and nothing will: every one is waiting on a condition that cannot clear on
its own. Measured against the live fleet, they fall into two groups, and the
distinction matters because the fixes are unrelated.

**Group 1 — already satisfied, still displayed as work.** Four rollouts name a
candidate version the fleet has already reached:

| rollout | paused | agents at target |
| --- | --- | --- |
| `bumblebee 0.1.1 -> 0.1.2` (assignment + profile) | 19 days | 10 of 15 |
| `workload-identity 0.1.4 -> 0.1.5` (profile) | 19 days | 9 of 15, and 4 are already past it on 0.1.7 |
| `powerdns 0.1.1 -> 0.1.3` (assignment, x2) | 19 days | all 3 relevant agents |

These are finished in every sense except the record. A rollout is not reaped
when the fleet converges by another path -- a later rollout, a direct
assignment, a reinstall -- so it stays `paused` forever and keeps rendering
Resume / Roll back / Cancel as though an operator still has a decision to make.

**Group 2 — genuinely blocked, by a health gate that is asking the wrong
question.** The gate treats "the add-on told us something is not ideal" as "the
candidate is broken", and two very different conditions get caught by it:

- `powerdns` on ns01-ns03 reports `no PowerDNS Recursor protobuf producer
  connected to 127.0.0.1:6000 for 60s`. The add-on is running correctly. It has
  no upstream feeding it, which is a property of the environment, not of the
  candidate build. Because the gate cannot tell those apart, **every powerdns
  rollout pauses forever** -- which is exactly what the three identical
  `0.1.3 -> 0.1.4` pauses are.
- `anomaly` on ns01-ns05 reports `resource limits not enforced: ... need
  cpu,memory,pids, available memory,pids`. The process state is `running`; a
  host has not delegated the `cpu` cgroup controller. That is a real problem
  worth surfacing, but it is a property of the host, and it is identical before
  and after the upgrade. It has held anomaly three versions behind (fleet on
  0.3.0, 0.3.3 approved) for 7 days.

Two agent-local faults are genuinely candidate-relevant and should keep
blocking: `bumblebee` on sr-test-pve04 (`systemd unit failed`) and `netprobe`
on ns01 (`dial netprobe socket: connection refused`).

Underneath both groups is the same reporting problem: a paused row says
`candidate reported unhealthy` and stops there. It never names the agent or the
reason, even though the exact string is already stored in
`addon_statuses.degradation_reason`. An operator cannot act on the row, so the
rows accumulate.

Finally, one logical update renders as many rows -- once per `assignment` and
once per `profile`. `powerdns 0.1.3 -> 0.1.4` is three identical assignment
rows; `workload-identity` appears about eight times across two versions. The
view is mostly duplicates and tombstones, which is why real problems are
invisible in it.

## What Changes

- **Terminate superseded rollouts.** A rollout whose candidate version is
  already the observed version on every in-scope target resolves as superseded
  rather than remaining paused. Reaping is derived from observed fleet state, so
  it also covers convergence that happened outside the rollout.
- **Split the health gate into candidate faults and environment faults.** A
  fault that is attributable to the candidate build (process not running, unit
  failed, crash loop, IPC unreachable) continues to block. A fault that is a
  property of the host or of absent upstream input does not block a rollout, is
  still surfaced on the fleet row, and is recorded on the rollout as an
  advisory. The classification is a property of the reported status, not a
  per-add-on allowlist.
- **Require a blocked rollout to name its evidence.** Pausing records the agent,
  the add-on-reported reason, and the evidence age, and the UI shows them on the
  row.
- **Collapse the rollout list to one row per logical update**, with per-scope
  detail available on expansion, and keep terminal rollouts out of the active
  list.
- **Make add-on version reporting truthful.** `otel-collector` reports `0.0.0`
  on all 13 agents while 0.1.3 is approved, so it can never be evaluated for an
  update. An add-on that cannot report its version is shown as unknown rather
  than as a version that sorts below everything.

Not in scope: the host-side remediation itself (delegating the `cpu` controller
on ns01-ns05, repairing the bumblebee unit on sr-test-pve04, restarting
netprobe on ns01). Those are operational actions, tracked separately. This
change is about the platform no longer wedging when they happen.

## Impact

- Affected specs: `agent-config` (rollout lifecycle and health gating),
  `agent-registry` (fleet evidence), `plugin-configuration-ui` (the fleet view).
- Affected code: add-on rollout evaluation and reconciliation in
  `serviceradar_core`, the add-on fleet LiveView in `web-ng`, and add-on status
  reporting for version truthfulness.
- Relationship to pending work: `add-native-addon-fleet-rollouts` (33/43) builds
  this feature and is not archived, so its requirements are not in `specs/`
  yet. This change adds complementary requirements rather than modifying that
  change's deltas; its task 6.6 (stable reason text on non-healthy rows)
  overlaps with the evidence work here and should be satisfied by it.
- Migration: existing paused-but-superseded rollouts are resolved by the
  reaper on first run. No operator action required.
