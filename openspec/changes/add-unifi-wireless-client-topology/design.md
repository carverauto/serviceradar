## Context
The current UniFi mapper path builds infrastructure topology from LLDP tables, port tables, and uplink metadata. It does not emit AP-to-client topology.

Live demo data confirms:
- UniFi APs are present as backbone nodes.
- Recent mapper rows include `unifi-api-uplink` links for AP uplinks.
- Recent mapper rows also include SNMP-L2 switch-to-AP sightings.
- There are no controller-derived wireless client association edges for those APs.

This means `web-ng` cannot surface endpoints off access points because the underlying topology model never receives those relationships.

## Goals
- Emit wireless client topology from UniFi controllers as first-class topology links.
- Model wireless clients as endpoint attachments to the serving AP.
- Preserve compatibility with the existing topology ingestion and God View endpoint clustering pipeline.
- Avoid duplicating the same client across multiple evidence sources when a stronger attachment identity exists.

## Non-Goals
- Redesign all endpoint clustering logic in `web-ng`.
- Add direct secret decryption or controller credential export changes.
- Solve every controller type in the same change; this change is UniFi-specific.

## Design
### UniFi mapper extraction
Extend the UniFi poller to query wireless client association data from the controller inventory/API responses already used for site discovery.

For each associated wireless client, publish a topology link where:
- the local device is the AP
- the neighbor represents the client identity
- the evidence is endpoint attachment, not backbone topology

### Link semantics
Published links SHALL use:
- `Protocol = "UniFi-API"`
- `metadata.source = "unifi-api-wireless-client"`
- `metadata.relation_type = "ATTACHED_TO"`
- `metadata.evidence_class = "endpoint-attachment"`

Confidence metadata SHOULD distinguish direct controller association from weaker single-identifier inferences so downstream ranking can prefer controller-backed wireless attachment evidence.

### Identity rules
Wireless clients often have:
- MAC address always
- IP address sometimes
- hostname/device name sometimes

The mapper SHOULD publish the strongest available client identity while keeping MAC-based identity stable enough for de-duplication across repeated polls.

### Merge behavior
Controller-derived wireless client links SHALL coexist with existing:
- UniFi uplink links
- LLDP/CDP links
- SNMP-L2 attachment/backbone links

Canonicalization and graph projection MUST NOT treat wireless client links as infrastructure backbone edges.

## Risks
- Controllers may expose different client payload shapes across versions.
- Clients may roam between APs frequently, which can create churn.
- Some clients may only expose MAC identity, increasing duplicate-resolution sensitivity.

## Validation
- Unit tests for UniFi client parsing and topology publication
- Tests for metadata/evidence shape
- Tests ensuring uplink extraction still behaves unchanged
