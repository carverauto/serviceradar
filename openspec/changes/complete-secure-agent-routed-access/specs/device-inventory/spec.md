## ADDED Requirements

### Requirement: Device remote-access actions use registered target and route state
Device details SHALL derive SSH, RDP, and provider-console actions from authoritative registered target, edge affinity, identity, trust, credential, adapter, and actor-policy state instead of operating-system or vendor-name heuristics alone.

#### Scenario: Reachable unclassified Linux host
- **WHEN** a device lacks a recognized Linux OS label but has a ready registered SSH target and the actor is authorized
- **THEN** device details exposes Connect with SSH

#### Scenario: Windows RDP target is ready
- **WHEN** a Windows device has a ready registered RDP target on a selected edge route
- **THEN** device details exposes Connect with RDP separately from the administrative Configure RDP action

#### Scenario: Heuristic match without route
- **WHEN** a device name or OS resembles Linux or Windows but no ready registered target and edge route exist
- **THEN** device details does not expose a connection action based only on the heuristic

### Requirement: Proxmox guest relationships are safe for interactive routing
Inventory SHALL preserve enough provider-instance, parent-host, guest-type, VMID, and canonical-device relationship state to resolve an interactive Proxmox guest console unambiguously. Identity conflicts SHALL remain visible and SHALL block console routing until resolved.

#### Scenario: Guest and IP sighting are fragmented
- **WHEN** a Proxmox guest record and a network sighting cannot be safely reconciled because the sighting lacks stable identity evidence
- **THEN** native PVE console may use the unambiguous guest-parent relationship while generic SSH/RDP requires a separately registered network target

#### Scenario: Multiple guests overmerge
- **WHEN** one canonical device UID is associated with distinct active guest provider references or VMIDs
- **THEN** inventory reports the conflict and remote-console readiness fails closed rather than choosing one guest

#### Scenario: Same PVE node name exists in Farm and Tonka
- **WHEN** two Proxmox provider instances both report a host named `pve02`
- **THEN** inventory stores cluster/provider-instance-scoped host references and does not overwrite one virtualization host with the other
