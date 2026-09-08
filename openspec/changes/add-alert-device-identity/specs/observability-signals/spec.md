# observability-signals

## ADDED Requirements

### Requirement: Engine-fired alerts carry a canonical device identity

An alert created from an OCSF event SHALL be able to record the device it is
about, in `alerts.device_uid`.

The value SHALL be a canonical `ocsf_devices.uid` or NULL. It SHALL NOT be read
directly from the source record: a record's `device_uid`/`device_id` is whatever
the producer supplied and is frequently a hostname, an IP, or a plugin-local id.
The stateful alert engine SHALL resolve the record through the device
correlation resolver and pass the canonical result, or NULL when it does not
resolve.

An alert whose device does not resolve SHALL still be created. NULL is a valid
outcome; failing to create the alert is not.

#### Scenario: A resolvable record produces an alert carrying its device
- **GIVEN** a stateful alert rule fires on a record whose device resolves to a canonical uid
- **WHEN** the alert is created
- **THEN** `alerts.device_uid` holds that canonical uid

#### Scenario: An unresolvable record still produces an alert
- **GIVEN** a record whose device does not resolve to any known device
- **WHEN** the alert is created
- **THEN** the alert is created with `device_uid` NULL
- **AND** the alert is NOT dropped

#### Scenario: A non-canonical identifier is never written
- **GIVEN** a record carrying a hostname or IP in its device field
- **WHEN** the alert is created
- **THEN** that raw value is NOT written to `device_uid`

#### Scenario: An empty identifier is treated as absent
- **WHEN** a caller supplies an empty or whitespace-only device uid
- **THEN** it is normalised to NULL rather than reaching the column

### Requirement: Out-of-service suppression applies to engine-fired alerts

With a device identity present, an alert for a device marked out of service
SHALL be suppressed by the create-time gate on the alert `:trigger` action, and
SHALL be withheld from notification by the `:device_out_of_service` suppression
reason.

This is existing designed behaviour that could not previously apply: the gates
key on `device_uid`, and device liveness treats a NULL identity as active, so
every engine-fired alert bypassed both.

#### Scenario: An alert for an out-of-service device is suppressed
- **GIVEN** a device is marked out of service
- **WHEN** a rule fires an alert that resolves to that device
- **THEN** the create-time gate rejects it

#### Scenario: An alert with no resolved device is not suppressed
- **GIVEN** an alert whose device did not resolve
- **THEN** the out-of-service gate does not suppress it
- **AND** the alert is created normally
