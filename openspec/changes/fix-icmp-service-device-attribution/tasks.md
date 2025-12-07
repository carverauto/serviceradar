## 1. Implementation
- [ ] 1.1 Ensure agent ICMP responses always attribute capability snapshots and metrics to the agent service device, treating any target `device_id`/host hints as metadata instead of the primary device ID.
- [ ] 1.2 Normalize or drop placeholder/non-IP host identifiers (for example `host_ip: "agent"`) when resolving ICMP collector devices so capability snapshots and metric summaries stay on the collector device.
- [ ] 1.3 Add regression tests covering ICMP payloads with `device_id` + `agent_id` to confirm capability snapshots, collector capability hints, and metric summaries expose ICMP for `k8s-agent` in device responses.
- [ ] 1.4 Verify device and metrics endpoints in the demo/k8s profile return ICMP capability + `metrics_summary.icmp=true` for `serviceradar:agent:k8s-agent` (UI sparkline renders).
