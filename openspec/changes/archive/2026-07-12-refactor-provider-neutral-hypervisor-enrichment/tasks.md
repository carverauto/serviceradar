## 1. Design
- [x] 1.1 Inventory existing Proxmox-specific code paths in plugin output, core ingestion, agent runtime, UI summaries, SRQL views, alert inputs, and console routing.
- [x] 1.2 Define a provider-neutral hypervisor enrichment envelope and adapter responsibilities.
- [x] 1.3 Define common identity precedence for guest MAC/IP/hostname/provider refs.
- [x] 1.4 Define provider-neutral credential rule purposes for inventory enrichment, console access, and future write operations.
- [x] 1.5 Define the generic remote-console tunnel contract for web-ng, agent-gateway, agent, browser xterm, RBAC, credential broker grants, and audit events.

## 2. Implementation
- [x] 2.1 Extract shared hypervisor inventory ingestor functions from the Proxmox ingestor.
- [x] 2.2 Update Proxmox ingestion to emit or translate into the shared envelope without changing operator behavior.
- [x] 2.3 Add a synthetic non-Proxmox provider fixture to prove vSphere/vCenter can reuse the pipeline.
- [x] 2.4 Move console session target selection to generic remote-console target metadata with protocol/provider transport adapters.
- [x] 2.5 Update UI labels and summaries to refer to hypervisors/virtualization generically where the provider is not Proxmox-specific.
- [x] 2.6 Rename or wrap Proxmox-specific agent/runtime interfaces that are actually generic remote-console control streams.
- [x] 2.7 Ensure SRQL/device detail/dashboard/alerting reads from provider-neutral virtualization fields before provider metadata.
- [x] 2.8 Reuse the xterm/webpty React component through a generic remote-console entrypoint, with Proxmox-specific labels/actions supplied as target metadata only.

## 3. Validation
- [x] 3.1 Add focused unit and DB-backed tests for shared hypervisor ingestion.
- [x] 3.2 Run Proxmox regression tests to prove current behavior is preserved.
- [x] 3.3 Add a synthetic vSphere/vCenter-shaped fixture that creates a host, cluster, datastore, VM, NIC, disk, and console target through the shared path.
- [x] 3.4 Add remote-console tunnel tests for a generic SSH target and a Proxmox guest target through the same web-ng to gateway to agent path.
- [x] 3.5 Document the adapter contract for vSphere/vCenter implementation and the reusable remote-console protocol contract.
