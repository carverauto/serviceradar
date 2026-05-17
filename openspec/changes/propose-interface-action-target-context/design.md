## Context

Northbound action plugins are intended to integrate with external systems such as OpenText Network Automation, Ansible, Nautobot, NetBox, ServiceNow, and vendor APIs. Those systems often need precise target context, but "precise" varies by integration. A device lookup may only need `device.ip`; an interface audit may need `interface.if_name`, `interface.if_index`, and `device.management_ip`; a modular chassis action may need slot/module/port identity.

SNMP `ifIndex` is not a physical port number. It is the index into IF-MIB tables for a particular agent view. On some platforms it is stable, on others it can change after reload or reconfiguration, and it does not encode chassis slot/module ownership by itself. For an interface displayed as `1/1/3`, ServiceRadar must not assume `ifIndex = 3`. The correct action context should carry the exact interface name/description and, when discovery can prove it, a separate physical-location object derived from ENTITY-MIB, ifStack, LLDP/CDP, or vendor/API data.

## Goals

- Provide integrations with the exact device/interface fields they declare in their descriptor.
- Preserve `ifIndex` when known, but treat it as one field among several rather than the primary identity.
- Represent modular physical location separately from IF-MIB identity.
- Avoid exposing internal/debug metadata as prominent device details UI.
- Make device details logs and availability panels reflect authoritative data queries instead of ambiguous loading or fallback states.

## Non-Goals

- Do not invent linecard/module data when discovery has not collected it.
- Do not require every plugin to receive every device/interface field.
- Do not remove the full alias table; remove only redundant summary cards.
- Do not build a general metadata explorer in this change. Raw/debug metadata can remain available behind diagnostics or a deliberate expand path.

## Decisions

- Action descriptors continue to declare required and optional context fields. Dispatch SHALL validate required fields before invoking the plugin and mark targets failed with a clear missing-context error when required fields are unavailable.
- Interface snapshots SHALL include a canonical interface identifier plus requested IF-MIB and display fields. `if_index` SHALL be numeric when known and nullable/absent when unavailable.
- Physical location SHALL be represented as a nested optional object, for example chassis/slot/module/subslot/port plus source and confidence/provenance fields. This keeps vendor-specific semantics out of `if_index`.
- Device details metadata cards SHALL use an allowlist/grouping model for operator-useful fields. Internal fields such as job IDs, API URLs, debug payloads, mapper implementation details, and counts of hidden keys SHALL not be shown as primary content.
- Logs tab data SHALL come from a bounded SRQL query keyed to the device identity and aliases already known to the page. Empty results are a valid terminal state.

## Risks / Trade-offs

- Some existing plugins may have been reading untyped metadata fields. Mitigation: add structured fields without removing legacy metadata immediately and update sample plugins/SDKs first.
- Physical interface location will be incomplete until discovery sources populate it. Mitigation: expose provenance and keep `if_name`/`if_descr` as first-class target fields.
- Filtering metadata may hide fields useful for debugging. Mitigation: keep a deliberate diagnostics expansion for users with appropriate permissions instead of displaying noisy fields in the main card.

## Open Questions

- Which physical-location fields should be persisted first from the current mapper payloads versus computed only at action dispatch time?
- Should the logs tab include device aliases by default, or only the canonical primary IP plus a visible alias filter?
