## ADDED Requirements

### Requirement: Partition-Scoped Address Resolution

The system SHALL resolve a live device from an IP address and a
partition without minting a new canonical uid.

Resolution SHALL prefer a `device_identifiers` row of type `ip` whose
`partition` matches the requested partition. When no such identifier
exists, resolution SHALL fall back to the unique live `ocsf_devices`
row with that IP.

An optional MAC SHALL corroborate the IP resolution. A MAC that is
absent from inventory SHALL be ignored. A MAC that resolves to a
different live device than the IP SHALL be reported as a conflict.
The MAC SHALL NOT override the IP.

This resolution is the identity contract used by the validation-run
API. It SHALL NOT create devices, identifiers, or aliases.

#### Scenario: Resolve by IP in the default partition

- **GIVEN** a live device with IP `192.168.1.55` and no conflicting
  identifier in partition `default`
- **WHEN** a caller resolves `{ip: "192.168.1.55", partition: "default"}`
- **THEN** the result SHALL be that device's `sr:` uid

#### Scenario: Unknown address is not created

- **WHEN** a caller resolves an IP that matches no live device in the
  requested partition
- **THEN** the result SHALL be not-found
- **AND** no `ocsf_devices` or `device_identifiers` row SHALL be inserted

#### Scenario: Conflicting MAC is reported

- **GIVEN** IP `192.168.1.55` resolves to device A
- **AND** MAC `aa:bb:cc:dd:ee:ff` resolves to device B
- **WHEN** a caller resolves both together
- **THEN** the result SHALL be a conflict naming both uids
