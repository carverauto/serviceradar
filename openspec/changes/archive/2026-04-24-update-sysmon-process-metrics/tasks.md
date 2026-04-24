## 1. Implementation
- [ ] 1.1 Verify sysmon process collection with `collect_processes` and `process_top_n` settings (agent/sysmon library).
- [ ] 1.2 Confirm gateway/core ingestion writes `process_metrics` rows with PID, process name, CPU%, memory% fields.
- [x] 1.3 Add/adjust SRQL queries to fetch latest process metrics per device for UI use.
- [x] 1.4 Add a device detail "Processes" panel showing top N processes by CPU/memory.
- [x] 1.5 Add tests covering process metrics ingestion and UI rendering.
- [x] 1.6 Document troubleshooting steps (where to verify process metrics in CNPG/SRQL).
