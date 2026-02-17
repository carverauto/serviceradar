# God-View Topology

God-View is the high-density topology experience for large graphs with causal blast-radius overlays.

## Feature Flag

God-View is controlled by:

- `SERVICERADAR_GOD_VIEW_ENABLED=true|false`

Runtime behavior:

- `false` (default): `/topology` is hidden/disabled.
- `true`: `/topology`, topology channel stream, and latest snapshot endpoint are available.

## Rollout Guidance

Recommended rollout order:

1. Enable in local Docker Compose or `demo` first.
2. Validate stability and performance.
3. Enable broader environments only after SLO validation.

For Helm-based deployments:

- Set `webNg.extraEnv.SERVICERADAR_GOD_VIEW_ENABLED: "true"` in the target values file.

## Operator Controls

Primary controls in God-View:

- Causal filter toggles (`root_cause`, `affected`, `healthy`, `unknown`)
- Visual ghosting/highlight controls
- Semantic zoom mode
- Structural reshape actions (collapse/expand paths)

Interpretation:

- `root_cause`: primary fault origin
- `affected`: blast-radius impacted nodes
- `healthy`: unaffected nodes
- `unknown`: insufficient/conflicting evidence

## Known Limitations

- Performance depends on browser/GPU capability; WebGPU-capable clients perform best.
- Unsupported WebGPU clients run in fallback mode with reduced throughput.
- Large revisions may be dropped under budget pressure to preserve interaction responsiveness.
- Causal confidence is bounded by telemetry quality/completeness.

## Telemetry and Signals

God-View emits operational telemetry for:

- Snapshot build latency
- Snapshot payload size
- Snapshot dropped count
- Snapshot error count

Use these metrics to validate rollout health and SLO readiness.

Recent local validation (February 14, 2026, Docker Compose CNPG + `web-ng`):

- Snapshot build (`GodViewStream.latest_snapshot/0`, 20 runs): `p50=14.12ms`, `p95=35.26ms` (warm path).
- Synthetic 100k encode (`Native.encode_snapshot/8`): `33.96ms` for `100,000` nodes and `99,999` edges.
- Synthetic 100k causal evaluation (`Native.evaluate_causal_states/2`): `103.23ms` for `100,000` nodes.

## Troubleshooting

### `/topology` is not visible

- Confirm `SERVICERADAR_GOD_VIEW_ENABLED=true` for `web-ng`.
- Confirm the pod has restarted with updated env.

### Stream fails to join (`god_view_disabled`)

- Feature flag is disabled at runtime.
- Verify `web-ng` runtime env and effective config.

### Snapshot decode errors

- Check schema/version compatibility between server and client.
- Verify latest deployed frontend bundle matches backend snapshot contract.

### Frequent dropped snapshots

- Check snapshot budget configuration and host load.
- Reduce update pressure and verify telemetry around build time and drop counts.
