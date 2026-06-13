# Change: Add cgroup-v2 tenant resource metrics

## Why
Issue 3790 calls out that host-level sysmon metrics are not enough for ApisCP-style multi-tenant hosts where each account maps to a cgroup or systemd slice. Operators need per-tenant CPU, memory, process, and IO signals that flow through the same JetStream metric contract as host, SNMP, OTEL, and plugin metrics.

## What Changes
- Add a sysmon cgroup-v2 collector that reads configured cgroup roots and emits per-cgroup resource metrics through the unified metric pipeline.
- Model cgroup identity as metric attributes on a host resource instead of inventing a separate metric stream or per-plugin UI path.
- Add per-cgroup reset anchors so cumulative cgroup counters can be normalized safely when cgroups are recreated.
- Add web/SRQL views for per-cgroup or per-tenant resource usage on device detail pages and dashboards.

## Impact
- Affected specs: sysmon-library, agent-configuration, build-web-ui
- Affected code: Go sysmon collector/config, metric event publishing, event_writer metric persistence, SRQL/web-ng device detail surfaces
- Depends on: OpenSpec change `update-anomaly-evaluation-cadence`, which defines the canonical `serviceradar.metric.v1` contract used by cgroup metrics
- Related changes: add-monotonic-counter-metric-semantics
