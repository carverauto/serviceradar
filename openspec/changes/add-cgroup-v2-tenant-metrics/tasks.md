## 1. Collector and Configuration
- [ ] 1.1 Add sysmon configuration for cgroup-v2 collection roots, include filters, exclude filters, and safe defaults.
- [ ] 1.2 Implement cgroup-v2 filesystem discovery with runtime support detection and permission-aware errors.
- [ ] 1.3 Read `cpu.stat`, `memory.current`, `memory.stat`, `pids.current`, and `io.stat` for configured cgroups.
- [ ] 1.4 Derive stable per-cgroup reset anchors from kernel cgroup identifiers or filesystem inode/ctime metadata.

## 2. Metric Contract
- [ ] 2.1 Publish cgroup metrics through the unified JetStream metric event envelope.
- [ ] 2.2 Attach cgroup path, slice, tenant/account, container, and Kubernetes metadata as metric attributes when available.
- [ ] 2.3 Mark cumulative cgroup counters with monotonic counter semantics from `add-monotonic-counter-metric-semantics`.
- [ ] 2.4 Ensure event_writer persists cgroup attributes without adding source-specific metric tables.

## 3. Product Surfaces
- [ ] 3.1 Add SRQL examples or saved queries for per-device cgroup CPU, memory, process, and IO usage.
- [ ] 3.2 Add a device detail table for recent cgroup or tenant resource usage when cgroup metrics exist.
- [ ] 3.3 Keep tenant/cgroup labels scoped to the attested device and avoid treating them as authorization identities.

## 4. Validation
- [ ] 4.1 Add sysmon unit tests with synthetic cgroup-v2 fixture files.
- [ ] 4.2 Add reset-anchor tests for cgroup recreation without host reboot.
- [ ] 4.3 Add ingestion tests proving cgroup metrics share the same persisted shape as host and plugin metrics.
- [ ] 4.4 Add UI tests for empty-state and populated per-cgroup tables.
