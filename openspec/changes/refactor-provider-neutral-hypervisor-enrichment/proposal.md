# Change: Refactor provider-neutral hypervisor enrichment

## Why
The first Proxmox implementation proves out hypervisor inventory, guest networking, and console access, but too much provider-specific logic will make vSphere/vCenter duplicate parsing, identity linking, UI summaries, and console routing.

## What Changes
- Define a provider-neutral hypervisor enrichment contract for hosts, clusters, datastores, guests, NICs, disks, storage systems, and environmentals.
- Move shared guest MAC/IP identity resolution out of Proxmox-specific ingestion code.
- Keep Proxmox and future vSphere/vCenter collectors as adapters that emit the shared contract.
- Define an edge remote-console substrate that routes browser sessions through web-ng, agent-gateway, and the selected agent into segmented/remote networks.
- Treat hypervisor console targets as one consumer of the shared remote-console substrate, not as the owner of the console/xterm implementation.
- Rename or wrap Proxmox-specific service, module, and API concepts where they are actually hypervisor-wide concerns.
- Keep provider-specific UI limited to labels, badges, detail panels, and adapter-specific actions.
- Add tests that prove Proxmox and a synthetic second provider can ingest the same shared inventory envelope.

## Impact
- Affected specs: device-inventory, edge-architecture, wasm-plugin-system
- Affected code: virtualization inventory ingestors, plugin SDK/result schemas, Proxmox plugin adapter, generic remote-console routing, console/xterm UI, device detail virtualization UI
