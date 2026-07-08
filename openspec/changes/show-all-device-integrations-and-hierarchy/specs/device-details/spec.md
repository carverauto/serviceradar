# Device Details

## ADDED Requirements

### Requirement: Device Details shows all discovery integrations
Device Details SHALL list every integration/source a merged device was discovered
through, not only the canonical source.

#### Scenario: Device discovered by agent, proxmox, and AWX
- **GIVEN** a device DIRE merged from agent, proxmox, and AWX discoveries
- **WHEN** the operator opens Device Details
- **THEN** all three integrations are shown

### Requirement: Guest devices link to their hypervisor
A guest device whose parent hypervisor is known SHALL link to that hypervisor,
and a hypervisor node SHALL show its guests.

#### Scenario: Guest shows its parent hypervisor
- **GIVEN** a proxmox guest whose node is known
- **WHEN** the operator opens the guest's Device Details
- **THEN** a link to the parent hypervisor device is shown
