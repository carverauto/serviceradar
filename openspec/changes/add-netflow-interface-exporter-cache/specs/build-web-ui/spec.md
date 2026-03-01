## ADDED Requirements

### Requirement: NetFlow Visualize dimension picker includes exporter/interface dimensions

The NetFlow Visualize dimension picker SHALL include exporter and interface metadata dimensions when available from SRQL.

#### Scenario: User selects an interface dimension
- **GIVEN** the user is on `/netflow`
- **WHEN** they add `in_if_name` to the dimensions list
- **THEN** the selected chart uses SRQL series/group-by based on `in_if_name`

