# Tasks: Update SNMP Credential Resolution

## 1. Data Model & Migrations
- [x] 1.1 Add SNMP credential fields to SNMPProfile (v1/v2c/v3, encrypted)
- [x] 1.2 Add device-level SNMP credential override resource + migration (encrypted)
- [x] 1.3 Add profile priority ordering (if not already present) and enforce default uniqueness

## 2. Credential Resolution
- [x] 2.1 Implement credential resolver with precedence: device override > profile creds
- [x] 2.2 Apply resolver in SNMPCompiler for polling config
- [x] 2.3 Apply resolver in mapper discovery config/runner

## 3. Mapper Discovery Jobs
- [x] 3.1 Remove per-job SNMP credential fields from MapperJob schema/actions
- [x] 3.2 Update Settings → Networks → Discovery UI to remove SNMP creds UI
- [x] 3.3 Ensure discovery jobs still compile with profile-based credentials

## 4. SNMP Profiles UI
- [x] 4.1 Add credential inputs to SNMP Profile editor (v2c/v3)
- [x] 4.2 Ensure secrets are masked and preserved on edit

## 5. Migration & Compatibility
- [x] 5.1 Provide a migration path for existing mapper job SNMP credentials
- [x] 5.2 Add validation or warnings when no matching profile/creds exist

## 6. Tests
- [x] 6.1 Unit tests for credential resolution precedence
- [x] 6.2 Integration tests for mapper discovery using profile creds
- [x] 6.3 UI tests for profile credentials + device override flows
