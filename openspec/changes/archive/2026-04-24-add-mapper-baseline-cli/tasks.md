## 1. Proposal
- [x] 1.1 Define the standalone mapper baseline CLI scope and credential boundary in specs

## 2. Implementation
- [x] 2.1 Add a standalone Go CLI entrypoint for mapper baseline runs
- [x] 2.2 Support explicit SNMP, UniFi, and MikroTik input modes
- [x] 2.3 Emit stable JSON artifacts for devices, interfaces, links, and summary counts
- [x] 2.4 Add focused tests for baseline config parsing and output shaping

## 3. Integration Boundary
- [x] 3.1 Add an Ash-managed export path or documented follow-up for saved controller config resolution
- [x] 3.2 Document that direct Postgres/AshCloak decryption from the Go CLI is out of scope
