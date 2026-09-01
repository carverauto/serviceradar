## ADDED Requirements

### Requirement: OTLP producers can attribute a log to a device
An OTLP log record SHALL be able to declare the device it concerns, using the same
attribute keys the system already accepts on events. A log so attributed SHALL be returned
by a device log query for that device.

#### Scenario: A producer names the device by address
- **GIVEN** an OTLP log record carrying a host attribute holding a device's address
- **WHEN** the record is ingested
- **THEN** a device log query for that device SHALL return the record

#### Scenario: A producer names the device by identity
- **GIVEN** an OTLP log record carrying a device identity attribute
- **WHEN** the record is ingested
- **THEN** a device log query for that device SHALL return the record

#### Scenario: Identity is preferred over address
- **GIVEN** a record carrying both a device identity and a host address
- **WHEN** the record is ingested
- **THEN** the identity SHALL determine the device

#### Scenario: An unattributed log is unchanged
- **WHEN** an OTLP log record carries no device attribute
- **THEN** it SHALL be stored and queryable exactly as before
- **AND** it SHALL NOT be attributed to any device

#### Scenario: An unresolvable attribute does not guess
- **WHEN** a record's device attribute is not a usable address and matches no known device
- **THEN** the record SHALL be stored unattributed
- **AND** it SHALL NOT be attributed to a device by partial or approximate matching

#### Scenario: Existing producers are unaffected
- **WHEN** syslog, GELF or trap records are ingested
- **THEN** their device correlation SHALL behave exactly as before

### Requirement: Device correlation for logs stays a query-time equality join
Device attribution for logs SHALL be resolved when a record is ingested, into the column
device log queries already join on. A device log query MUST NOT search log attributes.

#### Scenario: The read path is unchanged
- **WHEN** a device log query runs
- **THEN** it SHALL correlate through the existing indexed column
- **AND** it SHALL NOT scan or pattern-match attributes

#### Scenario: Attribution is durable
- **GIVEN** a record ingested with a device attribute
- **WHEN** it is queried later
- **THEN** its attribution SHALL not depend on re-reading its attributes
