# Change: Add Proxmox guest network identity

## Why
Proxmox guest enrichment currently stores guest network evidence mostly inside metadata, which prevents reliable IP/MAC-based device reconciliation and leaves guest inventory incomplete.

## What Changes
- Extract QEMU and LXC guest network interfaces from Proxmox config and guest-agent APIs.
- Persist guest NIC MAC/IP/bridge/VLAN data as structured virtualization inventory.
- Use MAC/IP evidence to link Proxmox guests to canonical inventory devices.
- Ensure the first-party Proxmox plugin package sync publishes the token-aware artifact and schema.

## Impact
- Affected specs: device-inventory, proxmox-integration-plugin
- Affected code: Proxmox Wasm plugin, core Proxmox enrichment ingestor, virtualization schema/resources, first-party plugin artifact sync
