# Change: Add layered topology evidence for virtual and logical devices

## Why
The current topology pipeline is still biased toward physical L2 adjacency. That works for devices with strong LLDP/CDP/controller uplink evidence, but it breaks down for virtual routers, hypervisor-hosted appliances, and logical overlays. In practice this causes two carrier-grade failures:

- weak `snmp-arp-fdb` observations get asked to explain topology they cannot prove
- virtual routers such as vJunos disappear entirely unless they accidentally emit strong physical-neighbor evidence

We need a topology contract that distinguishes physical connectivity from logical peering and hosting relationships, so discovery can stay recursive without promoting weak observations into fabricated backbone edges.

## What Changes
- Add a formal topology evidence hierarchy that separates physical, logical, hosted, inferred-segment, and observational evidence classes.
- Add first-class layered topology relations for hosted virtualization and logical peer adjacency rather than forcing those devices through `CONNECTS_TO`.
- Require mapper recursion and canonical promotion rules to use topology eligibility based on strong evidence, not raw ARP/FDB sightings.
- Define how virtual routers and other discovered devices behave when inventory exists but strong placement evidence does not: they remain visible as discovered but unplaced.
- Extend the topology surface so physical backbone, logical/overlay relationships, hosted relationships, and unplaced discovered devices can be rendered without polluting each other.
- Add a virtualization-source path for authoritative hosted relationships, with Proxmox-first support and an extensible contract for other hypervisors/controllers.

## Impact
- Affected specs:
  - `network-discovery`
  - `age-graph`
  - `build-web-ui`
- Affected code:
  - `go/pkg/mapper/discovery.go`
  - `go/pkg/mapper/snmp_polling.go`
  - `go/pkg/mapper/ubnt_poller.go`
  - `go/pkg/mapper/mikrotik_poller.go`
  - new virtualization/topology collectors under `go/pkg/mapper/`
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex`
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_graph.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/runtime_graph.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - `elixir/web-ng/assets/js/lib/god_view/*`

## Non-Goals
- Reconstruct every virtual-switch fabric or bridge domain in this change.
- Infer virtual-router placement from ARP/FDB alone.
- Replace the existing renderer in this change.
- Deliver full parity for every hypervisor/controller in the first iteration; the contract must support more sources, but the first implementation can land with Proxmox and existing logical-peer sources.

## Dependencies
- Builds on `improve-mapper-topology-fidelity` for stronger mapper evidence normalization.
- Complements `refactor-topology-read-model-for-carrier-scale` by supplying a carrier-grade topology contract for virtual/logical devices instead of relying on UI-side heuristics.
