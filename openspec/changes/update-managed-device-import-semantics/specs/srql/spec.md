## MODIFIED Requirements
### Requirement: Device Query Support
SRQL SHALL support querying device inventory via the `in:devices` stream with filtering, sorting, and pagination. Default `in:devices` queries SHALL return active devices only unless the query explicitly filters `is_active` or sets the inventory control token `include_inactive:true`.

#### Scenario: Query active devices by default
- **WHEN** a user runs `in:devices`
- **THEN** the generated query SHALL exclude devices with `is_active = false`

#### Scenario: Query inactive archival devices explicitly
- **WHEN** a user runs `in:devices is_active:false`
- **THEN** the generated query SHALL return inactive archival devices matching the rest of the query

#### Scenario: Query all lifecycle states for inventory management
- **WHEN** the device inventory uses `in:devices include_inactive:true`
- **THEN** the generated query SHALL include active and inactive device records
- **AND** the `include_inactive` control token SHALL NOT be passed through as a SQL predicate or bind parameter

#### Scenario: Query devices by IP
- **WHEN** a user runs `in:devices ip:192.168.1.1`
- **THEN** the generated query SHALL filter active device records by IP address

#### Scenario: Query devices by type
- **WHEN** a user runs `in:devices type:Router`
- **THEN** the generated query SHALL filter active device records by type
