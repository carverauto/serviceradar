## 1. Implementation
- [x] 1.1 Audit current log ingestion/storage for OTEL schema retention and identify where fields are dropped.
- [x] 1.2 Define and implement mapping for syslog/SNMP/GELF into OTEL log record fields (severity, body, resource/scope/attributes).
- [x] 1.3 Update log query/SRQL paths to return OTEL fields required by the UI.
- [x] 1.4 Update Logs UI to render OTEL schema fields in list/detail views.
- [x] 1.5 Add coverage (unit/integration) to verify OTEL fields persist from ingest through UI.
