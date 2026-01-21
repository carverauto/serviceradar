## ADDED Requirements

### Requirement: Interface classification rules
The system SHALL support rule-based classification of interfaces using persisted rule definitions.

#### Scenario: Rule match on interface fields
- **GIVEN** an enabled rule with an `if_name_pattern` of `^wg`
- **WHEN** an interface named `wgsts1000` is ingested
- **THEN** the interface SHALL be classified with `vpn` and `wireguard`

#### Scenario: Rule match on vendor context
- **GIVEN** a device with `vendor_name = "Ubiquiti"`
- **AND** an interface with `if_descr = "Annapurna Labs Ltd. Gigabit Ethernet Adapter"`
- **WHEN** the interface is ingested
- **THEN** the interface SHALL be classified as `management`

---

### Requirement: Deterministic rule precedence
The system SHALL evaluate classification rules in priority order and apply deterministic conflict resolution.

#### Scenario: Higher priority wins
- **GIVEN** two matching rules with different priorities
- **WHEN** an interface is ingested
- **THEN** the classification output SHALL use the higher-priority rule for mutually exclusive tags

---

### Requirement: Classification persistence
The system SHALL persist interface classifications on the interface record and update them when new data is ingested.

#### Scenario: Interface classification stored
- **GIVEN** a mapper interface ingestion event
- **WHEN** classification rules match
- **THEN** the interface record SHALL store the resulting classifications and metadata

---

### Requirement: Rule CRUD for future UI
The system SHALL expose rule definitions through Ash resources so a UI can manage them later.

#### Scenario: Admin creates a rule
- **GIVEN** an authenticated admin user
- **WHEN** they create an interface classification rule
- **THEN** the rule SHALL be persisted and available for subsequent ingestions
