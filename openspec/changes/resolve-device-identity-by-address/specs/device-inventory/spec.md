## ADDED Requirements

### Requirement: A device identity can be resolved from an address
The system SHALL expose device identity resolution from an address as a read, without
probing the device or evaluating any check. It SHALL accept a single address and a batch
of addresses, and SHALL apply the same resolution rules as the existing internal resolver:
the IP is authoritative, an optional MAC corroborates it, and no identity is created.

#### Scenario: A known address resolves
- **GIVEN** an address held by exactly one live device in a partition
- **WHEN** a permitted caller resolves that address
- **THEN** the response SHALL carry that device's uid

#### Scenario: Resolving causes no side effects
- **WHEN** an address is resolved
- **THEN** no probe SHALL be started
- **AND** no validation run SHALL be created
- **AND** no device identity SHALL be created

#### Scenario: A corroborating MAC is accepted
- **GIVEN** an address whose device also holds the MAC supplied with it
- **WHEN** the address is resolved
- **THEN** the response SHALL carry that device's uid

#### Scenario: A MAC pointing at another device is a conflict
- **GIVEN** an address that resolves to one device and a MAC held by a different one
- **WHEN** the address is resolved
- **THEN** the outcome SHALL be reported as a conflict
- **AND** it SHALL name both devices
- **AND** it SHALL NOT be reported as a successful resolution

#### Scenario: A MAC unknown to inventory is ignored
- **GIVEN** an address that resolves, and a MAC held by no device
- **WHEN** the address is resolved
- **THEN** the response SHALL carry the address's uid

#### Scenario: An address held by several devices is ambiguous
- **GIVEN** an address held by more than one live device in a partition
- **WHEN** the address is resolved
- **THEN** the outcome SHALL be reported as ambiguous
- **AND** it SHALL name the candidate uids

#### Scenario: An unknown address is not found
- **WHEN** an address held by no device is resolved
- **THEN** the outcome SHALL be reported as not found
- **AND** it SHALL NOT be reported as a server error

#### Scenario: An unusable address is rejected
- **WHEN** a value that is not a valid address is submitted
- **THEN** the request SHALL be rejected as malformed

### Requirement: A batch resolution reports each address independently
A batch resolution SHALL report an outcome for every address submitted, and one address
that cannot be resolved SHALL NOT prevent the others from being reported.

#### Scenario: A mixed batch reports every outcome
- **GIVEN** a batch holding a resolvable address and an unknown one
- **WHEN** the batch is resolved
- **THEN** the resolvable address SHALL carry its uid
- **AND** the unknown address SHALL carry its reason
- **AND** the request SHALL NOT be reported as failed

#### Scenario: Outcomes can be matched to their inputs
- **WHEN** a batch is resolved
- **THEN** each outcome SHALL identify the address it is for

#### Scenario: An over-long batch is refused
- **WHEN** a batch exceeds the supported number of addresses
- **THEN** the request SHALL be rejected
- **AND** the response SHALL state the limit

#### Scenario: A batch entry with no address is refused, not dropped
- **WHEN** a batch holds an entry carrying no address
- **THEN** the request SHALL be rejected as malformed
- **AND** the entry SHALL NOT be silently discarded

#### Scenario: A blank partition means the one the request supplied
- **GIVEN** a batch naming a partition, holding an entry whose own partition is blank
- **WHEN** the batch is resolved
- **THEN** the entry SHALL be resolved within the partition the request named

### Requirement: Resolving an identity is separately authorized
Resolving a device identity SHALL require its own permission, distinct from the permission
to execute a validation run.

#### Scenario: A caller permitted only to resolve may resolve
- **GIVEN** a caller holding the identity resolution permission and not the permission to
  execute validation runs
- **WHEN** it resolves an address
- **THEN** the request SHALL be permitted

#### Scenario: An unpermitted caller is refused
- **GIVEN** a caller holding neither permission
- **WHEN** it resolves an address
- **THEN** the request SHALL be refused
- **AND** it SHALL NOT reveal whether a device exists at that address

#### Scenario: It defaults with the inventory reads it is weaker than
- **WHEN** the permission catalog is upgraded
- **THEN** identity resolution SHALL default to the roles that may already view the device
  inventory
- **AND** it SHALL NOT default to any role that may not
