---
title: Network Performance Testing
---

# Network Performance Testing (netperf / rperf)

ServiceRadar actively measures network throughput, jitter, and packet loss
between agents using embedded **netperf** inside `serviceradar-agent`. Unlike
passive monitoring (which observes existing traffic), netperf generates
synthetic TCP or UDP traffic and measures how the network handles it.

For each test, netperf reports:

- **Availability and duration** - test success indicator (`rperf.available`)
  and measured duration in seconds (`rperf.duration_seconds`).
- **Throughput** - bits per second (`rperf.bits_per_second`) achieved for TCP
  or UDP traffic.
- **Jitter** - variation in packet delay (`rperf.jitter_ms`), in milliseconds
  (UDP).
- **Packet loss** - packets sent, received, and lost (`rperf.packets_sent`,
  `rperf.packets_received`, `rperf.packets_lost`) and loss percentage
  (`rperf.loss_percent`) (UDP).
- **Bytes transferred** - total bytes sent and received (`rperf.bytes_sent`,
  `rperf.bytes_received`) over the test duration.

Agents running with Hub Responder enabled also emit responder session gauges:
`rperf.responder_active_sessions`, `rperf.responder_sessions_total`,
`rperf.responder_busy_rejections_total`, and `rperf.responder_bytes_total`.

## Architecture

Active network performance testing is embedded directly into
`serviceradar-agent` (`go/pkg/netperf`). The legacy standalone `serviceradar-rperf`
server and `serviceradar-rperf-checker` gRPC pod (`:50081`) have been retired.

| Role | Binary | Transport / Ports | Auth / Authorization |
|---|---|---|---|
| **Spoke Sender** | `serviceradar-agent` | Outbound TCP `5199` (control) + UDP `5199` (optional UDP data) | mTLS + Ed25519 `NetperfPermitV1` + HMAC-SHA256 |
| **Hub Responder** (opt-in) | `serviceradar-agent` | Inbound TCP `5199` (mTLS) + single UDP socket `5199` | mTLS (`RequireAndVerifyClientCert`) + `NetperfPermitV1` verification |

Key architectural properties:

1. **No dynamic port pools** - TCP data streams ride over the mTLS-authenticated
   `5199/TCP` gRPC stream (`netperf.v1.NetworkPerfPeerService`), and UDP tests
   multiplex over the single `5199/UDP` socket using HMAC-SHA256 authenticated
   `session_id` headers. Ports `5200-5210` are no longer required.
2. **Zero gateway synthetic payload load** - Spoke agents talk directly to Hub
   Responders over `5199`, never routing synthetic test traffic through
   `agent-gateway`.
3. **Permit-authorized execution** - Control-plane `NetperfCompiler` compiles
   policies (`:hub_and_spoke` or `:hub_mesh`) into `AgentConfigResponse` and
   mints Ed25519-signed `NetperfPermitV1` tokens verified against the
   agent's `RecordTrust` keyset.
4. **Durable delivery** - Completed test summaries commit directly to the
   agent's `RecordSpool` under `serviceradar.metrics.batch` (`source =
   "rperf-metrics"`, `metric_type = "rperf"`), then flow through
   `EdgeRecordIngestService` -> NATS JetStream (`metrics.rperf.>`) ->
   `EventWriter` -> CNPG/StarRocks.

## Configuring Policies, Responders, and Profiles

Manage active network performance testing in the web UI at
**Settings -> Networks -> Netperf** (`/settings/networks/netperf`):

- **Profiles** - Define protocol (`tcp` or `udp`), direction (`upload`,
  `download`, or `bidirectional`), duration, parallel streams, omit warm-up
  interval, target bandwidth, and poll interval.
- **Hub Responders** - Opt in specific agents to listen on `5199/TCP` (+
  `5199/UDP` when UDP is enabled) with explicit concurrency and bandwidth caps.
- **Policies** - Bind spoke agents to hub responders (`hub_and_spoke`) or link
  responders together (`hub_mesh`) using a selected profile.
- **On-demand execution** - Trigger immediate runs from `/settings/networks/netperf`
  ("Run Test Now"), which dispatches a `netperf.run` command over `ControlStream`
  with a single-shot `NetperfPermitV1`.

### Revoking Issued Permits

Scheduled permits are valid for up to eight days and carry the Hub Responder's
authority epoch. Editing or disabling a policy rotates its permit IDs and drops
the target from the next config push, but it does not invalidate a permit a
spoke already holds. To revoke outstanding permits for a responder (for example
after tightening a profile or disabling a policy), click **Bump Epoch** on the
Hub Responder. Disabling a Hub Responder bumps its epoch as well. The responder
rejects any permit whose epoch is below its current epoch once it receives the
new config.

### Firewall Rules (Hub Responders only)

Only agents explicitly enabled as **Hub Responders** accept inbound traffic:

- **TCP `5199`** - Required for all Hub Responders (mTLS control and TCP data).
- **UDP `5199`** - Required only if the responder serves UDP tests.

Spoke-only agents require no inbound netperf ports.

## Querying Results with SRQL

Netperf measurements are stored as `rperf` time-series metrics. In SRQL,
`in:netperf`, `in:netperf_metrics`, `in:rperf`, and `in:rperf_metrics` all resolve
to the same metric scope (`metric_type = 'rperf'`).

Recent netperf measurements:

```srql
in:netperf sort:timestamp:desc limit:50
```

Throughput for a target over the last day:

```srql
in:rperf metric_name:"rperf.bits_per_second" tags.target:"hub-01" time:last_24h sort:timestamp:desc
```

UDP packet loss:

```srql
in:netperf metric_name:"rperf.loss_percent" tags.protocol:udp sort:timestamp:desc
```

See the [SRQL Language Reference](./srql-language-reference.md) for the full
`timeseries_metrics` field list (`metric_name`, `metric_type`, `value`,
`agent_id`, `timestamp`, and point tags such as `tags.target`,
`tags.responder_agent_id`, `tags.policy_id`, `tags.profile_id`,
`tags.direction`, `tags.protocol`, `tags.execution_source`, and
`tags.parallel`).

## Network Performance Dashboard

The built-in Network Performance dashboard at `/dashboards/network-performance`
shows netperf throughput, loss, jitter and availability per agent and target for
the last 24 hours.

## Alerting on Degradation

Because results land in `timeseries_metrics` with `metric_type = 'rperf'`, you
can build alerts the same way as any other metric:

- **Throughput drop** - alert when `rperf.bits_per_second` falls below an
  expected baseline.
- **Packet loss** - alert when `rperf.loss_percent` rises above a threshold for
  UDP targets.
- **Jitter** - alert when `rperf.jitter_ms` exceeds tolerance for
  latency-sensitive workloads.
- **Missing results** - alert when no `rperf` metrics arrive within a multiple
  of the policy poll interval.

Use the [Rule Builder](./rule-builder.md) to turn these into notifications.
