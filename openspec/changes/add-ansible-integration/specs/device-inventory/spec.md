## ADDED Requirements

### Requirement: Ansible-Managed Device Linkage Derived from AWX Inventory

The `Device` resource SHALL gain `ansible_managed` (boolean, default false) and `ansible_inventory_ref` (map: `controller_id`, `inventory_id`, `host_id`, `host_name`). Both attributes SHALL be **derived** from AWX inventory sync, not directly settable via user actions. The `InventorySyncWorker` (defined in the `ansible-integration` capability) SHALL feed AWX host records into DIRE with `discovery_source = "awx"`; DIRE merges them with records from other discovery sources, and the resulting device's `ansible_managed` and `ansible_inventory_ref` SHALL reflect whether the merged record set includes an AWX source. ServiceRadar SHALL NOT push devices into AWX inventory.

#### Scenario: AWX inventory sync sets ansible_managed automatically

- **GIVEN** an AWX inventory whose hosts overlap with existing ServiceRadar devices
- **WHEN** the InventorySyncWorker runs and DIRE merges the AWX records
- **THEN** matching devices SHALL have `ansible_managed = true` and `ansible_inventory_ref` populated, with `awx` added to `discovery_sources`
- **AND** the device detail UI SHALL display the AWX controller, inventory, and host name

#### Scenario: AWX-discovered host overlaps with proxmox-discovered device

- **GIVEN** a device already discovered via the proxmox integration AND the same logical host appearing in AWX inventory (because AWX uses a proxmox community ansible inventory plugin)
- **WHEN** the InventorySyncWorker runs
- **THEN** DIRE SHALL merge the records into a single device with `discovery_sources` containing both `proxmox` and `awx`
- **AND** the device SHALL have proxmox metadata AND `ansible_inventory_ref` populated, without duplicate device records

#### Scenario: AWX host disappears

- **GIVEN** a device linked to an AWX host that has been removed from AWX inventory
- **WHEN** the next InventorySyncWorker pass runs and DIRE no longer sees `awx` as a source for this device
- **THEN** the device SHALL have `ansible_managed = false`
- **AND** `ansible_inventory_ref` SHALL be cleared
- **AND** historical `PlaybookRun` rows referencing the device SHALL be retained for audit

#### Scenario: No manual mark/unmark action exists

- **GIVEN** any operator regardless of permissions
- **WHEN** they view a device detail page
- **THEN** the system SHALL NOT display a "Mark as Ansible-managed" toggle
- **AND** the API SHALL NOT expose a direct write to `ansible_managed` or `ansible_inventory_ref`
