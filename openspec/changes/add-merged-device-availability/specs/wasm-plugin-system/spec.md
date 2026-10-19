## ADDED Requirements

### Requirement: Plugins Declare Availability Authority
A plugin that reports device availability in discovery records SHALL declare its availability authority class in its package manifest, and core SHALL use that declaration, lowered by the plugin assignment's configuration when set, as the class of the plugin's availability evidence.
A plugin that reports availability without declaring a class SHALL have its evidence treated as `inventory_declared`. A discovery record SHALL NOT carry its own authority class; the class SHALL derive solely from the manifest and the assignment-level lowering.

#### Scenario: Hypervisor plugin declares managing controller
- **GIVEN** a plugin manifest that declares availability authority `managing_controller`
- **WHEN** the plugin reports a guest as running
- **THEN** core SHALL record `managing_controller` evidence `up` for that guest's device

#### Scenario: Undeclared plugin
- **GIVEN** a plugin whose manifest declares no availability authority
- **WHEN** the plugin reports `is_available` for a device
- **THEN** core SHALL record the evidence as `inventory_declared`

#### Scenario: Plugin omits availability
- **GIVEN** a plugin discovery record with no `is_available` value
- **WHEN** core ingests the record
- **THEN** core SHALL NOT record availability evidence for that device from that plugin
