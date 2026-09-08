## ADDED Requirements
### Requirement: Manual Device Re-add Reconciliation

The system SHALL reconcile manual device re-add attempts against existing include-deleted inventory records before inserting a new manual device.

#### Scenario: Hostname-only duplicate merges into resolved-IP record
- **GIVEN** a hostname-only manual device exists for `serviceradar.cloud`
- **AND** a separate active device exists for the IP address currently resolved from `serviceradar.cloud`
- **WHEN** an operator manually adds `serviceradar.cloud` again
- **THEN** the system SHALL update the resolved-IP device with the hostname/manual metadata
- **AND** SHALL merge the hostname-only duplicate into the resolved-IP canonical device
- **AND** SHALL preserve inventory associations through the existing device merge path
