## 1. Research
- [ ] 1.1 Review gopsutil CPU/memory/disk/process collection costs and platform caveats
- [ ] 1.2 Document current sysmon sampling + upload behavior (agent, gateway, ingest)

## 2. Configuration
- [ ] 2.1 Extend sysmon config schema with upload_interval, downsample_window, and per-metric intervals
- [ ] 2.2 Update config compiler/serialization for new fields (backward compatible)
- [ ] 2.3 Add validation for interval bounds and supported aggregation modes

## 3. Agent collection + aggregation
- [ ] 3.1 Implement windowed aggregation in pkg/sysmon (avg/min/max/last)
- [ ] 3.2 Emit downsampled MetricSample at upload cadence
- [ ] 3.3 Ensure process metrics can be sampled at a separate cadence

## 4. Ingestion + compatibility
- [ ] 4.1 Verify downstream ingest accepts downsampled samples without schema changes
- [ ] 4.2 Add tests for downsampling correctness and window alignment

## 5. Documentation
- [ ] 5.1 Update sysmon config docs with new fields and defaults
- [ ] 5.2 Add guidance on recommended intervals for scale
