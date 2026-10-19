# sweep-jobs

## ADDED Requirements

### Requirement: Sweep Device Discovery Scope

The system SHALL create a new device from a sweep result only for an answering
host whose address has no device, lies inside the sweep group's static targets,
and belongs to a group whose "Add newly found hosts to inventory" setting is
on. Hosts selected by the group's device query SHALL NOT create devices. A host
that does not qualify SHALL still be recorded as a host result without a device
and counted in the run's totals.

#### Scenario: Static target host is added to inventory
- **GIVEN** a sweep group with static target `198.51.100.0/24` and the
  setting on
- **WHEN** a sweep reports `198.51.100.20` available and no device holds that
  address
- **THEN** the system SHALL create a provisional device for `198.51.100.20`

#### Scenario: Device query host never creates a device
- **GIVEN** a sweep group with only a device query and no static targets
- **WHEN** a sweep reports an available host whose address no device holds,
  because the device it targeted was deleted or moved
- **THEN** the system SHALL NOT create a device for that address
- **AND** the host result SHALL be recorded without a device and counted

#### Scenario: Host outside the static targets is not added
- **GIVEN** a sweep group with static target `198.51.100.0/24` and a device
  query
- **WHEN** a sweep reports available hosts `198.51.100.30` and `203.0.113.30`
  and no device holds either address
- **THEN** the system SHALL create a device for `198.51.100.30` only

#### Scenario: Setting off adds nothing
- **GIVEN** a sweep group with static target `198.51.100.0/24` and the
  setting off
- **WHEN** a sweep reports an available host in that range with no device
- **THEN** the system SHALL NOT create a device

#### Scenario: Existing groups keep discovering
- **GIVEN** a sweep group created before the setting existed
- **WHEN** the system is upgraded
- **THEN** the group's setting SHALL be on without any data migration
