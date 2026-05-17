## ADDED Requirements

### Requirement: Interface action target snapshots expose requested interface context
The agent Wasm runtime SHALL invoke interface-scoped northbound actions with a target snapshot that includes the descriptor-requested device and interface context fields that ServiceRadar has available.

Interface context SHALL include a canonical interface identifier and MAY include `if_index`, `if_name`, `if_descr`, `if_alias`, MAC address, admin status, oper status, speed, MTU, and last-observed timestamps when available. `if_index` SHALL be treated as an SNMP IF-MIB row index, not as a physical port number or chassis/module identifier.

When a descriptor marks a context field as required, ServiceRadar SHALL either provide that field to the plugin or fail only the affected target with a structured missing-context error before plugin execution.

#### Scenario: Interface action receives ifIndex and name
- **GIVEN** an interface-scoped action descriptor requires `device.ip`, `interface.if_name`, and `interface.if_index`
- **AND** the selected interface has both fields available
- **WHEN** ServiceRadar dispatches the action target
- **THEN** the plugin invocation SHALL include `device.ip`, `interface.if_name`, and `interface.if_index`
- **AND** task history SHALL show the provided values without rendering `nil`

#### Scenario: Required ifIndex is missing
- **GIVEN** an interface-scoped action descriptor requires `interface.if_index`
- **AND** the selected interface does not have an IF-MIB index
- **WHEN** ServiceRadar prepares target dispatch
- **THEN** the affected target SHALL fail with a missing-context error
- **AND** ServiceRadar SHALL NOT invoke the plugin for that target

### Requirement: Interface physical location is distinct from ifIndex
ServiceRadar SHALL represent modular or physical interface location separately from SNMP `if_index` when discovery or integration evidence provides that information.

Physical-location context MAY include chassis, slot, module, submodule, port, parent interface, ENTITY-MIB `entPhysicalIndex`, source, confidence, and provenance metadata. ServiceRadar SHALL NOT derive chassis/module/port solely by parsing or truncating `if_index`.

#### Scenario: Modular chassis interface target
- **GIVEN** a Cisco-style interface displayed as `1/1/3`
- **AND** discovery has mapped that interface to chassis `1`, slot `1`, and port `3`
- **WHEN** an interface action target is dispatched
- **THEN** the target snapshot SHALL include the exact interface name
- **AND** the physical-location object SHALL include chassis, slot, and port fields
- **AND** `if_index` SHALL remain the SNMP row index value when known, even if it is not `3`

#### Scenario: No physical location evidence
- **GIVEN** an interface has `if_name` and `if_index` but no ENTITY-MIB or vendor physical-location evidence
- **WHEN** the target snapshot is built
- **THEN** ServiceRadar SHALL omit or null the physical-location object
- **AND** it SHALL NOT infer module or linecard ownership from `if_index`
