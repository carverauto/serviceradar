## ADDED Requirements

### Requirement: Armis attachment metadata also emits canonical facts
The Armis sync integration SHALL continue to persist selected attachment fields under stable `armis_*` metadata keys and SHALL also emit platform facts `switch_port_attachment` and `vlan_uid` from those values when they can be parsed. Parsing SHALL split `armis_access_switch` on the last colon into hostname and port, and SHALL read a VLAN identifier from `armis_vlan` or `armis_vlans` when present.

#### Scenario: Existing Armis switchport string becomes a fact
- **GIVEN** an Armis payload maps to metadata `armis_access_switch` = `nordcs-idfltc-asw001:1/1/41`
- **WHEN** the sync update is ingested
- **THEN** metadata SHALL still contain `armis_access_switch`
- **AND** a `switch_port_attachment` fact SHALL be recorded with hostname `nordcs-idfltc-asw001` and port `1/1/41`

#### Scenario: Existing Armis VLAN metadata becomes a vlan_uid fact
- **GIVEN** an Armis payload maps to metadata `armis_vlans` = `[561]`
- **WHEN** the sync update is ingested
- **THEN** metadata SHALL still contain `armis_vlans`
- **AND** a `vlan_uid` fact SHALL be recorded with value `561`
