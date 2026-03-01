## Context
Current enrichment quality depends on partial SNMP signals and inconsistent vendor-specific behavior. Standard MIB data already available in field captures can support stronger classification and topology inference if normalized once in mapper and consumed consistently downstream.

## Goals
- Build a deterministic SNMP fingerprint model that is transport- and vendor-agnostic.
- Improve role inference and enrichment accuracy for routers, switches, AP/bridges.
- Emit topology links with confidence and idempotent graph behavior.
- Preserve discovery capability while reducing duplicate/misclassified devices.

## Non-Goals
- Full SNMP MIB database ingestion for all vendor private branches.
- Trap parser redesign.
- Replacing current enrichment rule engine.

## Decisions
### Decision: Introduce a canonical `snmp_fingerprint` payload fragment
Mapper publishes a normalized object containing stable fields from standard OIDs:
- system: `sys_name`, `sys_descr`, `sys_object_id`, `sys_owner` (`sysContact`), `sys_location`, `ip_forwarding`
- bridge: `bridge_base_mac`, `bridge_port_count`, `stp_forwarding_port_count`
- vlan: `vlan_ids_seen`, `pvid_distribution`, `vlan_port_evidence`
- interface summary: counts by ifType and selected interface-name patterns

Rationale: this gives core-enrichment one stable input shape independent of parser internals.

### Decision: Topology links require confidence tiering
Topology candidates are scored:
- `high`: direct LLDP/CDP neighbor match or bridge evidence with unique remote MAC+port mapping
- `medium`: bridge/FDB evidence with ambiguous remote mapping but consistent over repeated sightings
- `low`: single-sighting indirect inference

Only `high` and `medium` are projected to AGE by default; `low` stays as candidate evidence.

### Decision: Inventory presentation prefers enriched fields with SNMP fallback
Device details and list fallback order:
- Vendor/model/type from enrichment result
- If missing, render SNMP-derived fallback (for example from `sys_descr` and `sys_object_id` mapping) with provenance badge

### Decision: AP/bridge vs router alias behavior remains role-driven
Alias promotion behavior remains governed by role inference from the existing DIRE hardening track, but this change provides stronger SNMP fingerprint inputs to that inference.

## Risks and Mitigations
- Risk: Additional SNMP walks increase scan latency.
  - Mitigation: Bound OID set, short per-table timeouts, and partial-result semantics.
- Risk: Graph noise from uncertain bridge inferences.
  - Mitigation: Confidence gating and repeated-sighting threshold for medium-confidence links.
- Risk: Vendor drift in `sysDescr` strings.
  - Mitigation: Keep inference signal-first (`ipForwarding`, bridge/VLAN evidence) and treat string parsing as secondary.

## Rollout
1. Add mapper fingerprint payload fields behind a feature flag.
2. Enable core ingestion and store signals without changing classification decisions.
3. Switch enrichment/role inference to fingerprint-backed inputs.
4. Enable topology confidence gating and AGE projection updates.
5. Remove legacy fallback paths once parity is validated in demo.
