## ADDED Requirements

### Requirement: SRQL Flow Filter By Application
SRQL `in:flows` queries SHALL support filtering by derived application label using `app:<value>`.

#### Scenario: Filter flows to a specific application
- **WHEN** a user runs `in:flows time:last_1h app:https sort:time:desc limit:50`
- **THEN** the query returns only flows whose derived application label matches `https`

### Requirement: SRQL Flow Stats Grouped By Application
SRQL `in:flows` queries SHALL support `stats` group-by on the derived application label.

#### Scenario: Aggregate bytes by application
- **WHEN** a user runs `in:flows time:last_1h stats:"sum(bytes_total) as bytes by app" sort:bytes:desc limit:8`
- **THEN** the query returns one row per application label with aggregated bytes

