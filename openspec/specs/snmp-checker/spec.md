# snmp-checker Specification

## Purpose
TBD - created by archiving change fix-snmp-check-deadlock. Update Purpose after archive.
## Requirements
### Requirement: SNMP checker health checks are deadlock-free
The SNMP checker service MUST allow `Check()` and `GetStatus()` to execute concurrently with datapoint processing without deadlocking.

#### Scenario: Health check during concurrent datapoint updates
- **GIVEN** the SNMP checker is processing datapoints (updating internal status)
- **WHEN** a health check calls `Check()` concurrently with datapoint updates
- **THEN** `Check()` returns a result without blocking indefinitely

### Requirement: SNMP PDU string types convert without panics
The SNMP checker MUST convert gosnmp PDU values of type `OctetString` and `ObjectDescription` into Go strings without panicking.

#### Scenario: Convert OctetString value returned as bytes
- **GIVEN** an SNMP response variable with Type `OctetString` and Value `[]byte("Test SNMP String")`
- **WHEN** the SNMP client converts the variable
- **THEN** the conversion result is the string `"Test SNMP String"` and conversion returns no error

#### Scenario: Convert ObjectDescription value returned as bytes
- **GIVEN** an SNMP response variable with Type `ObjectDescription` and Value `[]byte("Device OS v1.2.3")`
- **WHEN** the SNMP client converts the variable
- **THEN** the conversion result is the string `"Device OS v1.2.3"` and conversion returns no error

#### Scenario: Unexpected value type does not crash the checker
- **GIVEN** an SNMP response variable with Type `OctetString` or `ObjectDescription` and a Value that is not a `[]byte`
- **WHEN** the SNMP client converts the variable
- **THEN** conversion returns an error and the checker does not panic

