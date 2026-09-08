# Change: Let an agent's own report anchor its device identity

## Why

An agent knows two things about itself with more authority than anything else in the
system: its `agent_id`, which is stable across address changes, and its live address,
which `getSourceIP()` already re-detects when the onboard-time `host_ip` pin goes stale.
Neither fact currently anchors an inventory device, so a re-IP'd host becomes a second
device instead of an update.

Measured on farm01 for `alma-test01` (192.168.2.243 -> 192.168.1.171), from CNPG:

| when | event |
| --- | --- |
| Aug 12 16:49 | device A created @ `.2.243`, writer `mapper_topology_sighting` |
| Aug 14 00:28 | `agent_id=agent-alma-test01` identifier first seen, confidence `strong` |
| Aug 14 21:02 | device B created @ `.1.171`, **also** `mapper_topology_sighting` |
| Aug 14 - 20 | A keeps updating (last seen Aug 20 21:55) -- the stale IP an operator sees |
| Aug 22 19:30 | `merge_audit`: A -> B, `identity_reconciler`, `scheduled_reconciliation`; A soft-deleted |

**The reconciler is not broken and this is not a missing merge.** `Identity.DuplicateSweep`
merges only devices that SHARE a strong identifier, and states outright that bare-IP overlap
is not merge evidence. Device B carried no identifier for eight days, so there was nothing to
match on. The sweep runs every five minutes
(`ng_job_schedules.device_identity_reconciliation`, cron `*/5 * * * *`, enabled since Aug 11):
it declined roughly 2,300 times, correctly, and merged within minutes of the two rows finally
sharing `agent_id`. Shortening its interval would change nothing.

The gap is upstream. Devices for agent hosts are minted by *observer* sources -- mapper, sweep,
census -- and `SourcePolicy.observer_agent_source?/1` deliberately demotes an observer's
`agent_id` so it cannot identify the host it describes. That rule is correct and must stay:
without it every host a mapper sees collapses onto the mapper, which is a reproduced failure.
The consequence is that no source is left that may say "this device IS agent X."

Scale, on farm01: **2** devices carry an `agent_id` identifier and **1** distinct `agent_id`
appears in any device metadata, against 127 live devices whose creators are
`netprobe_census` (64), `mapper_topology_sighting` (53), `proxmox_unauthenticated_https_8006` (4),
`netprobe_mdns` (3) and `sweep_ip_seed` (1). There is no self-report source at all. This is the
general case, not one unlucky host.

It also invalidates a documented assumption. `inventory/discovery/decoders/process.ex` justifies
registering the process schema `:enrichment_only` on the grounds that "the agent host always
already has a device -- sysmon and the agent's own self-report create it." On farm01 neither
source has created one.

## What Changes

- **ADD a first-party `agent-self-report` device source.** The agent's periodic status already
  carries `agent_id` and a re-detected `SourceIp`; that pair becomes an inventory device update
  describing the agent's own host and nothing else.
- **`agent_id` anchors the agent's own device.** The self-report source is NOT an observer, so
  `SourcePolicy.include_agent_identifier?/2` admits its `agent_id` as a strong identifier and
  registers it. A re-IP then resolves by `agent_id` to the existing device and becomes an
  UPDATE of `ip`.
- **The self-report MAY create.** It is first-party evidence a host gives about itself, so unlike
  the enrichment-only sources it may bring its own device into existence when nothing resolves.
  It may create ONLY its own host row.
- **State the `agent_id` rotation policy.** Re-onboarding a host under a new `agent_id` is a new
  anchor; the change specifies what happens rather than leaving it to the duplicate sweep.
- Not BREAKING: additive source plus identifier registration. Existing observer demotion,
  mapper/sweep/census over-merge protection, and the duplicate sweep are unchanged.

## Impact

- **Affected specs:** `device-identity-reconciliation` (ADDED + MODIFIED).
- **Affected code:** `elixir/serviceradar_core/lib/serviceradar/inventory/sync/source_policy.ex`
  (classify the new source; leave `observer_agent_source?/1` semantics intact),
  `inventory/identity/ids.ex` (identifier eligibility), the agent-status ingest path in
  `serviceradar_core` that turns a `PushStatus`/Hello into an inventory update, and
  `go/pkg/agent` only if the self-report needs a field it does not already send.
- **Coordinate with:** `add-device-identity-fence` (identity boundaries; no overlap on
  `agent_id` anchoring today). Composes with the netprobe discovery work in
  `refactor-netprobe-onto-generic-addon-contract`, whose `process.v1` decoder documents the
  assumption this change makes true.
- **Risk:** the same over-merge this protects against. If an `agent-self-report` payload ever
  describes a host OTHER than the reporting agent, every such host collapses onto the agent's
  device. `design.md` sets that boundary and the tasks make it a tested invariant rather than a
  convention.
