## ADDED Requirements

### Requirement: SNMP checker health checks are deadlock-free
The SNMP checker service MUST allow `Check()` and `GetStatus()` to execute concurrently with datapoint processing without deadlocking.

#### Scenario: Health check during concurrent datapoint updates
- **GIVEN** the SNMP checker is processing datapoints (updating internal status)
- **WHEN** a health check calls `Check()` concurrently with datapoint updates
- **THEN** `Check()` returns a result without blocking indefinitely

