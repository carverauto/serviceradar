## 1. Implementation
- [ ] 1.1 Capture ingest-time observed timestamps for JSON log payloads when missing (syslog/GELF)
- [ ] 1.2 Update SRQL logs query planning to use effective timestamps for time filters and ordering
- [ ] 1.3 Adjust log list queries in the web UI if any client-side defaults hardcode timestamp-only semantics
- [ ] 1.4 Add tests for log ordering/time filtering with observed timestamp fallback
