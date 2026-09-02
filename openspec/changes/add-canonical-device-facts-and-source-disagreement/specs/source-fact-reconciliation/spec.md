## ADDED Requirements

### Requirement: Generic per-source inventory facts
The system SHALL record normalized inventory facts per canonical device, discovery source, and source instance for a platform-owned fact vocabulary. The initial keys SHALL be `switch_port_attachment` and `vlan_uid`. Built-in integrations and inventory plugins SHALL write the same keys. A new source that emits those keys SHALL participate in comparison without a core provider module.

#### Scenario: Two sources record the same fact key independently
- **GIVEN** Armis reports switch-port `niadcs-bldd03-asw001:gi1/3` for device `sr:01b95a66-67dd-41db-9286-358d11e2a7b6`
- **AND** OpenText NOM reports switch-port hostname `niadcs-bldd03-asw001` and port `gi1/3` for the same canonical device
- **WHEN** both observations are present
- **THEN** the system SHALL store one fact row per source for `switch_port_attachment`
- **AND** both rows SHALL reference the same canonical device uid

#### Scenario: Unknown fact keys are ignored
- **WHEN** a source emits a fact key that is not in the platform vocabulary
- **THEN** the system SHALL ignore that key
- **AND** it SHALL NOT fail the inventory snapshot

### Requirement: Generic source-fact disagreement diagnostics
The system SHALL detect when two or more present sources report different normalized values for the same fact key on the same canonical device. It SHALL upsert a durable diagnostic row that remains until the disagreement clears or an operator dismisses it. The diagnostic SHALL NOT use `platform.source_identity_conflicts` and SHALL NOT withhold northbound identity updates.

#### Scenario: Armis and NNMi disagree on access port
- **GIVEN** Armis reports port `gi1/3` on `niadcs-bldd03-asw001`
- **AND** OpenText NOM / NNMi reports port `3/1/28` on a different or same switch for the same device
- **WHEN** both facts are present and normalized values differ
- **THEN** the system SHALL open a `switch_port_attachment` disagreement for that device
- **AND** the row SHALL include each source, instance, and normalized value

#### Scenario: Identical snapshots do not duplicate disagreements
- **GIVEN** an open disagreement already exists for a device and fact key
- **WHEN** a later snapshot reports the same normalized values
- **THEN** the system SHALL NOT insert a second open row
- **AND** it MAY refresh `last_detected_at`

#### Scenario: Disagreement clears when sources agree or one drops out
- **GIVEN** an open `vlan_uid` disagreement
- **WHEN** remaining present sources agree, or only one present source still reports the fact
- **THEN** the diagnostic SHALL be marked cleared
- **AND** identity-conflict tables SHALL remain unchanged

### Requirement: Disagreement events and report
The system SHALL emit an OCSF event when a source-fact disagreement opens, when its compared values change, or when it clears. The system SHALL expose a queryable report of disagreements that reads the durable diagnostic table rather than the retention-bounded event log.

#### Scenario: Event on new disagreement
- **WHEN** a `switch_port_attachment` disagreement is first opened
- **THEN** the tenant `ocsf_events` table SHALL include one event naming the device, fact key, and disagreeing sources

#### Scenario: No event on unchanged snapshot
- **GIVEN** an open disagreement whose values have not changed
- **WHEN** another inventory snapshot is ingested
- **THEN** the system SHALL NOT emit another disagreement event

#### Scenario: Report lists open disagreements
- **WHEN** an authorized operator queries the source-fact disagreement report
- **THEN** the results SHALL include device uid, hostname, fact key, source values, status, and configured authority
- **AND** cleared rows SHALL be filterable rather than deleted

### Requirement: Operator-selected fact authority
The system SHALL let operators choose which integration source or plugin assignment wins for each platform fact key. Authority SHALL be stored in a platform catalog that can reference built-in integration sources, plugin inventory assignments or instances, and optional source-type defaults. Plugin packages MUST NOT declare winners, precedence, or authority. When no authority applies and sources disagree, canonical device fields SHALL be left unchanged.

#### Scenario: Operator marks OpenText NOM as switch-port winner
- **GIVEN** Armis and OpenText NOM disagree on `switch_port_attachment`
- **AND** the operator marked the OpenText NOM assignment as the winner for that fact
- **WHEN** promotion runs
- **THEN** canonical `switch_port_attachment` SHALL use the OpenText NOM value
- **AND** the disagreement SHALL remain visible

#### Scenario: No winner configured does not clobber canonical
- **GIVEN** canonical `vlan_uid` is `561` from Armis
- **AND** OpenText NOM later reports a different VLAN id
- **AND** no authority is configured for `vlan_uid`
- **WHEN** promotion runs
- **THEN** `vlan_uid` SHALL remain `561`
- **AND** a disagreement SHALL be opened

#### Scenario: Two winners is a configuration conflict
- **GIVEN** both the Armis integration source and the OpenText NOM assignment are marked as winners for `switch_port_attachment`
- **WHEN** those sources disagree
- **THEN** canonical attachment SHALL NOT change
- **AND** the disagreement SHALL record a configuration conflict

#### Scenario: Plugin manifest cannot claim authority
- **WHEN** a plugin package declares a winner, precedence, or authority field
- **THEN** import or catalog validation SHALL reject that descriptor
- **AND** runtime comparison SHALL ignore any such claim if it were present
