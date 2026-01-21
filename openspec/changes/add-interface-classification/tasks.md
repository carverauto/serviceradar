## 1. Planning
- [ ] 1.1 Confirm classification taxonomy (management/wan/lan/vpn/loopback/virtual/unknown)
- [ ] 1.2 Decide rule precedence and conflict resolution policy

## 2. Data Model
- [x] 2.1 Add Ash resource `InterfaceClassificationRule` with admin/operator CRUD
- [x] 2.2 Add migrations for rules table
- [x] 2.3 Extend interface resource with classification fields
- [x] 2.4 Add migrations for interface classification fields

## 3. Classification Engine
- [x] 3.1 Implement rule evaluation helper (Ash-first, deterministic ordering)
- [x] 3.2 Invoke classification during mapper interface ingestion
- [x] 3.3 Preserve existing classifications when updates lack interface data

## 4. Seeds & Defaults
- [x] 4.1 Seed UniFi/Ubiquiti management interface rules
- [x] 4.2 Seed WireGuard interface rules

## 5. Tests
- [x] 5.1 Unit tests for rule matching and precedence
- [ ] 5.2 Integration test for SNMP mapper ingestion -> interface classification

## 6. API & UI Readiness
- [x] 6.1 Expose rule list/read endpoints for future UI
- [ ] 6.2 Add interface classification fields to device detail response
- [ ] 6.3 Document rule schema in spec + ops docs
