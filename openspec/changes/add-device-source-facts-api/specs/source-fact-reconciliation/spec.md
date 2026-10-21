## ADDED Requirements

### Requirement: Externally reported source facts
The system SHALL let an authenticated external caller report and withdraw its own value for a platform fact key (`switch_port_attachment` or `vlan_uid`) on a device through the API.

A reported value SHALL be stored and compared in the same way as a fact from a sync update: per source and instance, and subject to promotion and disagreement detection. The source SHALL be recorded as `api:<label>` for the caller's label. The source instance SHALL be derived from the authenticated caller and SHALL NOT be accepted as input. Observation time SHALL be stamped by the server.

Reporting SHALL require the `devices.source_facts.write` permission. Addressing the device SHALL require that the device is visible to the caller.

#### Scenario: Sole source becomes canonical
- **GIVEN** a device has no switch-port fact from any source
- **WHEN** a caller reports `switch_port_attachment` with switch hostname `access01.example.com` and port `Gi1/0/7` under source label `example-nms`
- **THEN** the system SHALL store the fact under source `api:example-nms` with the caller as instance
- **AND** the device's canonical `switch_port_attachment` SHALL be that value, attributed to `api:example-nms`

#### Scenario: Disagreement with an integration holds canonical
- **GIVEN** the canonical `switch_port_attachment` came from the Armis integration
- **AND** no fact authority is configured
- **WHEN** a caller reports a different switch port for the same device
- **THEN** the canonical value SHALL remain the Armis value
- **AND** a `switch_port_attachment` disagreement SHALL be opened that lists both sources

#### Scenario: A label cannot impersonate an integration
- **GIVEN** the Armis integration source is authoritative for `switch_port_attachment`
- **WHEN** a caller reports a switch port under the label `armis`
- **THEN** the fact SHALL be recorded under source `api:armis`
- **AND** it SHALL NOT match the Armis authority row

#### Scenario: Callers cannot touch each other's facts
- **GIVEN** caller A reported a switch port for a device under label `example-nms`
- **WHEN** caller B withdraws `switch_port_attachment` under the same label
- **THEN** caller A's fact SHALL remain present

#### Scenario: Withdrawing an unsupported canonical value clears it
- **GIVEN** a caller's reported switch port is the device's canonical value
- **AND** no other present source reports the same value
- **WHEN** the caller withdraws the fact
- **THEN** the fact SHALL be marked absent
- **AND** the canonical `switch_port_attachment` SHALL be cleared

#### Scenario: Withdrawing a fact that another source still reports keeps canonical
- **GIVEN** a caller and an integration report the same switch port for a device
- **WHEN** the caller withdraws its fact
- **THEN** the canonical value SHALL remain the switch port the integration reports

#### Scenario: An unreadable value is rejected
- **WHEN** a caller reports `switch_port_attachment` without a port, or `vlan_uid` outside 1-4094
- **THEN** the request SHALL be rejected with the reason
- **AND** nothing SHALL be written

#### Scenario: Reporting requires its own permission
- **GIVEN** a caller that can view the device but lacks `devices.source_facts.write`
- **WHEN** it reports a source fact
- **THEN** the request SHALL be refused
- **AND** nothing SHALL be written
