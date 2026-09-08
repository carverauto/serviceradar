## 1. Research
- [ ] 1.1 Review gopsutil CPU/memory/disk/process collection costs and platform caveats
- [ ] 1.2 Document current sysmon sampling + upload behavior (agent, gateway, ingest)

## 2. Configuration
- [ ] 2.1 Extend sysmon config schema with upload_interval, downsample_window, and per-metric intervals
- [ ] 2.2 Update config compiler/serialization for new fields (backward compatible)
- [ ] 2.3 Add validation for interval bounds and supported aggregation modes
- [ ] 2.4 Add process telemetry mode configuration (`rollup`, `top_n`, `detail`) with safe defaults and explicit opt-in for raw per-process detail
- [ ] 2.5 Add optional detail-mode TTL/profile targeting guardrails so fleet-wide raw process rows cannot be enabled accidentally

## 3. Agent collection + aggregation
- [ ] 3.1 Implement windowed aggregation in pkg/sysmon (avg/min/max/last)
- [ ] 3.2 Emit downsampled MetricSample at upload cadence
- [ ] 3.3 Ensure process metrics can be sampled at a separate cadence
- [ ] 3.4 Emit process rollups/top-N summaries by default without per-process raw CPU/memory rows
- [ ] 3.5 Keep per-process raw detail available for bounded troubleshooting windows

## 4. Ingestion + compatibility
- [ ] 4.1 Verify downstream ingest accepts downsampled samples without schema changes
- [ ] 4.2 Add tests for downsampling correctness and window alignment
- [x] 4.3 Exclude process telemetry from default anomaly/capacity inputs while keeping process metrics on the JetStream/CNPG diagnostic path

## 5. Documentation
- [ ] 5.1 Update sysmon config docs with new fields and defaults
- [ ] 5.2 Add guidance on recommended intervals for scale
- [ ] 5.3 Document the 50k-agent process row-rate math and when to enable raw detail mode
