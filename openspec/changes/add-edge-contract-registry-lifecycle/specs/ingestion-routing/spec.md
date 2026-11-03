# ingestion-routing Delta

## ADDED Requirements

### Requirement: Compromised signing-key cohorts are remediated fail-closed
On compromise revocation of a producer signing key, the deployment SHALL remediate
the affected cohort fail-closed and SHALL NOT authoritatively project any record that
key signed. Every record signed by the compromise-revoked key SHALL resolve to
`historically_revoked` and be captured as a `ledger_only` audit row plus a
security-quarantine DLQ entry, and SHALL NEVER be authoritatively projected. Domain
rows that were already authoritatively projected from that key or cohort before
revocation SHALL be marked `security_held` and scheduled for operator-authorized
retraction or redrive under a fixed safe bundle rather than silently retained as
trusted state. Redrive of a remediated cohort SHALL use a durable synthetic spool, a
fresh delivery/map envelope, and a capability bound to the immutable catalog record,
and the ingest ledger SHALL make already-committed events harmless so a redrive
neither duplicates domain side effects nor reinstates compromised trust.

#### Scenario: A signing key is revoked for compromise after projection
- **GIVEN** a producer signing key is revoked for compromise after some of its
  records were already authoritatively projected
- **WHEN** EventWriter evaluates new and replayed deliveries signed by that key
- **THEN** every such record SHALL resolve to `historically_revoked`, land as a
  `ledger_only` audit row plus a security-quarantine DLQ entry, and SHALL NOT be
  authoritatively projected
- **AND** the already-projected domain rows from that cohort SHALL be marked
  `security_held` and scheduled for operator-authorized retraction or redrive under a
  fixed safe bundle
- **AND** an authorized redrive SHALL republish through a durable synthetic spool with
  a fresh delivery/map envelope and a capability bound to the immutable catalog
  record, while the ingest ledger makes already-committed events harmless
