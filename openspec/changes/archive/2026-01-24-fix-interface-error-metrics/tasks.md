## 1. Implementation
- [x] 1.1 Reproduce the missing interface error metrics on staging and capture expected SRQL payload/fields.
- [x] 1.2 Verify SNMP profile compilation includes in/out error counters and maps them to canonical metric keys.
- [x] 1.3 Ensure ingestion writes interface error counters to the interface metrics store (add/adjust schema or mapping as needed).
- [x] 1.4 Update SRQL `in:interfaces` projections to include error counter fields for latest and time-series queries.
- [x] 1.5 Update interface metrics UI to render error counters and show an empty-state when data is absent.
- [x] 1.6 Add coverage (unit/integration) for collector mapping, ingestion projection, SRQL output, and UI rendering.
