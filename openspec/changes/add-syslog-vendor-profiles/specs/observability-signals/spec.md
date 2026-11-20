## ADDED Requirements

### Requirement: Vendor syslog normalization preserves the log record
The system SHALL, when a tenant has a syslog profile rule installed, add structured vendor fields to a matching syslog log record while keeping that record a log. The raw message body MUST remain stored. A message that matches no installed profile MUST be stored as it is stored today, including the lossless fallback for unrecognized formats.

#### Scenario: Matched vendor syslog stays a log
- **GIVEN** the tenant has the junos syslog profile installed
- **WHEN** a Junos `SNMP_TRAP_LINK_DOWN` message is ingested
- **THEN** the system SHALL store a log record
- **AND** the log attributes SHALL include `syslog.event` `INTERFACE_DOWN` and the interface name
- **AND** the system SHALL NOT create an OCSF event unless a separate promotion rule matches

#### Scenario: Unmatched syslog is unchanged
- **WHEN** a syslog message matches no installed profile
- **THEN** the system SHALL store the log with its original body
- **AND** `syslog.matched` SHALL be absent

### Requirement: Vendor syslog rules run before severity mapping
The system SHALL evaluate installed syslog profile rules on `logs.syslog` after `strip_full_message` and before `syslog_severity`, so severity mapping still runs on the original severity fields.

#### Scenario: Severity mapping still runs
- **GIVEN** a syslog profile rule is installed at order 112
- **AND** `syslog_severity` is installed at order 115
- **WHEN** a matching syslog record with GELF level 4 is normalized
- **THEN** the profile attributes SHALL be present
- **AND** `severity_text` SHALL still be set by the syslog severity rule
