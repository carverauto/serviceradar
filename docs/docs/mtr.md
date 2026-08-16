---
title: MTR Path Monitoring
---

# MTR Path Monitoring

ServiceRadar uses MTR (My Traceroute) to capture hop-by-hop latency and
packet loss. The dashboard Latency and Packet Loss tiles read from stored
traces. If those tiles say **No MTR**, no traces exist in the current
window. That is almost always a setup or targeting problem, not a broken
chart.

There are three ways traces get into the system:

| Path | Where you use it | How it runs |
| --- | --- | --- |
| Interactive | **Diagnostics → MTR** | An operator starts a trace against a connected agent |
| Scheduled check | Agent check set (`mtr`) | The gateway sends a recurring check; see [Agent Configuration](./agent-configuration.md#mtr-my-traceroute-checks) |
| Automated policy | **Settings → Networks → MTR** | Core's baseline scheduler dispatches `mtr.run` / `mtr.bulk_run` to a preferred agent |

Dashboard Observability Metrics use the automated / stored traces
(`platform.mtr_traces` and `platform.mtr_hops`). A one-off diagnostic
trace also counts once it has been ingested.

## What you need

1. At least one **connected agent** that can send ICMP/UDP/TCP probes
   toward the targets (a host agent on the LAN, or an in-cluster agent
   that can reach those destinations).
2. **Automation workers enabled on core-elx** if you want scheduled
   baselines. Helm defaults these **off**.
3. An **enabled MTR policy** with targets and a preferred agent that is
   actually online.

Interactive traces only need step 1. Dashboard tiles need traces in the
selected time window, which automated baseline is meant to keep filled.

## Enable automated baseline (Helm)

Chart values live under `core.mtrAutomation`. The shipped defaults do
not start any MTR workers:

```yaml
core:
  mtrAutomation:
    enabled: false
    baselineEnabled: false
    triggerEnabled: false
    consensusEnabled: false
    baselineTickMs: 60000
    consensusCohortRetentionMs: 300000
```

Turn on baseline only first. Restart / roll `serviceradar-core` after
the change so the supervision tree picks up `MtrBaselineScheduler`.

```yaml
core:
  mtrAutomation:
    enabled: true
    baselineEnabled: true
    triggerEnabled: false
    consensusEnabled: false
```

Equivalent environment variables on core-elx:

- `MTR_AUTOMATION_ENABLED`
- `MTR_AUTOMATION_BASELINE_ENABLED`
- `MTR_AUTOMATION_TRIGGER_ENABLED`
- `MTR_AUTOMATION_CONSENSUS_ENABLED`

Each `MTR_AUTOMATION_*_ENABLED` flag defaults to the global value when
unset. Helm templates the four flags independently, so set both
`enabled` and `baselineEnabled` to `true` for scheduled captures.

Staged rollout and rollback switches are in
[Troubleshooting → MTR Automation](./troubleshooting-guide.md#mtr-automation).

Docker Compose defaults baseline **on**. For a fresh Compose database,
`MTR_RETENTION_DAYS` (1-395, default 30) seeds retention; change it later
under **Settings → Networks → MTR**. See [Docker Compose](./docker-setup.md#mtr-history-retention).

## Create or fix a policy

**Where:** **Settings → Networks → MTR** (`/settings/networks/mtr`)

1. Create a policy (or edit the existing one). Give it a name and leave
   it **enabled**.
2. Set **preferred agent** to a connected agent id. The form stores this
   as `target_selector.agent_id`. Bulk baseline **requires** this field.
   Auto-select only works when at least one candidate is on the control
   stream; if the preferred agent is offline, dispatch returns
   `preferred_agent_unavailable` and nothing runs.
3. Set protocol (`icmp`, `udp`, or `tcp`) and baseline interval
   (minimum 30 seconds; 300 seconds is the usual start).
4. Add the destinations you want baselined (managed devices or explicit
   targets, depending on policy scope).

The scheduler ticks about once a minute (`baselineTickMs`). It honors
the policy interval as a cooldown, so the first traces should appear
within one interval after the workers are up and the agent is
connected.

Confirm the agent received work:

```bash
journalctl -u serviceradar-agent --since "10 min ago" | grep -E "mtr\\.(run|bulk_run)|Received control command"
```

A healthy host agent logs `command_type":"mtr.bulk_run"` (or `mtr.run`)
and later writes hop results back through the gateway.

## Verify traces landed

1. **Diagnostics → MTR** should list recent outcomes.
2. Dashboard Latency / Packet Loss should leave **No MTR** once
   `mtr_traces` has rows in the dashboard time window.
3. SRQL:

```text
in:mtr_traces time:last_24h sort:timestamp:desc
```

Empty results after a dispatch usually mean the agent never ran the
command, or results failed to ingest. Check agent logs first, then
core-elx for `MTR baseline` dispatch summaries
(`dispatched`, `cooldown`, `no_candidates`, `preferred_agent_unavailable`).

## Why the dashboard said No MTR

The tiles are empty when `path_count` is 0. On a Helm install that
almost always means one of:

| Cause | What you see | Fix |
| --- | --- | --- |
| Automation workers off | No `MtrBaselineScheduler` in core, no periodic dispatch | Set `core.mtrAutomation.enabled` and `baselineEnabled` to `true`, roll core |
| Policy prefers a dead agent | Dispatch `no_candidates` / `preferred_agent_unavailable` | Point **preferred agent** at a connected agent (Settings → Cluster shows live agents) |
| Agent cannot reach targets | Commands received, hops empty or failed | ICMP/UDP/TCP from that agent to the destinations; try **Diagnostics → MTR** by hand |
| Agent offline | No `Received control command` | Fix enrollment / host IP / control stream first |

Pinning a policy at a host that moved IPs (stale `host_ip`) looks like
an MTR outage even when another agent is healthy. Retarget the policy
or fix the agent's advertised address, then wait one baseline interval.

Incident / recovery capture (`triggerEnabled`) and cohort consensus
(`consensusEnabled`) are optional. They do not fill the dashboard tiles
by themselves; baseline (or interactive traces) does.

## Related pages

- [Agent Configuration](./agent-configuration.md#mtr-my-traceroute-checks) — per-check probe limits
- [Navigating the Web UI](./web-ui-overview.md#diagnostics) — Diagnostics → MTR
- [Helm Configuration](./helm-configuration.md#mtr-automation) — chart values
- [Troubleshooting](./troubleshooting-guide.md#mtr-automation) — flag matrix and rollback
