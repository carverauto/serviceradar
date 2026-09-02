## ADDED Requirements

### Requirement: Inventory plugins emit platform facts without claiming authority
An inventory plugin MAY emit platform fact keys such as `switch_port_attachment` and `vlan_uid` on discovered devices, and MAY persist source-prefixed metadata for the same evidence. A plugin package MUST NOT declare that it wins conflicts, ranks sources, or is authoritative. Optional `emitted_facts` in the package descriptor is an advertisement only; core SHALL also infer keys from observed facts.

#### Scenario: OpenText NOM reports an NNMi attached switch port as a fact
- **GIVEN** NNMi attached-switch-port lookup returns switch hostname `SITE01-IDFC08-ASW002` and port `3/1/28` for an endpoint already in ServiceRadar
- **WHEN** the OpenText NOM plugin emits the device
- **THEN** the discovery record SHALL include a `switch_port_attachment` fact with that hostname and port
- **AND** source-prefixed metadata MAY include the raw NNMi values
- **AND** the package SHALL NOT include a winner or precedence field

#### Scenario: Manifest winner claim is rejected
- **WHEN** a signed package descriptor includes a fact-authority, precedence, or winner declaration
- **THEN** import or catalog validation SHALL fail
- **AND** the package SHALL NOT be approved

### Requirement: Optional NNMi L2 pass uses ServiceRadar endpoints
When an OpenText NOM assignment includes `nnm_url`, the plugin MAY collect attached switch ports from NNMi using endpoint MAC or IP values already known to ServiceRadar. It MUST NOT query attached switch ports by iterating Network Automation switch inventory addresses. When `nnm_url` is omitted, collection SHALL be inventory-only.

#### Scenario: NNMi pass is skipped without nnm_url
- **GIVEN** plugin configuration has `api_url` and no `nnm_url`
- **WHEN** inventory collection runs
- **THEN** the plugin SHALL collect Network Automation `list device` inventory
- **AND** it SHALL NOT call NNMi attached-switch-port

#### Scenario: NNMi pass looks up endpoints not switches
- **GIVEN** `nnm_url` is configured
- **AND** ServiceRadar has an endpoint MAC `B8:A4:4F:82:EF:F9`
- **WHEN** the optional L2 pass runs
- **THEN** the plugin SHALL query NNMi with the separator-free uppercase MAC
- **AND** it SHALL NOT use Network Automation switch IPs as the lookup key
- **AND** an empty NNMi items list SHALL be treated as no match rather than a failed snapshot
