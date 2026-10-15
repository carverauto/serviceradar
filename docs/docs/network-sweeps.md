---
sidebar_position: 14
title: Network Sweeps
---

# Network Sweeps

Network sweeps let you define scheduled scans against device inventories and
explicit IP targets. Sweeps are configured in the Web UI under Settings > Networks.

Sweeps are active scans. They are not [Visibility Profiles](./visibility-profiles.md),
which configure passive host-side fingerprinting, DPI, and flow attribution on
enrolled agents.

## Sweep Groups

Sweep groups are the primary unit of configuration. Each group includes:

- **Name and description**: Human-friendly identifiers.
- **Schedule**: Interval (e.g., `15m`, `1h`) or cron expression.
- **Targets**:
  - **Target criteria** (matches devices from inventory)
  - **Static targets** (CIDR, IP, or IP range strings)
- **Scanner profile** (optional): Base ports/modes/timeouts.
- **Overrides**: Group-specific settings that override the profile.
- **Partition / agent assignment**: Choose the target-device partition and
  which agents receive the sweep.
- **Enabled toggle**: Disable a group without deleting it.

### Deleting a Group

Use the group's delete button in Settings > Networks and review the confirmation.
It names the recorded execution count, or states that there are no recorded
executions. Confirming removes the group, its executions, and their per-host
results. Long-term coverage rollups are kept. Disable the group instead if you
want to stop scheduled scans while keeping its execution history subject to
normal retention.

If deletion is refused, the UI identifies authorization failures or a group
that no longer exists. For other failures, it directs you to the server log;
ask an administrator to inspect the corresponding sweep-group deletion error.

### Agent Assignment

Sweep groups support two assignment modes:

- **All eligible agents in this partition** sends the group to every eligible
  agent in the group's target-device partition. This is stored as an empty
  `agent_ids` list.
- **Selected agents** sends the group only to the fixed, non-empty set of agent
  UIDs chosen by the operator. A selected agent may have a control session in a
  different partition from the target devices; this supports isolation and
  cross-partition scanning without changing the group's device partition.

The selected-agent picker searches by name or UID and loads at most 50 rows at
a time with server-side pagination. Online status, control-session partition,
and reported sweep capability are advisory context in the picker. They do not
silently remove an existing assignment. If a previously selected UID no longer
resolves, the picker retains and displays the raw UID as unavailable so an
operator can remove it deliberately.

Scheduled delivery uses the stored UID assignment. **Run now** additionally
requires a unique live, sweep-capable control session for each selected agent.
Reachable agents still receive their commands when other selected agents are
offline or fail dispatch; the result reports successful command IDs and each
per-agent failure as a partial outcome. It never falls back to the group's
device partition for an unresolved selected agent.

### Last Run and Missed Sweeps

`last_run_at` is a group-level timestamp for the latest execution report
received from any eligible agent in All mode or any selected agent in Selected
mode. One member's report can therefore keep the group-level missed-sweep check
current. It does not prove that every assigned member ran or reported; inspect
the per-agent execution history to determine member coverage.

Missed-sweep diagnostics include the canonical `agent_ids` array. An empty
array means All mode; a non-empty array is the exact selected subset.

### Rolling Upgrade Compatibility

The assignment migration is additive and runs before array-aware application
pods start during a normal hooked Helm upgrade. Multi-agent selection is
enabled immediately after the upgrade; there is no manual cutover or feature
flag. During the typical 10-30 second rolling overlap, an old pod sees All as
the legacy nil scalar or a multi-agent subset as its first selected UID. This
is deliberately fail-narrow: an old pod may temporarily deliver to one member
of the subset, but it cannot broaden the job to unselected agents.

The legacy scalar column, synchronization trigger, and partial index remain in
place for rollback compatibility. They are removed only in a later deprecation
release after no supported current or rollback binary depends on them. If Helm
migration hooks are disabled, apply the migration externally before rolling
the application pods.

## Scanner Profiles

Profiles define reusable scan settings:

- **Ports**: List of TCP ports to scan.
- **Sweep modes**: One or more of the three supported modes (see below).
- **Concurrency**: Parallel scan worker count.
- **Timeout**: Per-target scan timeout.
- **Scan timeout**: Total wall-clock limit for a single sweep execution (e.g.
  `10m`, `1h`). When a sweep reaches this limit it is marked `cancelled` rather
  than `completed`. Unset means no clamp beyond the default 20-minute fallback
  built into the agent.

Groups can either reference a profile or define settings inline.

### Sweep Modes

The agent runs these sweep modes:

- **`tcp`**: SYN scanning. Fast, but raw SYN packets break upstream connection
  tracking. Tune rate limits and apply conntrack mitigation before scaling it up
  — see [SYN Scanner Tuning and Conntrack Mitigation](./syn-scanner-tuning.md).
- **`tcp_connect`**: Full TCP connect scanning. Slower than SYN, but completes
  the handshake so it is conntrack-safe and works without raw-socket privileges.
- **`icmp`**: ICMP echo (ping) sweeps for host reachability. The sweep scanner
  needs raw ICMP sockets (`CAP_NET_RAW` or root).

An agent probes its ICMP sockets once at startup. If it cannot open raw ICMP
sockets it reports `icmp.unavailable`, and core leaves the `icmp` mode out of
that agent's compiled sweep config. If it cannot open any ICMP socket for
traceroute it reports `mtr.unavailable`, and core leaves the `mtr` sweep mode
out. A group that has no modes left is not sent to that agent. An agent that
reports neither marker still receives every mode. The agent detail page
explains each marker.

## Target Criteria Syntax

Target criteria is a DSL that matches device fields. Criteria are expressed as a map
of `field -> operator`.

Supported operators include:

- `eq`, `neq`
- `in`, `not_in`
- `contains`, `not_contains`
- `starts_with`, `ends_with`
- `in_cidr`, `not_in_cidr`
- `in_range` (IPv4 ranges like `10.0.0.1-10.0.0.50`)
- `has_any`, `has_all` (tag operators)
- `gt`, `gte`, `lt`, `lte`
- `is_null`, `is_not_null`

### Examples

Match devices by tags:

```json
{
  "tags": {"has_any": ["critical", "env=prod"]}
}
```

Match devices by IP range:

```json
{
  "ip": {"in_cidr": "10.0.0.0/8"}
}
```

Match devices by discovery source and hostname prefix:

```json
{
  "discovery_sources": {"contains": "sweep"},
  "hostname": {"starts_with": "edge-"}
}
```

Combine criteria (all conditions must match):

```json
{
  "tags": {"has_all": ["env=prod", "tier=edge"]},
  "ip": {"in_range": "10.0.1.1-10.0.1.50"}
}
```

### Static Targets

Static targets are always included in the sweep, regardless of criteria matches:

```json
["10.0.0.0/24", "192.168.1.10", "10.0.2.1-10.0.2.25"]
```

## Running Scans Panel

The Running Scans panel in Settings > Networks shows every sweep execution that
is currently in progress. Each card displays the group name, elapsed time, host
counts, and a **Cancel** button for operators with the `networks.sweeps.run`
permission (the same permission that gates **Run now**).

### Cancelling a Running Scan

Clicking **Cancel** shows a confirmation prompt. Confirming does two things, in
this order:

1. Closes the execution record with a failed status. The error message records
   who cancelled it (`cancelled by <login email>`), matching the format used in
   the audit history. The update is filtered on `status == running`, so a scan
   that completed between the click and the write keeps its completed state; the
   panel reports it is no longer running.
2. Sends `sweep.cancel_group` to that execution's own agent to stop any in-flight
   scan. Agents advertise the `sweep_cancel` capability when they support this
   command. An agent that does not, or that is offline, is not sent the command;
   the run stays closed and the flash message explains why the agent was not
   stopped.

The run is always closed first. Results the agent sends before it receives the
stop command do not reopen a closed execution.

### What "running" means

Core creates an execution when the first result chunk of a completed agent sweep
arrives, and closes it on the final chunk. A stuck running execution is usually
caused by lost chunk delivery, not an agent still scanning. The cancel command
stops whatever scan of that group the agent has in flight; if none is running,
the agent reports that nothing was cancelled. Scheduled sweeps continue at their
normal interval.

## Execution Notes

- Target criteria are evaluated when configs are compiled.
- Sweep results update device availability and discovery metadata.
- Large result sets are chunked by the agent and streamed to the gateway.
