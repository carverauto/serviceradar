# Tasks: Update SNMP Credential Resolution

## 1. Data Model & Migrations
- [ ] 1.1 Add SNMP credential fields to SNMPProfile (v1/v2c/v3, encrypted)
- [ ] 1.2 Add device-level SNMP credential override resource + migration (encrypted)
- [ ] 1.3 Add profile priority ordering (if not already present) and enforce default uniqueness

## 2. Credential Resolution
- [ ] 2.1 Implement credential resolver with precedence: device override > profile creds
- [ ] 2.2 Apply resolver in SNMPCompiler for polling config
- [ ] 2.3 Apply resolver in mapper discovery config/runner

## 3. Mapper Discovery Jobs
- [ ] 3.1 Remove per-job SNMP credential fields from MapperJob schema/actions
- [ ] 3.2 Update Settings → Networks → Discovery UI to remove SNMP creds UI
- [ ] 3.3 Ensure discovery jobs still compile with profile-based credentials

## 4. SNMP Profiles UI
- [ ] 4.1 Add credential inputs to SNMP Profile editor (v2c/v3)
- [ ] 4.2 Ensure secrets are masked and preserved on edit

## 5. Migration & Compatibility
- [ ] 5.1 Provide a migration path for existing mapper job SNMP credentials
- [ ] 5.2 Add validation or warnings when no matching profile/creds exist

## 6. Tests
- [ ] 6.1 Unit tests for credential resolution precedence
- [ ] 6.2 Integration tests for mapper discovery using profile creds
- [ ] 6.3 UI tests for profile credentials + device override flows
