# Search Planner Operations

The device search planner fronts `/api/devices/search` and selects between the in-memory registry and the SRQL service. This runbook explains how to manage the rollout, interpret diagnostics, and monitor the new telemetry.

## Feature Flags

Planner usage can be toggled independently in the core service and the web UI:

- **Core**: `features.use_device_search_planner` in the `serviceradar-config` ConfigMap (`core.json`, default `true`).  
  Edit the config map (`kubectl edit configmap serviceradar-config -n demo`) or update `k8s/demo/base/configmap.yaml` before redeploying. After changing the flag, restart the core deployment:  
  `kubectl rollout restart deployment/serviceradar-core -n demo`.
- **Web UI**: `NEXT_PUBLIC_FEATURE_DEVICE_SEARCH_PLANNER` (default `true`).  
  Update the ConfigMap before rollout (`deploy.sh` generates it) or patch the deployment in place:
  ```bash
  kubectl set env deployment/serviceradar-web NEXT_PUBLIC_FEATURE_DEVICE_SEARCH_PLANNER=true -n demo
  kubectl set env deployment/serviceradar-web FEATURE_DEVICE_SEARCH_PLANNER=true -n demo
  ```

When either flag is disabled, the UI falls back to the legacy device list results and attaches diagnostics with `engine_reason: "feature_flag_disabled"`.

## Planner Diagnostics

`/api/devices/search` responses include a `diagnostics` map with the following keys:

| Field | Description |
|-------|-------------|
| `mode` | Caller-supplied planner mode (`auto`, `registry_only`, `srql_only`). |
| `engine_reason` | Why a backend was chosen (`query_supported`, `query_not_supported`, `registry_constraints`, `mode_forced`, `registry_only_available`). |
| `engine` | Backend that executed the query (`registry` or `srql`). |
| `duration_ms` | End-to-end planner latency, including registry lookup or SRQL round trip. |
| `unsupported_tokens` | SRQL tokens that forced a hand-off (only present when the planner routes to SRQL). |

### Example

```bash
curl -sk -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"in:devices status:online","filters":{"search":"serviceradar"},"pagination":{"limit":10}}' \
  https://core.serviceradar-demo/api/devices/search | jq '.diagnostics'
```

Output:

```json
{
  "mode": "auto",
  "engine_reason": "query_supported",
  "engine": "registry",
  "duration_ms": 2.3
}
```

## Telemetry Metrics

Planner execution emits the following OpenTelemetry metrics (exported via the standard `serviceradar.search` meter):

- `search_registry_duration_seconds` (`histogram`) — latency for registry-backed searches.  
  Dimensions: `mode`, `status` (`success` or `error`), `result_state` (`empty`, `lt10`, `lt50`, `lt100`, `gte100`).
- `search_srql_duration_seconds` (`histogram`) — latency for SRQL-backed searches with the same dimensions.
- `search_planner_fallback_total` (`counter`) — count of queries forced to SRQL because the registry could not satisfy them.  
  Dimensions: `reason` (`query_not_supported`, `registry_constraints`, or `unknown`) and `mode`.

### Prometheus Queries

```
histogram_quantile(0.95, rate(search_registry_duration_seconds_bucket[5m]))
histogram_quantile(0.95, rate(search_srql_duration_seconds_bucket[5m]))
increase(search_planner_fallback_total[15m])
```

Use these to confirm registry latency stays sub-millisecond and to identify unexpected fallback spikes.

## Rollout Playbook

1. **Stage in core**: Flip `features.use_device_search_planner` to `true` in `serviceradar-config` and restart `serviceradar-core`. Keep the UI flag disabled so only API clients exercise the planner.
2. **Validate**: Tail planner metrics (`kubectl logs deployment/serviceradar-core -n demo | grep search_planner`) and verify histograms appear in Prometheus.
3. **Enable UI flag**: Set `NEXT_PUBLIC_FEATURE_DEVICE_SEARCH_PLANNER=true` (and matching server flag) in the web deployment and redeploy.
4. **Monitor**: Watch `search_planner_fallback_total` and SRQL latency. Sustained increases indicate unsupported SRQL patterns; inspect `engine_reason` diagnostics to pinpoint problem queries.
5. **Rollback**: Set both flags to `false` and redeploy core/web. The legacy `/api/devices` list path remains available as a safe fallback.

## Troubleshooting

- **Unexpected SRQL traffic**: Check the planner diagnostics for `engine_reason: "query_not_supported"`. Queries containing aggregations (`count(`, `sum(`), joins, or metadata fan-out currently require SRQL.
- **Empty registry results**: Confirm the device registry is hydrated (`core_device_stats_processed_records` gauge) and that the trigram index contains entries (`SearchDevices` unit tests cover expected behavior).
- **Slow SRQL latency**: Use `search_srql_duration_seconds` to detect regressions and review the SRQL service logs (`ocaml/srql`). Consider increasing SRQL timeouts or scaling the service if demand spikes.
