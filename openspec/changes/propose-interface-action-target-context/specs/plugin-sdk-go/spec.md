## ADDED Requirements

### Requirement: Go SDK exposes enriched interface action target context
The Go plugin SDK SHALL expose typed helpers for interface-scoped northbound action target context, including canonical interface identity, IF-MIB/display fields, and optional physical-location metadata.

The SDK SHALL preserve backward compatibility for existing action plugins that only read device context or interface name fields.

#### Scenario: Go plugin reads interface ifIndex and physical location
- **GIVEN** a Go Wasm plugin receives an interface action invocation
- **WHEN** it decodes the target snapshot with the SDK
- **THEN** it SHALL be able to read `interface.if_index` when present
- **AND** it SHALL be able to read optional physical-location fields when present
- **AND** absent optional fields SHALL decode as empty/optional values rather than string `"nil"`
