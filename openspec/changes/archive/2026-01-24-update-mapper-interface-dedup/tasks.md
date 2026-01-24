## 1. Implementation
- [x] 1.1 Define the canonical interface de-dup key for mapper jobs (device identity + interface identifier).
- [x] 1.2 Add a mapper job interface registry to upsert and merge interface records before publishing.
- [x] 1.3 Update SNMP and API discovery flows to use the interface registry and only publish unique/merged interfaces.
- [x] 1.4 Add tests covering duplicate interface merges across SNMP/API and multiple seed scans.
