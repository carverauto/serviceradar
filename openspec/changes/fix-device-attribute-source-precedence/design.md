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
2. Strength order for `name`, weakest first, with no two sources sharing a
   tier:
   1. address fallback: the update has no hostname, so the name is an address
      (the passive census and hypervisor enrichment both produce these);
   2. passive census sighting with an observed hostname;
   3. a name reported by an automation inventory (such as AWX);
   4. SNMP `sysName` from the mapper;
   5. a name reported by the hypervisor platform inventory.
   The `hostname` column is gated by the same tiers and is accepted or
   rejected together with `name` as one value, because plugin inputs prefer
   `hostname` over `name`. Both `HypervisorEnrichmentIngestor` paths, the
   repeating existing-device host and guest update and
   `placeholder_device_update` on the create path, carry the inventory
   record's name as the tier 5 name / hostname pair when the record has one;
   a `provider_ref` or an address is never that name, and an update with no
   record name is a tier 1 address fallback.
3. Strength order for `vendor_name`, weakest first:
   1. a name that names SNMP agent software (Net-SNMP and similar), from
      device, integration or metadata evidence;
   2. the IEEE OUI registrant of the MAC (`mac_vendor_source = "ieee_oui"`),
      always this tier whatever the registrant string, so a census `Ubiquiti
      Inc` never ties a recorded `sysObjectID` `Ubiquiti`;
   3. a hardware vendor name from device, integration or metadata evidence: a
      `sysObjectID` hardware enterprise, `sysDescr` inference, a
      classification rule, an integration report, or explicit metadata.
   For a value that is not an OUI lookup, the name, not the channel or the
   `sysObjectID` enterprise alone, decides whether it is agent software, a
   hardware vendor, or not a vendor.
   The agent-software enterprises are a fixed, named list kept next to the
   enterprise-to-vendor table, only to mark table entries whose name is agent
   software; the vendor name, not the enterprise number, decides the tier.
   A `sysObjectID` under enterprise 8072 with a hardware vendor from
   `sysDescr` or a classification rule is tier 3; a `sysDescr` or
   classification result that names agent software is tier 1.
   Not vendor evidence, and never written to `vendor_name` from any source: an
   OS, software or platform name (`Linux`, `Microsoft`, `NGINX`, `Apache`,
   `Caddy`, an automation platform's own product name, ...). OS and software
   names are written to the OS / software fields instead. Such a name is
   ignored for `vendor_name`; the same update's OUI or hardware vendor is
   still ranked normally.
   `model` is accepted or rejected together with `vendor_name` as one value,
   at the vendor's write strength, because the mapper `sysDescr`, the
   automation inventory and the hypervisor / UniFi sources all write it.
4. Strength order for `type`, weakest first:
   1. a generic type set without device evidence (`host` from an automation
      inventory, or a default);
   2. a type inferred from a passive fingerprint or classification rule;
   3. a type derived from SNMP (for example `Router` from `ip_forwarding`);
   4. a type reported by the inventory that owns the device's platform role
      (hypervisor inventory `Hypervisor` / `Virtual`), strictly above SNMP so
      a hypervisor node that routes VM traffic keeps `Hypervisor`.
   `type`, `type_id` and `metadata.device_role` are accepted or rejected
   together as one value, so a rejected `Router` cannot leave its `type_id`
   beside a kept `Hypervisor`, and a mapper role (`router`, `ap_bridge`,
   `switch_l2` or `host` from `role_for_metrics` / `persist_role_metadata`)
   never replaces a platform `hypervisor` / `virtual-guest` role. That keeps
   `PluginInputPayloadBuilder`'s `device_role` and `target_kind` and
   `ProxmoxHostAuthority`'s role read stable; `device_role` is still copied
   into plugin inputs. Manual `type` ownership keeps precedence over all
   four, for all three fields.
5. Strength order for `integration_type`, weakest first:
   1. a generic automation inventory that lists the device as a host;
   2. the inventory that discovers the device as its own platform object
      (hypervisor inventory for a hypervisor node or VM).
6. An equal-or-stronger write replaces the recorded value. A weaker write
   fills the attribute only when no value is stored. Nothing else decides:
   there is no test comparing the stored name with the stored address. A
   populated value without a recorded strength (rows written before this
   change) is kept against a weakest-tier write; the next write of any tier
   above the weakest replaces it and records its strength. A missing strength is
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
   cannot race a read-then-write in Elixir. `name` and `hostname` are decided
   there as one value, as are `type` and `type_id`.
9. In-batch merging (`merge_records_by_uid`) applies the same order and the
   same equal-or-stronger rule to the updates it combines, so two updates for
   one device in one batch resolve the same way as in two batches.
10. The denormalized metadata `integration_id` slot is dropped. Integration
    membership already lives per provider in `device_identifiers`; readers of
    the slot move to the provider-scoped identifier: plugin inputs and
    `ProxmoxHostAuthority.target_ids`, `IdentityProjections.binding_keys`
    (unmerge), `ArmisNorthboundPopulation`, and the `SourceIdentityDrift`
    repair reread. The `ResultProcessor` writer that copies a snapshot
    `integration_id` into update metadata stops, or writes the
    provider-scoped identifier instead. A per-provider key in
    metadata was considered and rejected as a second copy of
    `device_identifiers`.
11. `PluginInputPayloadBuilder.normalize_device_row` copies an integration
    identifier into a plugin input item only for the plugin whose provider
    owns it. Proxmox inputs read the hypervisor provider ref from
    `device_identifiers`, which only the hypervisor inventory writes, so
    `ProxmoxHostAuthority.target_ids` sees a stable id.

12. Every single-valued attribute read by plugin input building or agent
    configuration compilation has one owning writer or a rank. Owned
    metadata keys are replaced only by their owner; another ingestor may only
    fill an absent key.

    | Attribute | Readers | Rule |
    | --- | --- | --- |
    | `name` / `hostname` | SNMP compiler, plugin inputs | ranked (decision 2) |
    | `vendor_name` / `model` | credential-rule target queries, plugin inputs | ranked (decision 3), one value |
    | `type` / `type_id` / `metadata.device_role` | plugin inputs (`target_kind`), `ProxmoxHostAuthority` | ranked (decision 4), one value |
    | `integration_type` | plugin inputs, unmerge | ranked (decision 5) |
    | metadata `integration_id` | (dropped) | provider-scoped identifiers (decision 10) |
    | `ip` | SNMP compiler, plugin inputs | existing address rank guard |
    | `hypervisor_provider_ref`, `proxmox_node`, `proxmox_cluster`, `hypervisor_guest_type`, `hypervisor_vmid`, `proxmox_base_url` | plugin inputs, `ProxmoxHostAuthority` | owner: hypervisor platform inventory |
    | `proxmox_candidate`, `proxmox_tls_sans_recorded`, `proxmox_tls_san_ips` | plugin inputs, `ProxmoxHostAuthority`, credential-rule target queries | owner: mapper Proxmox candidate probe |
    | `management_device_id` | SNMP compiler (polling host) | ranked: camera inventory > mapper |
    | tags / labels | target queries | merged maps (union), not single-valued |

## Open questions

- A name reported by an integration other than the automation inventory and
  the hypervisor inventory is not ranked by this change; it is not part of the
  observed loop. Rank it before it shares a device with another name source.

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
