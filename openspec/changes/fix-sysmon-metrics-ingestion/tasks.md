## 1. Implementation
- [ ] 1.1 Update edge-architecture spec delta for sysmon metrics ingestion and payload sizing
- [ ] 1.2 Add Ash resource for cpu_cluster_metrics and register in Observability domain
- [ ] 1.3 Add sysmon metrics ingestor to parse gRPC payloads and bulk insert per-tenant metrics
- [ ] 1.4 Route sysmon status updates through the ingestor in StatusHandler
- [ ] 1.5 Allow larger sysmon-metrics payloads in agent-gateway normalization
- [ ] 1.6 Add tests covering sysmon ingestion mapping and payload handling
