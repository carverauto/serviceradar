## ADDED Requirements

### Requirement: Fact-authority controls on integration sources and plugin assignments
The operator UI SHALL expose fact-authority controls on built-in integration sources and on plugin inventory assignments or credential rules. The controls SHALL let an operator mark which source wins for `switch_port_attachment` and `vlan_uid` when sources disagree. The controls SHALL write the platform authority catalog and SHALL NOT be generated from plugin-manifest winner fields.

#### Scenario: Armis integration source can be marked VLAN winner
- **GIVEN** an operator edits an Armis integration source
- **WHEN** they select that this source wins for VLAN
- **THEN** the platform authority catalog SHALL record the Armis source as authority for `vlan_uid`
- **AND** the Armis `plugin.yaml` equivalent SHALL NOT be required or consulted

#### Scenario: OpenText NOM assignment can be marked switch-port winner
- **GIVEN** an operator edits the OpenText NOM plugin assignment or credential rule
- **WHEN** they select that this source wins for switch port
- **THEN** the platform authority catalog SHALL record that assignment as authority for `switch_port_attachment`
- **AND** the OpenText NOM package descriptor SHALL NOT contain that choice
