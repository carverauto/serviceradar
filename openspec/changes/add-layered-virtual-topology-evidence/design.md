## Context
The current topology model effectively has one operator-facing relation: physical-looking adjacency. That is enough for LLDP/CDP-discovered switches and for some controller-derived uplinks, but it is not enough for virtual routers, hosted network appliances, or overlay links.

In demo, MikroTik appears because it has a stronger source path and more authoritative identity/topology data. vJunos does not appear because it has inventory identity but no topology evidence strong enough to survive the current promotion rules. When weak ARP/FDB observations are allowed to fill the gap, the result is worse: fabricated L2 placement, endpoint explosions, and polluted backbone edges.

Carrier-grade behavior requires a layered contract:
- physical transport adjacency
- logical or overlay peering
- hosted virtualization placement
- inferred segment attachment
- observed-only evidence

## Goals / Non-Goals
- Goals:
  - Preserve recursive discovery without allowing weak endpoint observations to drive topology expansion.
  - Model virtual routers and hosted appliances without pretending they are physical-switch neighbors.
  - Keep strong physical topology visible and trustworthy.
  - Surface discovered-but-unplaced virtual devices explicitly instead of hiding them or inventing edges.
  - Make the UI capable of rendering physical, logical, and hosted relationships without mixing their semantics.
- Non-Goals:
  - Full digital-twin modeling of every hypervisor bridge and VLAN.
  - Promoting ARP/FDB-only observations into physical backbone placement for virtual devices.
  - Rewriting all existing mapper sources before the new contract can land.

## Decisions

### Decision: Formalize evidence classes
Every topology observation will normalize into one of these evidence classes:
- `direct-physical`
- `direct-logical`
- `hosted-virtual`
- `inferred-segment`
- `observed-only`

`direct-physical` is for topology strong enough to place devices in the physical backbone, such as LLDP/CDP and authoritative controller uplinks.

`direct-logical` is for overlay or routed relationships such as WireGuard and future BGP/OSPF/IPsec evidence.

`hosted-virtual` is for authoritative host/guest placement, such as Proxmox saying VM X runs on host Y.

`inferred-segment` is for switch/router segment inference that may be useful for endpoint visibility but is not sufficient to place virtual devices in the physical backbone by itself.

`observed-only` is for low-confidence or one-sided evidence that should remain available for diagnostics and later reconciliation but must not become operator-facing topology by default.

### Decision: Promote relations by family, not by a single universal edge type
Canonical topology will distinguish at least these operator-facing relation families:
- `CONNECTS_TO` for physical adjacency
- `LOGICAL_PEER` for overlay or routed adjacency
- `HOSTED_ON` for host/guest placement
- `ATTACHED_TO` for endpoint or segment attachment
- `OBSERVED_TO` for diagnostic-only observations

This avoids forcing virtual routers through `CONNECTS_TO` when the evidence is actually logical or hosted.

### Decision: Strong-evidence recursion remains enabled
Recursive discovery remains a core product behavior. The recursion boundary changes from “any discovered target” to “topology-eligible discovered target”.

Recursion is allowed through:
- `direct-physical`
- `direct-logical`
- `hosted-virtual` where the collector can interrogate the host or guest usefully

Recursion is not allowed through:
- `candidate_only`
- `observed-only`
- `inferred-segment` links derived only from weak ARP/FDB identity
- endpoint attachments

### Decision: Virtual routers without strong placement stay visible as unplaced
If a device is confidently identified as a router, firewall, or managed network appliance but lacks strong physical/logical/hosted evidence, the system keeps it in inventory and allows the topology UI to show it as discovered but unplaced.

Consequences:
- Operators do not lose awareness of the device.
- The platform does not fabricate a physical edge to “make the graph look complete”.

### Decision: Layered UI rendering is required
The topology UI must be able to render physical backbone, logical peers, hosted relationships, and unplaced discovered devices as separate semantics. The default operational view remains physical-first, but logical and hosted layers must be available without corrupting the physical topology contract.

## Risks / Trade-offs
- Adding relation families increases complexity in ingestion and rendering.
  Mitigation: keep the evidence hierarchy explicit and central, and keep relation-family mapping in core rather than spreading heuristics across the UI.
- Some environments will still lack authoritative virtualization or logical-peer data.
  Mitigation: expose unplaced discovered devices and diagnostics instead of inventing placement.
- Controller uplinks can be partially authoritative.
  Mitigation: normalize them into explicit evidence classes with source-specific rules rather than treating all controller data as equally strong.

## Migration Plan
1. Introduce the evidence hierarchy in mapper normalization and core ingestion.
2. Add canonical relation-family projection for `LOGICAL_PEER`, `HOSTED_ON`, and stricter `ATTACHED_TO`/`OBSERVED_TO`.
3. Update recursive discovery to follow topology-eligible strong evidence only.
4. Add a first authoritative hosted-virtual collector path, starting with Proxmox.
5. Update the topology read model and UI to render layered relations plus an unplaced lane/panel for discovered-but-unplaced devices.
6. Validate demo cases:
   - MikroTik remains visible through strong evidence.
   - vJunos appears as hosted, logical, or unplaced, but never as a fabricated physical neighbor.
   - weak ARP/FDB noise cannot create large false endpoint groups or backbone edges.

## Open Questions
- Which initial logical-peer collectors should land in the first implementation after WireGuard: BGP, OSPF, IPsec, or all three?
- Should the topology UI surface unplaced devices in-canvas, in a side panel, or both?
- For Proxmox-first support, do we want a dedicated mapper source or a shared virtualization collector interface from the start?
