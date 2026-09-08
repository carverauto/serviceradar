## ADDED Requirements
### Requirement: BMP events SRQL entity
SRQL SHALL support a `bmp_events` entity that queries raw BMP routing telemetry from `platform.bmp_routing_events`.

#### Scenario: Query recent BMP events
- **GIVEN** BMP routing rows exist in `platform.bmp_routing_events`
- **WHEN** a client sends `in:bmp_events time:last_15m sort:time:desc limit:50`
- **THEN** SRQL SHALL return rows from `platform.bmp_routing_events`
- **AND** results SHALL be ordered and paginated according to query parameters

### Requirement: BMP routing filters in SRQL
SRQL `in:bmp_events` queries SHALL support routing-oriented filters including `event_type`, `severity_id`, `router_ip`, `peer_ip`, and `prefix`.

#### Scenario: Filter by router and peer
- **GIVEN** BMP events exist for multiple routers and peers
- **WHEN** a client sends `in:bmp_events router_ip:10.42.68.85 peer_ip:10.0.2.4 time:last_1h`
- **THEN** SRQL SHALL return only rows matching both router and peer filters

#### Scenario: Filter by prefix and event type
- **GIVEN** BMP events include mixed event types and prefixes
- **WHEN** a client sends `in:bmp_events event_type:route_withdraw prefix:10.43.0.0/16 time:last_24h`
- **THEN** SRQL SHALL return only matching withdraw events for that prefix

### Requirement: BMP events metadata exposure
SRQL `in:bmp_events` responses SHALL expose raw-routing context needed by observability workflows, including routing metadata and stable event identity.

#### Scenario: Response contains correlation-ready fields
- **GIVEN** a BMP routing row includes metadata with event identity and topology keys
- **WHEN** SRQL returns `in:bmp_events` results
- **THEN** the response SHALL include fields required for correlation and drill-through
- **AND** those fields SHALL be usable alongside promoted `in:events` workflows
