## ADDED Requirements
### Requirement: God-View node detail card shows node identity and network context
The God-View deck.gl node-detail surfaces (click selection card and node tooltip) SHALL render node identity and network context from the topology payload when those fields are present, including `id`, `ip`, `type`, `vendor`, `model`, `last_seen`, `asn`, and geographic location fields.

#### Scenario: Node detail card includes IP and metadata
- **GIVEN** a God-View node payload includes `details.ip` and other metadata fields
- **WHEN** an operator clicks that node in the deck.gl canvas
- **THEN** the node detail card SHALL display the node IP address and available metadata values
- **AND** the tooltip for that same node SHALL show the same IP/type context

#### Scenario: Missing fields render explicit fallback values
- **GIVEN** a God-View node payload is missing one or more detail metadata fields
- **WHEN** an operator opens node details from the deck.gl canvas
- **THEN** the node detail card SHALL remain visible
- **AND** each missing field SHALL render an explicit fallback value (for example `unknown` or `—`) rather than rendering blank/undefined content

#### Scenario: Regression coverage for detail metadata mapping
- **GIVEN** automated God-View frontend tests are executed
- **WHEN** node-detail rendering logic is validated
- **THEN** tests SHALL fail if IP or required mapped detail fields are dropped from the rendered detail card for payloads that include those fields
