## ADDED Requirements

### Requirement: Canonical switch-port attachment field
The system SHALL persist a canonical `switch_port_attachment` JSONB object on `ocsf_devices` for the winning access-switch attachment of a device. The object SHALL include `switch_hostname`, `port`, `source`, `source_instance`, and `observed_at`, and MAY include `switch_device_uid`, `if_alias`, `vlan_id`, `vlan_name`, and `raw`. Source-prefixed metadata keys SHALL remain the source-native record and SHALL NOT be deleted when the canonical field is written.

#### Scenario: Armis attachment is promoted without dropping metadata
- **GIVEN** a device whose metadata includes `armis_access_switch` = `niadcs-bldd03-asw001:gi1/3`
- **AND** no other present source reports a disagreeing switch-port attachment
- **WHEN** fact promotion runs
- **THEN** `ocsf_devices.switch_port_attachment.switch_hostname` SHALL be `niadcs-bldd03-asw001`
- **AND** `ocsf_devices.switch_port_attachment.port` SHALL be `gi1/3`
- **AND** `ocsf_devices.switch_port_attachment.source` SHALL be `armis`
- **AND** `metadata.armis_access_switch` SHALL still equal `niadcs-bldd03-asw001:gi1/3`

#### Scenario: Endpoint NIC inventory is not switch attachment
- **GIVEN** a device with `network_interfaces` populated and no switch-port fact
- **WHEN** canonical attachment is computed
- **THEN** `switch_port_attachment` SHALL remain empty
- **AND** NIC inventory SHALL NOT be copied into `switch_port_attachment`

### Requirement: Canonical VLAN identifier from source facts
The system SHALL populate `ocsf_devices.vlan_uid` from the winning VLAN fact when that fact is a stable VLAN identifier. Source-prefixed VLAN metadata such as `metadata.armis_vlans` SHALL be retained. VLAN names that are not identifiers SHALL be stored on `switch_port_attachment.vlan_name` and SHALL NOT overwrite `vlan_uid`.

#### Scenario: Armis VLAN array promotes to vlan_uid
- **GIVEN** a device whose metadata includes `armis_vlans` = `[561]`
- **AND** no other present source reports a disagreeing VLAN identifier
- **WHEN** fact promotion runs
- **THEN** `ocsf_devices.vlan_uid` SHALL be `561`
- **AND** `metadata.armis_vlans` SHALL still equal `[561]`

#### Scenario: Named VLAN does not clobber vlan_uid
- **GIVEN** a source reports VLAN name `DMZnonPCI-BE_FW_10.176.3.64/28` and no numeric VLAN id
- **WHEN** fact promotion runs
- **THEN** `switch_port_attachment.vlan_name` MAY be set
- **AND** `vlan_uid` SHALL NOT be replaced with that name
