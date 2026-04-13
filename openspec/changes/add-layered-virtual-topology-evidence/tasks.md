## 1. Evidence Contract
- [x] 1.1 Add the formal topology evidence hierarchy (`direct-physical`, `direct-logical`, `hosted-virtual`, `inferred-segment`, `observed-only`) to mapper normalization and core ingestion.
- [x] 1.2 Define the relation-family mapping (`CONNECTS_TO`, `LOGICAL_PEER`, `HOSTED_ON`, `ATTACHED_TO`, `OBSERVED_TO`) and add contract tests for promotion boundaries.
- [x] 1.3 Update recursive discovery eligibility so only topology-eligible strong evidence expands the target set.

## 2. Collector and Mapper Sources
- [x] 2.1 Preserve and normalize strong physical evidence from LLDP/CDP and authoritative controller uplinks.
- [x] 2.2 Add first-class logical-peer evidence handling for existing strong sources such as WireGuard and prepare the collector contract for BGP/OSPF/IPsec.
- [x] 2.3 Add a first authoritative hosted-virtual source path, starting with Proxmox host/guest inventory and topology facts.

## 3. Core Projection and Inventory Semantics
- [x] 3.1 Project layered canonical relations into AGE without forcing logical or hosted devices through physical `CONNECTS_TO`.
- [x] 3.2 Keep virtual routers and managed appliances visible as discovered-but-unplaced when no strong placement evidence exists.
- [ ] 3.3 Ensure weak `snmp-arp-fdb` or other observational evidence cannot promote virtual devices into the physical backbone.

## 4. Topology UI
- [ ] 4.1 Extend the topology read model to expose physical, logical, hosted, and unplaced layers explicitly.
- [ ] 4.2 Render physical backbone as the default operational view while allowing logical/hosted relationships to be toggled or overlaid without polluting the physical graph.
- [x] 4.3 Show discovered-but-unplaced devices in an explicit operator-visible state instead of hiding them or fabricating edges.

## 5. Verification
- [ ] 5.1 Add regression fixtures covering virtual routers, hosted appliances, controller-derived uplinks, and weak ARP/FDB noise.
- [ ] 5.2 Validate representative demo topologies where MikroTik remains connected via strong evidence and vJunos appears as hosted, logical, or unplaced instead of disappearing.
- [x] 5.3 Run `openspec validate add-layered-virtual-topology-evidence --strict`.
