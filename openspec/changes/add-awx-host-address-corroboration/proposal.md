# Change: Let host-name agreement corroborate an AWX host's exact address match

## Why
An AWX inventory host whose `ansible_host` address equals a live device's address, and whose
name is that device's host name or its short form, stayed a separate record. The AWX holder
lookups refused agent-managed devices with the child-asset claim, and an address match was
accepted only with a Proxmox link or a holder without MACs. "Hostname Agreement Is Not
Identity" forbids merging two existing devices on host-name agreement, so the AWX exception has
to be stated there, narrowly, rather than carved out of the requirement.

## What Changes
- For an AWX inventory host, agreement of the first DNS label of the two host names, ignoring
  case, corroborates an exact match between the `ansible_host` address and the live device
  holding that address. With that corroboration the AWX record merges into that device, which
  survives.
- Host-name agreement alone never identifies an AWX host: it does not merge across different
  addresses, and an address match without it still needs a Proxmox link, an overlapping MAC or
  a holder without MACs.
- A MAC that contradicts the device's MACs refuses the merge.

## Impact
- Affected specs: device-identity-reconciliation
- Affected code: `ServiceRadar.Inventory.DeviceDiscoveryIngestor` (AWX holder lookups),
  `ServiceRadar.Inventory.DeviceClaimPolicy` (`:host_inventory_record` claim type)
