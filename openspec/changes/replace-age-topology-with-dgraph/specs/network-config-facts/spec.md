## ADDED Requirements

### Requirement: Config revisions live in CNPG
The system SHALL persist retrieved device configurations as Ash-backed `network_config_revisions` rows in the `platform` schema, including device uid, source, config kind, retrieval time, content hash, and body.

#### Scenario: Running-config revision is stored
- **WHEN** a collector submits a running-config for a canonical device
- **THEN** a `network_config_revisions` row is created with `config_kind=running`
- **AND** the content hash is stored
- **AND** the body is not written as a Dgraph predicate

#### Scenario: Duplicate hash is idempotent
- **WHEN** the same device submits a body whose hash matches the latest revision
- **THEN** no additional revision row is required
- **AND** parsed facts are not rebuilt

### Requirement: Parsed interface facts live in CNPG
The system SHALL parse config revisions into Ash-backed `network_config_interface_facts` and SHALL NOT treat the parser output as the topology graph.

#### Scenario: Interface stanza becomes a fact row
- **GIVEN** a revision whose body contains an invented IOS-like interface stanza with a name and IPv4 prefix
- **WHEN** the downparser runs
- **THEN** one fact row exists for that `(revision_id, if_name)`
- **AND** the IPv4 prefix, description, VLAN, and shutdown flag are populated when present in the stanza

#### Scenario: Facts feed the graph projector
- **WHEN** interface facts are written
- **THEN** the topology projector is invoked with `ingestor=network_config_v1`
- **AND** Dgraph receives Prefix and Interface updates
- **AND** the fact rows remain the rebuild source

### Requirement: Collector does not parse
The system SHALL retrieve configuration through a plugin action that submits the body as an artifact and SHALL parse that body in core, not inside the Wasm plugin.

#### Scenario: OpenText action submits a body
- **WHEN** the OpenText config-retrieve action succeeds
- **THEN** core receives an artifact result containing the config body
- **AND** the plugin has not emitted interface facts or topology edges

### Requirement: Synthetic config fixtures
The system SHALL use invented configuration text in tests and docs; captured live Network Automation configs SHALL NOT enter the repository.

#### Scenario: Parser fixture is invented
- **WHEN** a downparser unit test loads a config body
- **THEN** hostnames, addresses, and site identifiers are documentation or reserved values
- **AND** the body is not an export from a running OpenText instance
