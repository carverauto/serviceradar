## Context

`ocsf_devices` holds one value per attribute. Sources differ in what they know:
SNMP (mapper) reports `sysName`, `sysDescr` and `sysObjectID`; the passive
census sees an IP and a MAC; hypervisor enrichment sees a node's address and
platform role; an automation inventory lists hosts; an OUI lookup names the
NIC registrant. Today the last write wins, except for `ip` (never-downgrade
address rank, #3905) and manual `type` ownership.

## Decisions

1. Each single-valued attribute (`name`, `vendor_name`, `type`,
   `integration_type`) stores its source and evidence strength alongside the
   value. Strength is assigned by the writer from the evidence it holds, not
   inferred later from the value.
2. Strength order for `name`, weakest first:
   1. address fallback: the update has no hostname, so the name is an address
      (the passive census and hypervisor enrichment both produce these);
   2. passive census sighting with an observed hostname;
   3. SNMP `sysName` from the mapper, or a name reported by an integration.
3. Strength order for `vendor_name`, weakest first. The tier follows the
   vendor name derived for the update, never the evidence channel or the
   `sysObjectID` enterprise alone:
   1. a name that names SNMP agent software (Net-SNMP and similar), from any
      source;
   2. the IEEE OUI registrant of the MAC (`mac_vendor_source = "ieee_oui"`);
   3. a hardware vendor name, from any source: a `sysObjectID` hardware
      enterprise, `sysDescr` inference, a classification rule, an integration
      report, or explicit metadata.
   The agent-software enterprises are a fixed, named list kept next to the
   enterprise-to-vendor table; an enterprise not on it is a hardware vendor.
   A `sysObjectID` under enterprise 8072 with a hardware vendor from
   `sysDescr` or a classification rule is tier 3; a `sysDescr` or
   classification result that names agent software is tier 1.
   Not vendor evidence, and never written to `vendor_name` from any source: an
   OS, software or platform name (`Linux`, `Microsoft`, `NGINX`, `Apache`,
   `Caddy`, an automation platform's own product name, ...). OS and software
   names are written to the OS / software fields instead.
4. Strength order for `type`, weakest first:
   1. a generic type set without device evidence (`host` from an automation
      inventory, or a default);
   2. a type inferred from a passive fingerprint or classification rule;
   3. a type derived from SNMP (for example `Router` from `ip_forwarding`);
   4. a type reported by the inventory that owns the device's platform role
      (hypervisor inventory `Hypervisor` / `Virtual`), strictly above SNMP so
      a hypervisor node that routes VM traffic keeps `Hypervisor`.
   Manual `type` ownership keeps precedence over all four.
5. Strength order for `integration_type`, weakest first:
   1. a generic automation inventory that lists the device as a host;
   2. the inventory that discovers the device as its own platform object
      (hypervisor inventory for a hypervisor node or VM).
6. An equal-or-stronger write replaces the recorded value. A weaker write
   fills the attribute only when no value is stored. Nothing else decides:
   there is no test comparing the stored name with the stored address. A
   populated value without a recorded strength (rows written before this
   change) is kept against a weakest-tier write; the next write of a middle or
   strongest tier replaces it and records its strength. A missing strength is
   never treated as a recorded weak strength. So the first census pass after
   rollout may change an unrecorded spelling once (for example a legacy
   `Net-SNMP`, OS or hardware vendor spelling becomes the OUI spelling), and
   the first mapper pass may change it once more to a stronger value.
7. An address fallback name is derived from the address the device keeps after
   the address rank guard, never from an update address the guard rejected, so
   an NDP or link-local (`fe80::`) sighting cannot rename a device. A recorded
   address-fallback name follows the address the device keeps.
8. The upsert compares strength with the stored row inside the `ON CONFLICT`
   update, the same place the `ip` rank guard lives, so concurrent writers
   cannot race a read-then-write in Elixir.
9. In-batch merging (`merge_records_by_uid`) applies the same order and the
   same equal-or-stronger rule to the updates it combines, so two updates for
   one device in one batch resolve the same way as in two batches.
10. The denormalized metadata `integration_id` slot is dropped. Integration
    membership already lives per provider in `device_identifiers`; readers of
    the slot move to the provider-scoped identifier. A per-provider key in
    metadata was considered and rejected as a second copy of
    `device_identifiers`.
11. `PluginInputPayloadBuilder.normalize_device_row` copies an integration
    identifier into a plugin input item only for the plugin whose provider
    owns it. Proxmox inputs read the hypervisor provider ref from
    `device_identifiers`, which only the hypervisor inventory writes, so
    `ProxmoxHostAuthority.target_ids` sees a stable id.

## Open questions

- None that block implementation.

## Rejected alternatives

- Ignore `name` / `vendor_name` in the config version hash: the compiled config
  really does change (target name, credential), so the version must change.
- Drop the census's name and vendor entirely: loses enrichment for devices no
  other source describes, which the passive-census spec intends to keep.
- Treat a stored name equal to the stored address as replaceable: a second
  definition of "placeholder" that disagrees with the recorded strength. It
  lets a guard-rejected address rename a device, and classifies an observed
  `sysName` that happens to be an address as a placeholder, which restarts the
  loop this change exists to stop.
- Refuse any name that parses as an IP literal (an address-literal stop-gap):
  it hides the census and hypervisor-enrichment writes without ranking them,
  drops a real `sysName` that is an address, and leaves `vendor_name`, `type`
  and `integration_type` flipping. The name fix is built on recorded strength
  instead.
