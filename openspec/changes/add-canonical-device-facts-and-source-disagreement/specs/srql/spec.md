## ADDED Requirements

### Requirement: Canonical attachment and VLAN are SRQL-queryable
SRQL `in:devices` SHALL expose canonical `vlan_uid` and `switch_port_attachment` (including nested `switch_hostname` and `port`) in addition to existing source-prefixed metadata queries.

#### Scenario: Query canonical switch hostname
- **WHEN** a client runs `in:devices switch_port_attachment.switch_hostname:niadcs-bldd03-asw001`
- **THEN** SRQL SHALL return devices whose canonical attachment hostname matches
- **AND** devices that only have unmatched `metadata.armis_access_switch` SHALL NOT be required to match this field until promotion has run

#### Scenario: Existing Armis metadata query still works
- **WHEN** a client runs `in:devices metadata.armis_access_switch:"%:%"`
- **THEN** SRQL SHALL continue to return devices with that metadata key

### Requirement: Source-fact disagreement report query
SRQL SHALL expose open and historical source-fact disagreements as a first-class query stream with device identity, fact key, source values, status, and authority.

#### Scenario: List open attachment disagreements
- **WHEN** a client queries the source-fact disagreement stream for `fact_key:switch_port_attachment status:open`
- **THEN** each row SHALL identify the canonical device and each disagreeing source value
- **AND** the query SHALL read durable diagnostics, not only retained `ocsf_events`
